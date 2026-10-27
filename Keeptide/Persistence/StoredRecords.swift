import CoreData
import Foundation

/// Queue-confined Core Data mapping and integrity checks. Every entry point must
/// be called synchronously from the supplied context's queue.
enum StoredRecords {
    static func object(_ key: RecordKey, in context: NSManagedObjectContext) throws -> NSManagedObject? {
        let request = NSFetchRequest<NSManagedObject>(entityName: key.entity)
        request.predicate = NSPredicate(format: "id == %@", key.id as NSUUID)
        request.fetchLimit = 2
        let matches = try context.fetch(request)
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
        let request = dictionaryRequest(
            entity: "LibraryItem",
            properties: itemMetadataProperties,
            predicate: NSPredicate(format: "deletedAt == nil"),
            sortDescriptors: [
                NSSortDescriptor(key: "lastCopiedAt", ascending: false),
                NSSortDescriptor(key: "id", ascending: true)
            ]
        )
        request.fetchLimit = limit
        let rows = try context.fetch(request)
        return try rows.map { row in
            let itemID = ItemID(rawValue: try required(row, "id"))
            return ItemSummary(
                itemID: itemID,
                title: try required(row, "title"),
                lastCopiedAt: try required(row, "lastCopiedAt"),
                history: try currentRef(item: row, itemID: itemID, facet: .history, in: context),
                memo: try currentRef(item: row, itemID: itemID, facet: .memo, in: context)
            )
        }
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
            return try resolveCapture(ref: ref, captureID: captureID, metadata: capture, in: context)

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
                return try resolveCapture(ref: ref, captureID: captureID, metadata: capture, in: context)

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

    static func fingerprint(_ key: RecordKey, in context: NSManagedObjectContext) throws -> Data {
        guard let value = try value(key, in: context) else { throw StoreError.notFound }
        return try digest(value)
    }

    static func candidateFingerprint(in context: NSManagedObjectContext) throws -> Data {
        let request = dictionaryRequest(
            entity: "LibraryItem",
            properties: itemMetadataProperties,
            predicate: NSPredicate(
                format: "deletedAt == nil AND historyEligible == YES AND historyDeletedAt == nil AND captureID != nil"
            ),
            sortDescriptors: [NSSortDescriptor(key: "id", ascending: true)]
        )
        let refs = try context.fetch(request).compactMap { row -> ContentRef? in
            let itemID = ItemID(rawValue: try required(row, "id"))
            return try currentRef(item: row, itemID: itemID, facet: .history, in: context)
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
        let itemIDs = try itemRows.map { try required($0, "id") as UUID }

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
                guard let version = memo["version"] as? UUID,
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
        metadata: NSDictionary,
        in context: NSManagedObjectContext
    ) throws -> ResolvedContent {
        guard let manifestData = metadata["manifest"] as? Data else {
            return incomplete(ref, .recovering)
        }
        let manifest: CaptureManifest
        do {
            manifest = try decodeManifest(manifestData)
            guard try manifest.canonicalData() == manifestData,
                  ContentDigest.sha256(manifestData) == ref.digest else {
                return incomplete(ref, .corrupt)
            }
        } catch {
            return incomplete(ref, .corrupt)
        }

        let request = NSFetchRequest<NSManagedObject>(entityName: "CaptureRepresentation")
        request.predicate = NSPredicate(format: "snapshotID == %@", captureID as NSUUID)
        request.sortDescriptors = [
            NSSortDescriptor(key: "itemIndex", ascending: true),
            NSSortDescriptor(key: "representationIndex", ascending: true),
            NSSortDescriptor(key: "id", ascending: true)
        ]
        let objects = try context.fetch(request)
        guard let captureObject = try StoredRecords.object(.capture(captureID), in: context) else {
            return incomplete(ref, .recovering)
        }
        guard let related = captureObject.value(forKey: "representations") as? NSSet else {
            return incomplete(ref, .corrupt)
        }
        let relatedIDs = Set(related.compactMap { ($0 as? NSManagedObject)?.objectID })
        guard relatedIDs.count == related.count,
              relatedIDs == Set(objects.map(\.objectID)) else {
            return incomplete(ref, .corrupt)
        }
        var values: [RepresentationValue] = []
        var ids = Set<UUID>()
        for object in objects {
            guard let id = object.value(forKey: "id") as? UUID,
                  ids.insert(id).inserted,
                  let relatedSnapshot = object.value(forKey: "snapshot") as? NSManagedObject,
                  relatedSnapshot.objectID == captureObject.objectID else {
                return incomplete(ref, .corrupt)
            }
            guard let storageRaw = object.value(forKey: "storage") as? String,
                  let storage = RepresentationStorage(rawValue: storageRaw),
                  let snapshotID = object.value(forKey: "snapshotID") as? UUID,
                  let type = object.value(forKey: "typeIdentifier") as? String,
                  let digest = object.value(forKey: "digest") as? Data else {
                return incomplete(ref, .corrupt)
            }
            let itemIndex: Int
            let representationIndex: Int
            let byteCount: Int64
            do {
                itemIndex = try exactInt(object, "itemIndex")
                representationIndex = try exactInt(object, "representationIndex")
                byteCount = try int64(object, "byteCount")
            } catch {
                return incomplete(ref, .corrupt)
            }
            var bytes = object.value(forKey: "bytes") as? Data
            if storage == .localReference {
                guard bytes == nil else { return incomplete(ref, .corrupt) }
                let accessRequest = dictionaryRequest(
                    entity: "FileAccessRecord",
                    properties: ["id", "snapshotID", "bytes"],
                    predicate: NSPredicate(format: "id == %@", id as NSUUID)
                )
                accessRequest.fetchLimit = 2
                let access = try context.fetch(accessRequest)
                guard access.count <= 1 else { return incomplete(ref, .corrupt) }
                guard let row = access.first else { return incomplete(ref, .requiresRelocation) }
                guard row["snapshotID"] as? UUID == captureID,
                      let localBytes = row["bytes"] as? Data,
                      Int64(localBytes.count) == byteCount,
                      ContentDigest.sha256(localBytes) == digest else {
                    return incomplete(ref, .corrupt)
                }
                bytes = localBytes
            }
            values.append(RepresentationValue(
                id: id,
                snapshotID: snapshotID,
                itemIndex: itemIndex,
                representationIndex: representationIndex,
                typeIdentifier: type,
                storage: storage,
                byteCount: byteCount,
                digest: digest,
                bytes: bytes
            ))
        }

        let integrity = manifest.validate(values.map { value in
            guard value.storage == .localReference else { return value }
            var manifestValue = value
            manifestValue.bytes = nil
            return manifestValue
        }, snapshotID: captureID)
        guard integrity == .complete else { return incomplete(ref, integrity) }
        guard values.allSatisfy({ value in
            guard let bytes = value.bytes else { return false }
            return Int64(bytes.count) == value.byteCount && ContentDigest.sha256(bytes) == value.digest
        }) else { return incomplete(ref, .recovering) }
        return ResolvedContent(ref: ref, integrity: .complete, representations: values)
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
        encoder.dateEncodingStrategy = .millisecondsSince1970
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
