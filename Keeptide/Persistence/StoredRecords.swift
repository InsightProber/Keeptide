import CoreData
import Foundation

/// Queue-confined Core Data mapping and integrity checks. Every entry point must
/// be called synchronously from the supplied context's queue.
enum StoredRecords {
    static func object(_ key: RecordKey, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: key.entity)
        request.predicate = NSPredicate(format: "id == %@", key.id as NSUUID)
        if case .itemMarker = key {
            // Cloud merges may produce equivalent logical tombstones.
        } else {
            request.fetchLimit = 2
        }
        let matches = try context.fetch(request)
        if case .itemMarker = key, !matches.isEmpty {
            let validated = try matches.map { object -> (NSManagedObject, Date) in
                guard object.value(forKey: "id") as? UUID == key.id,
                      let deletedAt = object.value(forKey: "deletedAt") as? Date,
                      deletedAt.timeIntervalSinceReferenceDate.isFinite else {
                    throw StoreError.corruptStore
                }
                return (object, deletedAt)
            }
            return validated.max { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.objectID.uriRepresentation().absoluteString
                    < rhs.0.objectID.uriRepresentation().absoluteString
            }?.0
        }
        guard matches.count <= 1 else { throw StoreError.corruptStore }
        return matches.first
    }

    static func value(_ key: RecordKey, in context: NSManagedObjectContext) throws -> RecordValue? {
        guard let object = try object(key, in: context) else { return nil }
        switch key {
        case .item:
            return .item(try itemValue(object))
        case .capture:
            let id: UUID = try required(object, "id")
            let manifestData: Data = try required(object, "manifest")
            let digest: Data = try required(object, "digest")
            let manifest = try decodeManifest(manifestData)
            return .capture(CaptureValue(
                id: id,
                manifest: manifest,
                digest: digest,
                representations: try captureRepresentations(snapshotID: id, in: context)
            ))
        case .memo:
            return .memo(try memoValue(object, includeBody: true))
        case .collection:
            return .collection(CollectionValue(
                id: CollectionID(rawValue: try required(object, "id")),
                name: try required(object, "name"),
                color: try required(object, "color"),
                sortOrder: try double(object, "sortOrder"),
                deletedAt: object.value(forKey: "deletedAt") as? Date
            ))
        case .itemMarker:
            return .itemMarker(ItemDeletionMarkerValue(
                itemID: ItemID(rawValue: try required(object, "id")),
                deletedAt: try required(object, "deletedAt")
            ))
        case .facetMarker:
            guard let facet = ContentFacet(rawValue: try required(object, "facet")) else {
                throw StoreError.corruptStore
            }
            return .facetMarker(FacetDeletionMarkerValue(
                id: try required(object, "id"),
                itemID: ItemID(rawValue: try required(object, "itemID")),
                facet: facet,
                generationID: try required(object, "generationID"),
                purgedAt: try required(object, "purgedAt")
            ))
        }
    }

    static func write(
        _ value: RecordValue,
        to object: NSManagedObject,
        in context: NSManagedObjectContext
    ) throws {
        guard object.entity.name == value.key.entity else { throw StoreError.invalidTransaction }
        switch value {
        case .item(let item):
            object.setValue(item.id.rawValue, forKey: "id")
            object.setValue(item.createdAt, forKey: "createdAt")
            object.setValue(item.sourceApp, forKey: "sourceApp")
            object.setValue(item.title, forKey: "title")
            object.setValue(item.captureID, forKey: "captureID")
            object.setValue(item.memoID, forKey: "memoID")
            object.setValue(item.collectionID?.rawValue, forKey: "collectionID")
            object.setValue(item.isFavorite, forKey: "isFavorite")
            object.setValue(item.historyEligible, forKey: "historyEligible")
            object.setValue(item.historyDeletedAt, forKey: "historyDeletedAt")
            object.setValue(item.historyPurgeAfter, forKey: "historyPurgeAfter")
            object.setValue(item.deletedAt, forKey: "deletedAt")
            object.setValue(item.lastCopiedAt, forKey: "lastCopiedAt")
            object.setValue(item.copyCount, forKey: "copyCount")

        case .capture(let capture):
            let canonical = try capture.manifest.canonicalData()
            guard ContentDigest.sha256(canonical) == capture.digest,
                  capture.manifest.validate(capture.representations, snapshotID: capture.id) == .complete else {
                throw StoreError.invalidTransaction
            }
            object.setValue(capture.id, forKey: "id")
            object.setValue(canonical, forKey: "manifest")
            object.setValue(capture.digest, forKey: "digest")

            if let existing = object.value(forKey: "representations") as? Set<NSManagedObject> {
                existing.forEach(context.delete)
            }
            for representation in capture.representations {
                let child = NSEntityDescription.insertNewObject(
                    forEntityName: "CaptureRepresentation",
                    into: context
                )
                child.setValue(representation.id, forKey: "id")
                child.setValue(representation.snapshotID, forKey: "snapshotID")
                child.setValue(Int64(representation.itemIndex), forKey: "itemIndex")
                child.setValue(Int64(representation.representationIndex), forKey: "representationIndex")
                child.setValue(representation.typeIdentifier, forKey: "typeIdentifier")
                child.setValue(representation.storage.rawValue, forKey: "storage")
                child.setValue(representation.byteCount, forKey: "byteCount")
                child.setValue(representation.digest, forKey: "digest")
                child.setValue(representation.bytes, forKey: "bytes")
                child.setValue(object, forKey: "snapshot")
            }

        case .memo(let memo):
            object.setValue(memo.id, forKey: "id")
            object.setValue(memo.itemID.rawValue, forKey: "itemID")
            object.setValue(memo.title, forKey: "title")
            object.setValue(memo.bodyMode.rawValue, forKey: "bodyMode")
            object.setValue(memo.sourceRepresentationType, forKey: "sourceRepresentationType")
            object.setValue(memo.body, forKey: "body")
            object.setValue(memo.version?.rawValue, forKey: "version")
            object.setValue(memo.digest, forKey: "digest")
            object.setValue(memo.languageHint, forKey: "languageHint")
            object.setValue(memo.note, forKey: "note")
            object.setValue(memo.deletedAt, forKey: "deletedAt")
            object.setValue(memo.purgeAfter, forKey: "purgeAfter")

        case .collection(let collection):
            object.setValue(collection.id.rawValue, forKey: "id")
            object.setValue(collection.name, forKey: "name")
            object.setValue(collection.color, forKey: "color")
            object.setValue(collection.sortOrder, forKey: "sortOrder")
            object.setValue(collection.deletedAt, forKey: "deletedAt")

        case .itemMarker(let marker):
            object.setValue(marker.itemID.rawValue, forKey: "id")
            object.setValue(marker.deletedAt, forKey: "deletedAt")

        case .facetMarker(let marker):
            object.setValue(marker.id, forKey: "id")
            object.setValue(marker.itemID.rawValue, forKey: "itemID")
            object.setValue(marker.facet.rawValue, forKey: "facet")
            object.setValue(marker.generationID, forKey: "generationID")
            object.setValue(marker.purgedAt, forKey: "purgedAt")
        }
    }

    /// Relationships are linked only after every transaction record has been
    /// inserted, so a failed lookup cannot leave a partially linked item.
    static func link(_ item: ItemValue, in context: NSManagedObjectContext) throws {
        guard let itemObject = try object(.item(item.id), in: context) else {
            throw StoreError.invalidTransaction
        }
        itemObject.setValue(try relatedObject(item.captureID.map(RecordKey.capture), in: context), forKey: "capture")
        let memoObject = try relatedObject(item.memoID.map(RecordKey.memo), in: context)
        if let memoObject {
            guard memoObject.value(forKey: "itemID") as? UUID == item.id.rawValue else {
                throw StoreError.invalidTransaction
            }
        }
        itemObject.setValue(memoObject, forKey: "memo")
        itemObject.setValue(
            try relatedObject(item.collectionID.map(RecordKey.collection), in: context),
            forKey: "collection"
        )
    }

    static func summaries(limit: Int, in context: NSManagedObjectContext) throws -> [ItemSummary] {
        guard limit >= 0 else { throw StoreError.invalidTransaction }
        guard limit > 0 else { return [] }
        let batchSize = 128
        var offset = 0
        var summaries: [ItemSummary] = []
        while summaries.count < limit {
            let request = dictionaryRequest(
                entity: "LibraryItem",
                properties: itemMetadataProperties,
                predicate: NSPredicate(format: "deletedAt == nil"),
                sortDescriptors: [
                    NSSortDescriptor(key: "lastCopiedAt", ascending: false),
                    NSSortDescriptor(key: "id", ascending: true)
                ]
            )
            request.fetchLimit = batchSize
            request.fetchOffset = offset
            let rows = try context.fetch(request)
            guard !rows.isEmpty else { break }

            let projection = try readProjection(items: rows, strict: false, in: context)
            for row in projection.items where summaries.count < limit {
                guard let summary = summary(row, projection: projection) else { continue }
                summaries.append(summary)
            }
            guard rows.count == batchSize else { break }
            offset += rows.count
        }
        return summaries
    }

    static func snapshotReferences(
        in context: NSManagedObjectContext
    ) throws -> (refs: [ContentRef], protectedCaptures: Set<UUID>) {
        let projection = try readProjection(strict: true, in: context)
        var refs: [ContentRef] = []
        var protectedCaptures = Set<UUID>()
        for row in projection.items {
            let metadata = try validatedItemMetadata(row)
            if let captureID = metadata.captureID { protectedCaptures.insert(captureID) }
            guard metadata.deletedAt == nil,
                  !projection.itemMarkerIDs.contains(metadata.id.rawValue) else { continue }

            if metadata.historyEligible, metadata.historyDeletedAt == nil {
                guard let captureID = metadata.captureID else { throw StoreError.snapshotUnavailable }
                let marker = ProjectedFacet(
                    itemID: metadata.id.rawValue,
                    facet: .history,
                    generationID: captureID
                )
                if !projection.facetMarkers.contains(marker) {
                    guard let capture = projection.captures[captureID] else { throw StoreError.snapshotUnavailable }
                    guard let digest = capture["digest"] as? Data else { throw StoreError.corruptStore }
                    refs.append(ContentRef(
                        itemID: metadata.id,
                        facet: .history,
                        version: ContentVersion(rawValue: captureID),
                        digest: digest
                    ))
                }
            }

            if let memoID = metadata.memoID {
                let marker = ProjectedFacet(
                    itemID: metadata.id.rawValue,
                    facet: .memo,
                    generationID: memoID
                )
                guard !projection.facetMarkers.contains(marker) else { continue }
                guard let memo = projection.memos[memoID] else { throw StoreError.snapshotUnavailable }
                if memo["deletedAt"] != nil { continue }
                guard let ref = try projectedMemoRef(
                    item: metadata,
                    memoID: memoID,
                    memo: memo,
                    projection: projection
                ) else { throw StoreError.snapshotUnavailable }
                refs.append(ref)
            }
        }
        return (refs, protectedCaptures)
    }

    static func currentRef(
        itemID: ItemID,
        facet: ContentFacet,
        in context: NSManagedObjectContext
    ) throws -> ContentRef? {
        guard let item = try itemMetadata(itemID, in: context) else { throw StoreError.notFound }
        try ensureVisible(item: item, itemID: itemID, facet: facet, in: context)
        return try currentRef(item: item, itemID: itemID, facet: facet, in: context)
    }

    static func resolve(_ ref: ContentRef, in context: NSManagedObjectContext) throws -> ResolvedContent {
        guard let item = try itemMetadata(ref.itemID, in: context) else { throw StoreError.notFound }
        try ensureVisible(item: item, itemID: ref.itemID, facet: ref.facet, in: context)

        switch ref.facet {
        case .history:
            guard let captureID = item["captureID"] as? UUID else { throw StoreError.notFound }
            guard ref.version.rawValue == captureID else { throw StoreError.staleReference }
            guard let capture = try captureMetadata(captureID, in: context) else {
                return incomplete(ref, .recovering)
            }
            let digest: Data = try required(capture, "digest")
            guard digest == ref.digest else { throw StoreError.staleReference }
            return try resolveCapture(ref: ref, captureID: captureID, in: context)

        case .memo:
            guard let memoID = item["memoID"] as? UUID else { throw StoreError.notFound }
            guard let memo = try memoMetadata(memoID, in: context) else {
                return incomplete(ref, .recovering)
            }
            guard memo["itemID"] as? UUID == ref.itemID.rawValue,
                  let rawMode = memo["bodyMode"] as? String,
                  let mode = MemoBodyMode(rawValue: rawMode) else {
                return incomplete(ref, .corrupt)
            }
            switch mode {
            case .inheritedCapture:
                guard let captureID = item["captureID"] as? UUID else {
                    return incomplete(ref, .recovering)
                }
                guard ref.version.rawValue == captureID else { throw StoreError.staleReference }
                guard let capture = try captureMetadata(captureID, in: context) else {
                    return incomplete(ref, .recovering)
                }
                let digest: Data = try required(capture, "digest")
                guard digest == ref.digest else { throw StoreError.staleReference }
                guard memo["version"] == nil,
                      memo["digest"] == nil,
                      try !hasBody(memoID: memoID, in: context) else {
                    return incomplete(ref, .corrupt)
                }
                return try resolveCapture(ref: ref, captureID: captureID, in: context)

            case .ownedPlainText, .ownedMarkdown:
                guard let version = memo["version"] as? UUID,
                      let digest = memo["digest"] as? Data else {
                    return incomplete(ref, .recovering)
                }
                guard ref.version.rawValue == version, ref.digest == digest else {
                    throw StoreError.staleReference
                }
                let bodyRequest = dictionaryRequest(
                    entity: "MemoDocument",
                    properties: ["id", "body"],
                    predicate: NSPredicate(format: "id == %@", memoID as NSUUID)
                )
                bodyRequest.fetchLimit = 2
                let bodies = try context.fetch(bodyRequest)
                guard bodies.count <= 1 else { return incomplete(ref, .corrupt) }
                guard let body = bodies.first?["body"] as? Data else {
                    return incomplete(ref, .recovering)
                }
                guard String(data: body, encoding: .utf8) != nil,
                      ContentDigest.sha256(body) == digest else {
                    return incomplete(ref, .corrupt)
                }
                let representation = RepresentationValue(
                    id: memoID,
                    snapshotID: memoID,
                    itemIndex: 0,
                    representationIndex: 0,
                    typeIdentifier: "public.utf8-plain-text",
                    storage: .portable,
                    byteCount: Int64(body.count),
                    digest: digest,
                    bytes: body
                )
                return ResolvedContent(ref: ref, integrity: .complete, representations: [representation])
            }
        }
    }

    /// Loads the cloud-portable capture graph without consulting local file
    /// authorization. Archive/export callers use this strict boundary so a
    /// local relocation cannot hide a damaged portable payload.
    static func validatedCapture(_ id: UUID, in context: NSManagedObjectContext) throws -> CaptureValue {
        do {
            return try captureValue(id, in: context)
        } catch CaptureReadFailure.missing {
            throw StoreError.notFound
        } catch {
            throw StoreError.corruptStore
        }
    }

    static func fingerprint(_ key: RecordKey, in context: NSManagedObjectContext) throws -> Data {
        switch key {
        case .capture(let id):
            return try captureFingerprint(id: id, in: context)
        case .memo(let id):
            guard let metadata = try memoMetadata(id, in: context) else { throw StoreError.notFound }
            return try digest(try MemoFingerprint(metadata, bodyPresent: hasBody(memoID: id, in: context)))
        default:
            guard let value = try value(key, in: context) else { throw StoreError.notFound }
            return try digest(value)
        }
    }

    static func candidateFingerprint(digest candidateDigest: Data, in context: NSManagedObjectContext) throws -> Data {
        let captureRequest = dictionaryRequest(
            entity: "CaptureSnapshot",
            properties: ["id", "digest"],
            predicate: NSPredicate(format: "digest == %@", candidateDigest as NSData)
        )
        let captureRows = try context.fetch(captureRequest)
        var captureDigests: [UUID: Data] = [:]
        let captureIDs = try captureRows.map { row -> UUID in
            let id: UUID = try required(row, "id")
            let digest: Data = try required(row, "digest")
            guard digest == candidateDigest,
                  captureDigests.updateValue(digest, forKey: id) == nil else {
                throw StoreError.corruptStore
            }
            return id
        }
        guard !captureIDs.isEmpty else { return try digest([ContentRef]()) }

        let itemRequest = dictionaryRequest(
            entity: "LibraryItem",
            properties: itemMetadataProperties,
            predicate: NSPredicate(
                format: "deletedAt == nil AND historyEligible == YES AND historyDeletedAt == nil AND captureID IN %@",
                captureIDs
            ),
            sortDescriptors: [NSSortDescriptor(key: "id", ascending: true)]
        )
        let items = try context.fetch(itemRequest)
        let itemIDs = try items.map { try required($0, "id") as UUID }
        let hiddenItems = try itemMarkerIDs(itemIDs: itemIDs, strict: true, in: context)
        let facetMarkers = try facetMarkers(itemIDs: itemIDs, strict: true, in: context)
        let refs = try items.compactMap { row -> ContentRef? in
            let item = try validatedItemMetadata(row)
            guard !hiddenItems.contains(item.id.rawValue), let captureID = item.captureID else { return nil }
            let marker = ProjectedFacet(itemID: item.id.rawValue, facet: .history, generationID: captureID)
            guard !facetMarkers.contains(marker), let digest = captureDigests[captureID] else { return nil }
            return ContentRef(
                itemID: item.id,
                facet: .history,
                version: ContentVersion(rawValue: captureID),
                digest: digest
            )
        }
        return try digest(refs)
    }

    static func referenceFingerprint(snapshotID: UUID, in context: NSManagedObjectContext) throws -> Data {
        let itemsRequest = dictionaryRequest(
            entity: "LibraryItem",
            properties: itemMetadataProperties,
            predicate: NSPredicate(format: "captureID == %@", snapshotID as NSUUID),
            sortDescriptors: [NSSortDescriptor(key: "id", ascending: true)]
        )
        let itemRows = try context.fetch(itemsRequest)
        let itemIDs = try itemRows.map { row -> UUID in
            _ = try validatedItemMetadata(row)
            return try required(row, "id")
        }

        let memoRows: [NSDictionary]
        if itemIDs.isEmpty {
            memoRows = []
        } else {
            let memoRequest = dictionaryRequest(
                entity: "MemoDocument",
                properties: memoMetadataProperties,
                predicate: NSPredicate(format: "itemID IN %@", itemIDs),
                sortDescriptors: [
                    NSSortDescriptor(key: "itemID", ascending: true),
                    NSSortDescriptor(key: "id", ascending: true)
                ]
            )
            memoRows = try context.fetch(memoRequest)
        }
        for row in memoRows {
            let memoID: UUID = try required(row, "id")
            _ = try MemoFingerprint(row, bodyPresent: hasBody(memoID: memoID, in: context))
        }
        return try digest(ReferenceFingerprint(
            items: try itemRows.map(ReferenceItemMetadata.init),
            memos: try memoRows.map(ReferenceMemoMetadata.init)
        ))
    }
}

private extension StoredRecords {
    static let itemMetadataProperties = [
        "id", "createdAt", "sourceApp", "title", "captureID", "memoID", "collectionID",
        "isFavorite", "historyEligible", "historyDeletedAt", "historyPurgeAfter", "deletedAt",
        "lastCopiedAt", "copyCount"
    ]
    static let memoMetadataProperties = [
        "id", "itemID", "title", "bodyMode", "sourceRepresentationType", "version", "digest",
        "languageHint", "note", "deletedAt", "purgeAfter"
    ]

    static func readProjection(strict: Bool, in context: NSManagedObjectContext) throws -> ReadProjection {
        let itemRequest = dictionaryRequest(
            entity: "LibraryItem",
            properties: itemMetadataProperties,
            sortDescriptors: [
                NSSortDescriptor(key: "lastCopiedAt", ascending: false),
                NSSortDescriptor(key: "id", ascending: true)
            ]
        )
        let items = try context.fetch(itemRequest)
        return try readProjection(items: items, strict: strict, in: context)
    }

    static func readProjection(
        items: [NSDictionary],
        strict: Bool,
        in context: NSManagedObjectContext
    ) throws -> ReadProjection {
        let rawItemIDs = items.compactMap { $0["id"] as? UUID }
        let duplicateItemIDs = try duplicateItemIDs(for: rawItemIDs, in: context)
        if strict, !duplicateItemIDs.isEmpty { throw StoreError.corruptStore }
        let projectedItems = items.filter { row in
            guard let id = row["id"] as? UUID else { return true }
            return !duplicateItemIDs.contains(id)
        }
        let itemIDs = projectedItems.compactMap { $0["id"] as? UUID }
        let captureIDs = Array(Set(projectedItems.compactMap { $0["captureID"] as? UUID }))
        let memoIDs = Array(Set(projectedItems.compactMap { $0["memoID"] as? UUID }))

        var captureRows: [NSDictionary] = []
        for ids in batches(captureIDs) {
            let request = dictionaryRequest(
                entity: "CaptureSnapshot",
                properties: ["id", "digest"],
                predicate: NSPredicate(format: "id IN %@", ids)
            )
            captureRows.append(contentsOf: try context.fetch(request))
        }
        let captures = try projectedRowsByID(captureRows, strict: strict)

        var memoRows: [NSDictionary] = []
        var memoIDsWithBody = Set<UUID>()
        for ids in batches(memoIDs) {
            let request = dictionaryRequest(
                entity: "MemoDocument",
                properties: memoMetadataProperties,
                predicate: NSPredicate(format: "id IN %@", ids)
            )
            memoRows.append(contentsOf: try context.fetch(request))
            let bodyRequest = dictionaryRequest(
                entity: "MemoDocument",
                properties: ["id"],
                predicate: NSPredicate(format: "id IN %@ AND body != nil", ids)
            )
            for row in try context.fetch(bodyRequest) {
                do {
                    memoIDsWithBody.insert(try required(row, "id") as UUID)
                } catch {
                    if strict { throw error }
                }
            }
        }
        let memos = try projectedRowsByID(memoRows, strict: strict)

        return ReadProjection(
            items: projectedItems,
            itemMarkerIDs: try itemMarkerIDs(itemIDs: itemIDs, strict: strict, in: context),
            facetMarkers: try facetMarkers(itemIDs: itemIDs, strict: strict, in: context),
            captures: captures,
            memos: memos,
            memoIDsWithBody: memoIDsWithBody
        )
    }

    static func summary(_ row: NSDictionary, projection: ReadProjection) -> ItemSummary? {
        guard let item = try? validatedItemMetadata(row),
              item.deletedAt == nil,
              !projection.itemMarkerIDs.contains(item.id.rawValue) else { return nil }
        let history = projectedHistoryRef(item: item, projection: projection)
        let memo = try? projectedMemoRef(
            item: item,
            memoID: item.memoID,
            memo: item.memoID.flatMap { projection.memos[$0] },
            projection: projection
        )
        guard history != nil || memo != nil else { return nil }
        return ItemSummary(
            itemID: item.id,
            title: item.title,
            lastCopiedAt: item.lastCopiedAt,
            history: history,
            memo: memo
        )
    }

    static func projectedHistoryRef(item: ValidatedItemMetadata, projection: ReadProjection) -> ContentRef? {
        guard item.historyEligible,
              item.historyDeletedAt == nil,
              let captureID = item.captureID else { return nil }
        let marker = ProjectedFacet(itemID: item.id.rawValue, facet: .history, generationID: captureID)
        guard !projection.facetMarkers.contains(marker),
              let capture = projection.captures[captureID],
              let digest = capture["digest"] as? Data else { return nil }
        return ContentRef(
            itemID: item.id,
            facet: .history,
            version: ContentVersion(rawValue: captureID),
            digest: digest
        )
    }

    static func projectedMemoRef(
        item: ValidatedItemMetadata,
        memoID: UUID?,
        memo: NSDictionary?,
        projection: ReadProjection
    ) throws -> ContentRef? {
        guard let memoID else { return nil }
        let marker = ProjectedFacet(itemID: item.id.rawValue, facet: .memo, generationID: memoID)
        guard !projection.facetMarkers.contains(marker) else { return nil }
        guard let memo else { throw StoreError.snapshotUnavailable }
        _ = try MemoFingerprint(
            memo,
            bodyPresent: projection.memoIDsWithBody.contains(memoID)
        )
        guard memo["id"] as? UUID == memoID,
              memo["itemID"] as? UUID == item.id.rawValue,
              memo["deletedAt"] == nil,
              let rawMode = memo["bodyMode"] as? String,
              let mode = MemoBodyMode(rawValue: rawMode) else {
            throw StoreError.corruptStore
        }
        switch mode {
        case .inheritedCapture:
            guard !projection.memoIDsWithBody.contains(memoID),
                  memo["version"] == nil,
                  memo["digest"] == nil else { throw StoreError.corruptStore }
            guard let captureID = item.captureID,
                  let capture = projection.captures[captureID] else { throw StoreError.snapshotUnavailable }
            guard let digest = capture["digest"] as? Data else { throw StoreError.corruptStore }
            return ContentRef(
                itemID: item.id,
                facet: .memo,
                version: ContentVersion(rawValue: captureID),
                digest: digest
            )
        case .ownedPlainText, .ownedMarkdown:
            guard projection.memoIDsWithBody.contains(memoID) else { throw StoreError.snapshotUnavailable }
            guard let version = memo["version"] as? UUID,
                  let digest = memo["digest"] as? Data else { throw StoreError.corruptStore }
            return ContentRef(
                itemID: item.id,
                facet: .memo,
                version: ContentVersion(rawValue: version),
                digest: digest
            )
        }
    }

    static func validatedItemMetadata(_ row: NSDictionary) throws -> ValidatedItemMetadata {
        let id = ItemID(rawValue: try required(row, "id"))
        let createdAt: Date = try required(row, "createdAt")
        let title: String = try required(row, "title")
        let isFavorite = try bool(row, "isFavorite")
        let historyEligible = try bool(row, "historyEligible")
        let lastCopiedAt: Date = try required(row, "lastCopiedAt")
        let copyCount = try int64(row, "copyCount")
        let sourceApp: String? = try optional(row, "sourceApp")
        let captureID: UUID? = try optional(row, "captureID")
        let memoID: UUID? = try optional(row, "memoID")
        let collectionID: UUID? = try optional(row, "collectionID")
        let historyDeletedAt: Date? = try optional(row, "historyDeletedAt")
        let historyPurgeAfter: Date? = try optional(row, "historyPurgeAfter")
        let deletedAt: Date? = try optional(row, "deletedAt")
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              lastCopiedAt.timeIntervalSinceReferenceDate.isFinite,
              historyDeletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              historyPurgeAfter?.timeIntervalSinceReferenceDate.isFinite ?? true,
              deletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              copyCount >= 0 else { throw StoreError.corruptStore }
        _ = (sourceApp, collectionID, historyPurgeAfter, isFavorite)
        return ValidatedItemMetadata(
            id: id,
            title: title,
            captureID: captureID,
            memoID: memoID,
            historyEligible: historyEligible,
            historyDeletedAt: historyDeletedAt,
            deletedAt: deletedAt,
            lastCopiedAt: lastCopiedAt
        )
    }

    static func uniqueRowsByID(_ rows: [NSDictionary]) throws -> [UUID: NSDictionary] {
        var result: [UUID: NSDictionary] = [:]
        for row in rows {
            let id: UUID = try required(row, "id")
            guard result.updateValue(row, forKey: id) == nil else { throw StoreError.corruptStore }
        }
        return result
    }

    static func projectedRowsByID(
        _ rows: [NSDictionary],
        strict: Bool
    ) throws -> [UUID: NSDictionary] {
        var result: [UUID: NSDictionary] = [:]
        var duplicates = Set<UUID>()
        for row in rows {
            guard let id = row["id"] as? UUID else {
                if strict { throw StoreError.corruptStore }
                continue
            }
            guard !duplicates.contains(id) else { continue }
            if result.updateValue(row, forKey: id) != nil {
                if strict { throw StoreError.corruptStore }
                result.removeValue(forKey: id)
                duplicates.insert(id)
            }
        }
        return result
    }

    static func duplicateItemIDs(
        for itemIDs: [UUID],
        in context: NSManagedObjectContext
    ) throws -> Set<UUID> {
        var seen = Set<UUID>()
        var duplicates = Set<UUID>()
        for ids in batches(Array(Set(itemIDs))) {
            let request = dictionaryRequest(
                entity: "LibraryItem",
                properties: ["id"],
                predicate: NSPredicate(format: "id IN %@", ids)
            )
            for row in try context.fetch(request) {
                let id: UUID = try required(row, "id")
                if !seen.insert(id).inserted { duplicates.insert(id) }
            }
        }
        return duplicates
    }

    static func batches<T>(_ values: [T], size: Int = 128) -> [[T]] {
        guard !values.isEmpty else { return [] }
        return stride(from: 0, to: values.count, by: size).map { start in
            Array(values[start..<min(start + size, values.count)])
        }
    }

    static func itemMarkerIDs(
        itemIDs: [UUID],
        strict: Bool,
        in context: NSManagedObjectContext
    ) throws -> Set<UUID> {
        guard !itemIDs.isEmpty else { return [] }
        var ids = Set<UUID>()
        for itemIDs in batches(itemIDs) {
            let request = dictionaryRequest(
                entity: "ItemDeletionMarker",
                properties: ["id", "deletedAt"],
                predicate: NSPredicate(format: "id IN %@", itemIDs)
            )
            for row in try context.fetch(request) {
                guard let id = row["id"] as? UUID,
                      let deletedAt = row["deletedAt"] as? Date,
                      deletedAt.timeIntervalSinceReferenceDate.isFinite else {
                    if strict { throw StoreError.corruptStore }
                    continue
                }
                ids.insert(id)
            }
        }
        return ids
    }

    static func facetMarkers(
        itemIDs: [UUID],
        strict: Bool,
        in context: NSManagedObjectContext
    ) throws -> Set<ProjectedFacet> {
        guard !itemIDs.isEmpty else { return [] }
        var markers = Set<ProjectedFacet>()
        for itemIDs in batches(itemIDs) {
            let request = dictionaryRequest(
                entity: "FacetDeletionMarker",
                properties: ["itemID", "facet", "generationID", "purgedAt"],
                predicate: NSPredicate(format: "itemID IN %@", itemIDs)
            )
            for row in try context.fetch(request) {
                guard let itemID = row["itemID"] as? UUID,
                      let rawFacet = row["facet"] as? String,
                      let facet = ContentFacet(rawValue: rawFacet),
                      let generationID = row["generationID"] as? UUID,
                      let purgedAt = row["purgedAt"] as? Date,
                      purgedAt.timeIntervalSinceReferenceDate.isFinite else {
                    if strict { throw StoreError.corruptStore }
                    continue
                }
                markers.insert(ProjectedFacet(itemID: itemID, facet: facet, generationID: generationID))
            }
        }
        return markers
    }

    static func hasBody(memoID: UUID, in context: NSManagedObjectContext) throws -> Bool {
        try hasRow(
            entity: "MemoDocument",
            predicate: NSPredicate(format: "id == %@ AND body != nil", memoID as NSUUID),
            in: context
        )
    }

    static func optional<T>(_ dictionary: NSDictionary, _ key: String) throws -> T? {
        guard let value = dictionary[key], !(value is NSNull) else { return nil }
        guard let typed = value as? T else { throw StoreError.corruptStore }
        return typed
    }

    static func captureFingerprint(id: UUID, in context: NSManagedObjectContext) throws -> Data {
        guard let captureObject = try object(.capture(id), in: context),
              captureObject.value(forKey: "id") as? UUID == id,
              let manifestData = captureObject.value(forKey: "manifest") as? Data,
              let storedDigest = captureObject.value(forKey: "digest") as? Data else {
            throw StoreError.notFound
        }
        let manifest = try decodeManifest(manifestData)
        guard try manifest.canonicalData() == manifestData,
              ContentDigest.sha256(manifestData) == storedDigest else {
            throw StoreError.corruptStore
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
        request.sortDescriptors = [
            NSSortDescriptor(key: "itemIndex", ascending: true),
            NSSortDescriptor(key: "representationIndex", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        let objects = try context.fetch(request)
        guard let related = captureObject.value(forKey: "representations") as? NSSet else {
            throw StoreError.corruptStore
        }
        let relatedObjects = related.compactMap { $0 as? NSManagedObject }
        guard relatedObjects.count == related.count,
              Set(relatedObjects.map(\.objectID)) == Set(objects.map(\.objectID)) else {
            throw StoreError.corruptStore
        }

        let values = try objects.map { object -> RepresentationValue in
            guard let snapshot = object.value(forKey: "snapshot") as? NSManagedObject,
                  snapshot.objectID == captureObject.objectID,
                  let storageRaw = object.value(forKey: "storage") as? String,
                  let storage = RepresentationStorage(rawValue: storageRaw) else {
                throw StoreError.corruptStore
            }
            return RepresentationValue(
                id: try required(object, "id"),
                snapshotID: try required(object, "snapshotID"),
                itemIndex: try exactInt(object, "itemIndex"),
                representationIndex: try exactInt(object, "representationIndex"),
                typeIdentifier: try required(object, "typeIdentifier"),
                storage: storage,
                byteCount: try int64(object, "byteCount"),
                digest: try required(object, "digest"),
                bytes: nil
            )
        }
        guard values.count == manifest.entries.count,
              manifest.validate(values, snapshotID: id) != .corrupt else {
            throw StoreError.corruptStore
        }
        let portableIDs = values.filter { $0.storage == .portable }.map(\.id)
        if !portableIDs.isEmpty {
            let payloadRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
            payloadRequest.predicate = NSPredicate(format: "id IN %@ AND bytes != nil", portableIDs)
            payloadRequest.includesPendingChanges = false
            guard try context.count(for: payloadRequest) == portableIDs.count else {
                throw StoreError.corruptStore
            }
        }
        let localPayloadRequest = NSFetchRequest<NSFetchRequestResult>(entityName: "CaptureRepresentation")
        localPayloadRequest.predicate = NSPredicate(
            format: "snapshotID == %@ AND storage == %@ AND bytes != nil",
            id as NSUUID,
            RepresentationStorage.localReference.rawValue
        )
        localPayloadRequest.includesPendingChanges = false
        guard try context.count(for: localPayloadRequest) == 0 else {
            throw StoreError.corruptStore
        }
        return try digest(CaptureFingerprint(
            id: id,
            digest: storedDigest,
            representations: values.map(RepresentationFingerprint.init)
        ))
    }

    static func relatedObject(_ key: RecordKey?, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        guard let key else { return nil }
        guard let object = try object(key, in: context) else { throw StoreError.invalidTransaction }
        return object
    }

    static func itemValue(_ object: NSManagedObject) throws -> ItemValue {
        ItemValue(
            id: ItemID(rawValue: try required(object, "id")),
            createdAt: try required(object, "createdAt"),
            sourceApp: object.value(forKey: "sourceApp") as? String,
            title: try required(object, "title"),
            captureID: object.value(forKey: "captureID") as? UUID,
            memoID: object.value(forKey: "memoID") as? UUID,
            collectionID: (object.value(forKey: "collectionID") as? UUID).map(CollectionID.init),
            isFavorite: try bool(object, "isFavorite"),
            historyEligible: try bool(object, "historyEligible"),
            historyDeletedAt: object.value(forKey: "historyDeletedAt") as? Date,
            historyPurgeAfter: object.value(forKey: "historyPurgeAfter") as? Date,
            deletedAt: object.value(forKey: "deletedAt") as? Date,
            lastCopiedAt: try required(object, "lastCopiedAt"),
            copyCount: try int64(object, "copyCount")
        )
    }

    static func memoValue(_ object: NSManagedObject, includeBody: Bool) throws -> MemoValue {
        guard let mode = MemoBodyMode(rawValue: try required(object, "bodyMode")) else {
            throw StoreError.corruptStore
        }
        return MemoValue(
            id: try required(object, "id"),
            itemID: ItemID(rawValue: try required(object, "itemID")),
            title: try required(object, "title"),
            bodyMode: mode,
            sourceRepresentationType: object.value(forKey: "sourceRepresentationType") as? String,
            body: includeBody ? object.value(forKey: "body") as? Data : nil,
            version: (object.value(forKey: "version") as? UUID).map(ContentVersion.init),
            digest: object.value(forKey: "digest") as? Data,
            languageHint: object.value(forKey: "languageHint") as? String,
            note: try required(object, "note"),
            deletedAt: object.value(forKey: "deletedAt") as? Date,
            purgeAfter: object.value(forKey: "purgeAfter") as? Date
        )
    }

    static func captureRepresentations(
        snapshotID: UUID,
        in context: NSManagedObjectContext
    ) throws -> [RepresentationValue] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "snapshotID == %@", snapshotID as NSUUID)
        request.sortDescriptors = [
            NSSortDescriptor(key: "itemIndex", ascending: true),
            NSSortDescriptor(key: "representationIndex", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        return try context.fetch(request).map { object in
            guard let storage = RepresentationStorage(rawValue: try required(object, "storage")) else {
                throw StoreError.corruptStore
            }
            let itemIndex = try exactInt(object, "itemIndex")
            let representationIndex = try exactInt(object, "representationIndex")
            return RepresentationValue(
                id: try required(object, "id"),
                snapshotID: try required(object, "snapshotID"),
                itemIndex: itemIndex,
                representationIndex: representationIndex,
                typeIdentifier: try required(object, "typeIdentifier"),
                storage: storage,
                byteCount: try int64(object, "byteCount"),
                digest: try required(object, "digest"),
                bytes: object.value(forKey: "bytes") as? Data
            )
        }
    }

    static func itemMetadata(_ itemID: ItemID, in context: NSManagedObjectContext) throws -> NSDictionary? {
        try uniqueDictionary(
            entity: "LibraryItem",
            properties: itemMetadataProperties,
            predicate: NSPredicate(format: "id == %@", itemID.rawValue as NSUUID),
            in: context
        )
    }

    static func captureMetadata(_ id: UUID, in context: NSManagedObjectContext) throws -> NSDictionary? {
        try uniqueDictionary(
            entity: "CaptureSnapshot",
            properties: ["id", "manifest", "digest"],
            predicate: NSPredicate(format: "id == %@", id as NSUUID),
            in: context
        )
    }

    static func memoMetadata(_ id: UUID, in context: NSManagedObjectContext) throws -> NSDictionary? {
        try uniqueDictionary(
            entity: "MemoDocument",
            properties: memoMetadataProperties,
            predicate: NSPredicate(format: "id == %@", id as NSUUID),
            in: context
        )
    }

    static func currentRef(
        item: NSDictionary,
        itemID: ItemID,
        facet: ContentFacet,
        in context: NSManagedObjectContext
    ) throws -> ContentRef? {
        do {
            try ensureVisible(item: item, itemID: itemID, facet: facet, in: context)
        } catch StoreError.notFound {
            return nil
        }
        switch facet {
        case .history:
            guard let captureID = item["captureID"] as? UUID,
                  let capture = try captureMetadata(captureID, in: context),
                  let digest = capture["digest"] as? Data else { return nil }
            return ContentRef(
                itemID: itemID,
                facet: .history,
                version: ContentVersion(rawValue: captureID),
                digest: digest
            )
        case .memo:
            guard let memoID = item["memoID"] as? UUID,
                  let memo = try memoMetadata(memoID, in: context),
                  memo["itemID"] as? UUID == itemID.rawValue,
                  let rawMode = memo["bodyMode"] as? String,
                  let mode = MemoBodyMode(rawValue: rawMode) else { return nil }
            switch mode {
            case .inheritedCapture:
                guard memo["version"] == nil,
                      memo["digest"] == nil,
                      try !hasBody(memoID: memoID, in: context) else {
                    throw StoreError.corruptStore
                }
                guard let captureID = item["captureID"] as? UUID,
                      let capture = try captureMetadata(captureID, in: context),
                      let digest = capture["digest"] as? Data else { return nil }
                return ContentRef(
                    itemID: itemID,
                    facet: .memo,
                    version: ContentVersion(rawValue: captureID),
                    digest: digest
                )
            case .ownedPlainText, .ownedMarkdown:
                guard try hasBody(memoID: memoID, in: context),
                      let version = memo["version"] as? UUID,
                      let digest = memo["digest"] as? Data else { return nil }
                return ContentRef(
                    itemID: itemID,
                    facet: .memo,
                    version: ContentVersion(rawValue: version),
                    digest: digest
                )
            }
        }
    }

    static func ensureVisible(
        item: NSDictionary,
        itemID: ItemID,
        facet: ContentFacet,
        in context: NSManagedObjectContext
    ) throws {
        guard item["deletedAt"] == nil,
              try !hasRow(
                entity: "ItemDeletionMarker",
                predicate: NSPredicate(format: "id == %@", itemID.rawValue as NSUUID),
                in: context
              ) else { throw StoreError.notFound }

        let generationID: UUID
        switch facet {
        case .history:
            guard try bool(item, "historyEligible"),
                  item["historyDeletedAt"] == nil,
                  let captureID = item["captureID"] as? UUID else { throw StoreError.notFound }
            generationID = captureID
        case .memo:
            guard let memoID = item["memoID"] as? UUID else { throw StoreError.notFound }
            generationID = memoID
            if let memo = try memoMetadata(memoID, in: context), memo["deletedAt"] != nil {
                throw StoreError.notFound
            }
        }
        guard try !hasRow(
            entity: "FacetDeletionMarker",
            predicate: NSPredicate(
                format: "itemID == %@ AND facet == %@ AND generationID == %@",
                itemID.rawValue as NSUUID,
                facet.rawValue,
                generationID as NSUUID
            ),
            in: context
        ) else { throw StoreError.notFound }
    }

    static func resolveCapture(
        ref: ContentRef,
        captureID: UUID,
        in context: NSManagedObjectContext
    ) throws -> ResolvedContent {
        let capture: CaptureValue
        do {
            capture = try captureValue(captureID, in: context)
        } catch CaptureReadFailure.missing, CaptureReadFailure.recovering {
            return incomplete(ref, .recovering)
        } catch {
            return incomplete(ref, .corrupt)
        }
        guard capture.digest == ref.digest else { throw StoreError.staleReference }

        var resolved: [RepresentationValue] = []
        var requiresRelocation = false
        for var representation in capture.representations {
            guard representation.storage == .localReference else {
                resolved.append(representation)
                continue
            }
            let accessRequest = dictionaryRequest(
                entity: "FileAccessRecord",
                properties: ["id", "snapshotID", "bytes"],
                predicate: NSPredicate(format: "id == %@", representation.id as NSUUID)
            )
            accessRequest.fetchLimit = 2
            let access = try context.fetch(accessRequest)
            guard access.count <= 1 else { return incomplete(ref, .corrupt) }
            guard let row = access.first else {
                requiresRelocation = true
                resolved.append(representation)
                continue
            }
            guard row["snapshotID"] as? UUID == captureID,
                  let localBytes = row["bytes"] as? Data,
                  Int64(localBytes.count) == representation.byteCount,
                  ContentDigest.sha256(localBytes) == representation.digest else {
                return incomplete(ref, .corrupt)
            }
            representation.bytes = localBytes
            resolved.append(representation)
        }
        guard !requiresRelocation else { return incomplete(ref, .requiresRelocation) }
        return ResolvedContent(ref: ref, integrity: .complete, representations: resolved)
    }

    static func captureValue(_ id: UUID, in context: NSManagedObjectContext) throws -> CaptureValue {
        guard let captureObject = try object(.capture(id), in: context) else {
            throw CaptureReadFailure.missing
        }
        guard captureObject.value(forKey: "id") as? UUID == id,
              let manifestData = captureObject.value(forKey: "manifest") as? Data,
              let storedDigest = captureObject.value(forKey: "digest") as? Data else {
            throw CaptureReadFailure.recovering
        }
        let manifest: CaptureManifest
        do {
            manifest = try decodeManifest(manifestData)
            guard try manifest.canonicalData() == manifestData,
                  ContentDigest.sha256(manifestData) == storedDigest else {
                throw CaptureReadFailure.corrupt
            }
        } catch let error as CaptureReadFailure {
            throw error
        } catch {
            throw CaptureReadFailure.corrupt
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "snapshotID == %@", id as NSUUID)
        request.sortDescriptors = [
            NSSortDescriptor(key: "itemIndex", ascending: true),
            NSSortDescriptor(key: "representationIndex", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        let objects = try context.fetch(request)
        guard let related = captureObject.value(forKey: "representations") as? NSSet else {
            throw CaptureReadFailure.corrupt
        }
        let relatedObjects = related.compactMap { $0 as? NSManagedObject }
        guard relatedObjects.count == related.count,
              Set(relatedObjects.map(\.objectID)) == Set(objects.map(\.objectID)) else {
            throw CaptureReadFailure.corrupt
        }

        let values: [RepresentationValue]
        do {
            values = try objects.map { object in
                guard let snapshot = object.value(forKey: "snapshot") as? NSManagedObject,
                      snapshot.objectID == captureObject.objectID,
                      let storageRaw = object.value(forKey: "storage") as? String,
                      let storage = RepresentationStorage(rawValue: storageRaw) else {
                    throw CaptureReadFailure.corrupt
                }
                return RepresentationValue(
                    id: try required(object, "id"),
                    snapshotID: try required(object, "snapshotID"),
                    itemIndex: try exactInt(object, "itemIndex"),
                    representationIndex: try exactInt(object, "representationIndex"),
                    typeIdentifier: try required(object, "typeIdentifier"),
                    storage: storage,
                    byteCount: try int64(object, "byteCount"),
                    digest: try required(object, "digest"),
                    bytes: object.value(forKey: "bytes") as? Data
                )
            }
        } catch let error as CaptureReadFailure {
            throw error
        } catch {
            throw CaptureReadFailure.corrupt
        }

        switch manifest.validate(values, snapshotID: id) {
        case .complete:
            return CaptureValue(id: id, manifest: manifest, digest: storedDigest, representations: values)
        case .recovering:
            throw CaptureReadFailure.recovering
        case .corrupt, .requiresRelocation:
            throw CaptureReadFailure.corrupt
        }
    }

    static func incomplete(_ ref: ContentRef, _ integrity: ContentIntegrity) -> ResolvedContent {
        ResolvedContent(ref: ref, integrity: integrity, representations: [])
    }

    static func decodeManifest(_ data: Data) throws -> CaptureManifest {
        do { return try JSONDecoder().decode(CaptureManifest.self, from: data) }
        catch { throw StoreError.corruptStore }
    }

    static func uniqueDictionary(
        entity: String,
        properties: [String],
        predicate: NSPredicate,
        in context: NSManagedObjectContext
    ) throws -> NSDictionary? {
        let request = dictionaryRequest(entity: entity, properties: properties, predicate: predicate)
        request.fetchLimit = 2
        let rows = try context.fetch(request)
        guard rows.count <= 1 else { throw StoreError.corruptStore }
        return rows.first
    }

    static func dictionaryRequest(
        entity: String,
        properties: [String],
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor]? = nil
    ) -> NSFetchRequest<NSDictionary> {
        let request = NSFetchRequest<NSDictionary>(entityName: entity)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = properties
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        request.includesPendingChanges = false
        return request
    }

    static func hasRow(
        entity: String,
        predicate: NSPredicate,
        in context: NSManagedObjectContext
    ) throws -> Bool {
        let request = NSFetchRequest<NSFetchRequestResult>(entityName: entity)
        request.predicate = predicate
        request.fetchLimit = 1
        request.includesPendingChanges = false
        return try context.count(for: request) > 0
    }

    static func digest<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .deferredToDate
        return ContentDigest.sha256(try encoder.encode(value))
    }

    static func required<T>(_ object: NSManagedObject, _ key: String) throws -> T {
        guard let value = object.value(forKey: key) as? T else { throw StoreError.corruptStore }
        return value
    }

    static func required<T>(_ dictionary: NSDictionary, _ key: String) throws -> T {
        guard let value = dictionary[key] as? T else { throw StoreError.corruptStore }
        return value
    }

    static func int64(_ object: NSManagedObject, _ key: String) throws -> Int64 {
        guard let value = object.value(forKey: key) as? NSNumber else { throw StoreError.corruptStore }
        return value.int64Value
    }

    static func int64(_ dictionary: NSDictionary, _ key: String) throws -> Int64 {
        guard let value = dictionary[key] as? NSNumber else { throw StoreError.corruptStore }
        return value.int64Value
    }

    static func exactInt(_ object: NSManagedObject, _ key: String) throws -> Int {
        let value = try int64(object, key)
        guard let result = Int(exactly: value) else { throw StoreError.corruptStore }
        return result
    }

    static func bool(_ object: NSManagedObject, _ key: String) throws -> Bool {
        guard let value = object.value(forKey: key) as? NSNumber else { throw StoreError.corruptStore }
        return value.boolValue
    }

    static func bool(_ dictionary: NSDictionary, _ key: String) throws -> Bool {
        guard let value = dictionary[key] as? NSNumber else { throw StoreError.corruptStore }
        return value.boolValue
    }

    static func double(_ object: NSManagedObject, _ key: String) throws -> Double {
        guard let value = object.value(forKey: key) as? NSNumber else { throw StoreError.corruptStore }
        return value.doubleValue
    }
}

private enum CaptureReadFailure: Error {
    case missing
    case recovering
    case corrupt
}

private struct ReadProjection {
    let items: [NSDictionary]
    let itemMarkerIDs: Set<UUID>
    let facetMarkers: Set<ProjectedFacet>
    let captures: [UUID: NSDictionary]
    let memos: [UUID: NSDictionary]
    let memoIDsWithBody: Set<UUID>
}

private struct ProjectedFacet: Hashable {
    let itemID: UUID
    let facet: ContentFacet
    let generationID: UUID
}

private struct ValidatedItemMetadata {
    let id: ItemID
    let title: String
    let captureID: UUID?
    let memoID: UUID?
    let historyEligible: Bool
    let historyDeletedAt: Date?
    let deletedAt: Date?
    let lastCopiedAt: Date
}

private struct CaptureFingerprint: Encodable {
    let id: UUID
    let digest: Data
    let representations: [RepresentationFingerprint]
}

private struct RepresentationFingerprint: Encodable {
    let id: UUID
    let snapshotID: UUID
    let itemIndex: Int
    let representationIndex: Int
    let typeIdentifierBytes: Data
    let storage: RepresentationStorage
    let byteCount: Int64
    let digest: Data

    init(_ value: RepresentationValue) {
        id = value.id
        snapshotID = value.snapshotID
        itemIndex = value.itemIndex
        representationIndex = value.representationIndex
        typeIdentifierBytes = Data(value.typeIdentifier.utf8)
        storage = value.storage
        byteCount = value.byteCount
        digest = value.digest
    }
}

private struct MemoFingerprint: Encodable {
    let id: UUID
    let itemID: UUID
    let title: String
    let bodyMode: MemoBodyMode
    let sourceRepresentationTypeBytes: Data?
    let version: UUID?
    let digest: Data?
    let languageHint: String?
    let note: String
    let deletedAt: Date?
    let purgeAfter: Date?
    let bodyPresent: Bool

    init(_ row: NSDictionary, bodyPresent: Bool) throws {
        id = try StoredRecords.required(row, "id")
        itemID = try StoredRecords.required(row, "itemID")
        title = try StoredRecords.required(row, "title")
        guard let rawMode: String = try? StoredRecords.required(row, "bodyMode"),
              let bodyMode = MemoBodyMode(rawValue: rawMode) else {
            throw StoreError.corruptStore
        }
        self.bodyMode = bodyMode
        let sourceRepresentationType: String? = try StoredRecords.optional(row, "sourceRepresentationType")
        sourceRepresentationTypeBytes = sourceRepresentationType.map {
            Data($0.utf8)
        }
        version = try StoredRecords.optional(row, "version")
        digest = try StoredRecords.optional(row, "digest")
        languageHint = try StoredRecords.optional(row, "languageHint")
        note = try StoredRecords.required(row, "note")
        deletedAt = try StoredRecords.optional(row, "deletedAt")
        purgeAfter = try StoredRecords.optional(row, "purgeAfter")
        self.bodyPresent = bodyPresent
        guard deletedAt?.timeIntervalSinceReferenceDate.isFinite ?? true,
              purgeAfter?.timeIntervalSinceReferenceDate.isFinite ?? true else {
            throw StoreError.corruptStore
        }
        switch bodyMode {
        case .inheritedCapture:
            guard !bodyPresent, version == nil, digest == nil else { throw StoreError.corruptStore }
        case .ownedPlainText, .ownedMarkdown:
            guard bodyPresent, version != nil, digest?.count == 32 else { throw StoreError.corruptStore }
        }
    }
}

private struct ReferenceFingerprint: Encodable {
    let items: [ReferenceItemMetadata]
    let memos: [ReferenceMemoMetadata]
}

private struct ReferenceItemMetadata: Encodable {
    let id: UUID
    let captureID: UUID?
    let memoID: UUID?
    let historyEligible: Bool
    let historyDeletedAt: Date?
    let deletedAt: Date?

    init(_ row: NSDictionary) throws {
        id = try StoredRecords.required(row, "id")
        captureID = row["captureID"] as? UUID
        memoID = row["memoID"] as? UUID
        historyEligible = try StoredRecords.bool(row, "historyEligible")
        historyDeletedAt = row["historyDeletedAt"] as? Date
        deletedAt = row["deletedAt"] as? Date
    }
}

private struct ReferenceMemoMetadata: Encodable {
    let id: UUID
    let itemID: UUID
    let bodyMode: String
    let version: UUID?
    let digest: Data?
    let deletedAt: Date?

    init(_ row: NSDictionary) throws {
        id = try StoredRecords.required(row, "id")
        itemID = try StoredRecords.required(row, "itemID")
        bodyMode = try StoredRecords.required(row, "bodyMode")
        version = row["version"] as? UUID
        digest = row["digest"] as? Data
        deletedAt = row["deletedAt"] as? Date
    }
}
