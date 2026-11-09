import CoreData
import Foundation

/// What a derived text was made by.
enum DerivedTextOperation: String, Codable, Sendable {
    /// Text recognized in an image.
    case extractText
    case translate
}

/// How whole a saved result is.
enum DerivedTextStatus: String, Codable, Sendable {
    case complete
    /// A person stopped it before it was whole.
    case stopped
    /// It reached the output's length limit and is cut off.
    case truncated
}

/// What a generation was asked to make: one operation on one item's content as it was then, with its parameters.
struct DerivedTextRequest: Equatable, Sendable {
    /// The item's content, version and digest included.
    var source: ContentRef
    var operation: DerivedTextOperation
    /// BCP-47 codes, where the operation has languages.
    var sourceLanguage: String?
    var targetLanguage: String?
    /// For recognized text: whether it keeps the image's line breaks or joins its lines into paragraphs.
    var keepsLineBreaks: Bool

    init(source: ContentRef, operation: DerivedTextOperation, sourceLanguage: String? = nil,
         targetLanguage: String? = nil, keepsLineBreaks: Bool = false) {
        self.source = source
        self.operation = operation
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.keepsLineBreaks = keepsLineBreaks
    }
}

/// Text recognized in or translated from an item, kept on this Mac beside the item it came from. It is derived data:
/// it is never mirrored to iCloud or exported, it shows only while its item is current and unchanged, and clearing it
/// leaves the item as it was.
struct DerivedText: Equatable, Sendable {
    let id: UUID
    /// The item's content it was made from, version and digest included.
    let source: ContentRef
    let operation: DerivedTextOperation
    let status: DerivedTextStatus
    /// The engine as people see it, such as "On this Mac" or "Claude Haiku 5.5".
    let engine: String
    /// The provider's model identifier, or the engine's revision.
    let model: String?
    let sourceLanguage: String?
    let targetLanguage: String?
    let keepsLineBreaks: Bool
    let text: String
    /// SHA-256 of `text` in UTF-8. A paste checks it, so a result replaced meanwhile is never pasted in its place.
    let textDigest: Data
    let usage: GenerationUsage?
    /// Identifies the generation on this Mac only.
    let requestID: UUID
    let createdAt: Date
}

/// The results kept beside items in the library's local store: one per item, facet and operation, so that a new result
/// replaces the old one rather than piling up. A result is bound to its item's content as it was: while the item is in
/// Recently Deleted, after it changed, or under another store generation, there is no result for it, and the item's
/// permanent deletion removes its results in the same local transaction as its other local records.
final class DerivedTextStore: @unchecked Sendable {
    private let controller: PersistenceController

    init(controller: PersistenceController) {
        self.controller = controller
    }

    /// Saves the final snapshot of a generation for `request`, once, as `snapshot.saveDecision` says: a whole result
    /// replaces any earlier one; a result a person stopped, or one cut off, is kept only while the item has no whole
    /// result for this content, whatever language that result is in, so a new translation that does not finish leaves
    /// the earlier one; anything else is not kept. Nothing is kept for an item that changed or went while it was
    /// generated, nor under another store generation than `expectedIdentity`, the one the content was read in: a late
    /// result never lands on other content. Returns what was saved, or nil.
    @discardableResult
    func save(_ snapshot: GenerationSnapshot, for request: DerivedTextRequest, channel: OutputChannel = .main,
              at now: Date = Date(), expecting expectedIdentity: StoreIdentity? = nil) async throws -> DerivedText? {
        let decision = snapshot.saveDecision
        let text = snapshot.text(channel)
        guard decision != .discard, !text.isEmpty else { return nil }
        guard let info = snapshot.info, now.timeIntervalSinceReferenceDate.isFinite else {
            throw StoreError.invalidTransaction
        }
        let status: DerivedTextStatus = switch snapshot.phase {
        case .finished(.completed): .complete
        case .finished(.truncated): .truncated
        default: .stopped
        }
        // Usage with no count in it is no usage, as a read gives it back.
        let usage = snapshot.usage.flatMap { $0.inputTokens == nil && $0.outputTokens == nil ? nil : $0 }
        let result = DerivedText(
            id: UUID(), source: request.source, operation: request.operation, status: status, engine: info.engine,
            model: info.model, sourceLanguage: request.sourceLanguage, targetLanguage: request.targetLanguage,
            keepsLineBreaks: request.keepsLineBreaks, text: text, textDigest: ContentDigest.sha256(Data(text.utf8)),
            usage: usage, requestID: info.requestID, createdAt: now
        )
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try StoreSafetyGate.validate(.projection, runtime: controller.runtime)
            let identity = controller.runtime.identity
            if let expectedIdentity, expectedIdentity != identity { return nil }
            guard try Self.isCurrent(request.source, in: context) else { return nil }
            let existing = try Self.objects(itemID: request.source.itemID, facet: request.source.facet,
                                            operation: request.operation, in: context)
            if decision == .keepIfNoCompleteResult,
               existing.contains(where: { Self.isWholeResult($0, of: request.source, under: identity) }) {
                return nil
            }
            do {
                // Every earlier row goes, an unreadable one too: one result per item and operation.
                existing.forEach(context.delete)
                Self.insert(result, under: identity, into: context)
                try context.save()
            } catch {
                context.rollback()
                throw error
            }
            return result
        }
    }

    /// The result of `operation` for exactly this content of an item, while the item is current: not in Recently
    /// Deleted, not expired, and unchanged since the result was made. Nil otherwise.
    func result(for source: ContentRef, operation: DerivedTextOperation) async throws -> DerivedText? {
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            guard try Self.isCurrent(source, in: context) else { return nil }
            let identity = controller.runtime.identity
            for object in try Self.objects(itemID: source.itemID, facet: source.facet, operation: operation,
                                           in: context) where Self.isWritten(object, under: identity) {
                // A row that cannot be read is derived data the next result replaces: it is no result, and the item's
                // other results stay readable.
                guard let result = try? Self.result(from: object) else { continue }
                if result.source == source { return result }
            }
            return nil
        }
    }

    /// Which of these sources have a whole result of the operation, for exactly their content, in this store
    /// generation: what the cards say of their items, read for the cards on screen at once. One fetch finds the rows of
    /// all the items; only an item with a whole result is checked for being current. A row that can't be read, or an
    /// item that can't be checked, is no result, and the others still count.
    func sourcesWithWholeResults(_ sources: [ContentRef],
                                 operation: DerivedTextOperation) async throws -> Set<ContentRef> {
        let wanted = Set(sources)
        guard !wanted.isEmpty else { return [] }
        let itemIDs = Set(wanted.map(\.itemID.rawValue)).map { $0 as NSUUID }
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            let identity = controller.runtime.identity
            let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
            request.predicate = NSPredicate(format: "itemID IN %@ AND operation == %@", itemIDs, operation.rawValue)
            var found: Set<ContentRef> = []
            for object in try context.fetch(request) {
                guard let kept = try? Self.result(from: object), wanted.contains(kept.source),
                      !found.contains(kept.source), Self.isWholeResult(object, of: kept.source, under: identity),
                      (try? Self.isCurrent(kept.source, in: context)) == true else { continue }
                found.insert(kept.source)
            }
            return found
        }
    }

    /// Settings' Clear Saved Results…: every result goes, and the items they came from stay as they are. Returns how
    /// many went.
    @discardableResult
    func removeAll() async throws -> Int {
        let controller = controller
        return try await controller.perform { context in
            context.reset()
            defer { context.reset() }
            try StoreSafetyGate.validate(.projection, runtime: controller.runtime)
            do {
                let objects = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DerivedText"))
                objects.forEach(context.delete)
                if context.hasChanges { try context.save() }
                return objects.count
            } catch {
                context.rollback()
                throw error
            }
        }
    }

    /// Queue-confined permanent cleanup, beside the item's other local records. The caller saves or rolls back the
    /// surrounding LocalState transaction. No item-wide wildcard is accepted: only the facets named go.
    static func stageExactCleanup(itemID: ItemID, facets: Set<ContentFacet>,
                                  in context: NSManagedObjectContext) throws -> Int {
        var removed = 0
        for facet in facets {
            let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
            request.predicate = NSPredicate(format: "itemID == %@ AND facet == %@", itemID.rawValue as NSUUID,
                                            facet.rawValue)
            let matches = try context.fetch(request)
            matches.forEach(context.delete)
            removed += matches.count
        }
        return removed
    }

    // MARK: Rows

    /// Whether `source` is the item's current content: visible, and of the same version and digest.
    private static func isCurrent(_ source: ContentRef, in context: NSManagedObjectContext) throws -> Bool {
        do {
            return try StoredRecords.currentRef(itemID: source.itemID, facet: source.facet, in: context) == source
        } catch StoreError.notFound, StoreError.staleReference {
            return false
        }
    }

    private static func objects(itemID: ItemID, facet: ContentFacet, operation: DerivedTextOperation,
                                in context: NSManagedObjectContext) throws -> [NSManagedObject] {
        let request = NSFetchRequest<NSManagedObject>(entityName: "DerivedText")
        request.predicate = NSPredicate(format: "itemID == %@ AND facet == %@ AND operation == %@",
                                        itemID.rawValue as NSUUID, facet.rawValue, operation.rawValue)
        return try context.fetch(request)
    }

    /// Whether `object` is a whole result for exactly `source`, written in this store generation and readable.
    private static func isWholeResult(_ object: NSManagedObject, of source: ContentRef,
                                      under identity: StoreIdentity) -> Bool {
        guard isWritten(object, under: identity), let kept = try? result(from: object) else { return false }
        return kept.status == .complete && kept.source == source
    }

    private static func isWritten(_ object: NSManagedObject, under identity: StoreIdentity) -> Bool {
        object.value(forKey: "storeID") as? UUID == identity.storeID
            && object.value(forKey: "storeGeneration") as? UUID == identity.generation
    }

    private static func insert(_ result: DerivedText, under identity: StoreIdentity,
                               into context: NSManagedObjectContext) {
        let object = NSEntityDescription.insertNewObject(forEntityName: "DerivedText", into: context)
        object.setValue(result.id, forKey: "id")
        object.setValue(identity.storeID, forKey: "storeID")
        object.setValue(identity.generation, forKey: "storeGeneration")
        object.setValue(result.source.itemID.rawValue, forKey: "itemID")
        object.setValue(result.source.facet.rawValue, forKey: "facet")
        object.setValue(result.source.version.rawValue, forKey: "sourceVersion")
        object.setValue(result.source.digest, forKey: "sourceDigest")
        object.setValue(result.operation.rawValue, forKey: "operation")
        object.setValue(result.status.rawValue, forKey: "status")
        object.setValue(result.engine, forKey: "engine")
        object.setValue(result.model, forKey: "model")
        object.setValue(result.sourceLanguage, forKey: "sourceLanguage")
        object.setValue(result.targetLanguage, forKey: "targetLanguage")
        object.setValue(result.keepsLineBreaks, forKey: "keepsLineBreaks")
        object.setValue(Data(result.text.utf8), forKey: "text")
        object.setValue(result.textDigest, forKey: "textDigest")
        object.setValue(result.usage?.inputTokens.map { Int64($0) }, forKey: "inputTokens")
        object.setValue(result.usage?.outputTokens.map { Int64($0) }, forKey: "outputTokens")
        object.setValue(result.requestID, forKey: "requestID")
        object.setValue(result.createdAt, forKey: "createdAt")
    }

    /// The stored row as a value. A row whose text does not match its digest, or that misses what every result has,
    /// is corrupt.
    private static func result(from object: NSManagedObject) throws -> DerivedText {
        guard let id = object.value(forKey: "id") as? UUID,
              let itemID = object.value(forKey: "itemID") as? UUID,
              let facet = (object.value(forKey: "facet") as? String).flatMap(ContentFacet.init(rawValue:)),
              let version = object.value(forKey: "sourceVersion") as? UUID,
              let sourceDigest = object.value(forKey: "sourceDigest") as? Data,
              let operation = (object.value(forKey: "operation") as? String).flatMap(DerivedTextOperation.init(rawValue:)),
              let status = (object.value(forKey: "status") as? String).flatMap(DerivedTextStatus.init(rawValue:)),
              let engine = object.value(forKey: "engine") as? String,
              let bytes = object.value(forKey: "text") as? Data,
              let text = String(data: bytes, encoding: .utf8),
              let textDigest = object.value(forKey: "textDigest") as? Data,
              textDigest == ContentDigest.sha256(bytes),
              let requestID = object.value(forKey: "requestID") as? UUID,
              let createdAt = object.value(forKey: "createdAt") as? Date else {
            throw StoreError.corruptStore
        }
        let inputTokens = (object.value(forKey: "inputTokens") as? Int64).map { Int($0) }
        let outputTokens = (object.value(forKey: "outputTokens") as? Int64).map { Int($0) }
        return DerivedText(
            id: id,
            source: ContentRef(itemID: ItemID(rawValue: itemID), facet: facet,
                               version: ContentVersion(rawValue: version), digest: sourceDigest),
            operation: operation, status: status, engine: engine, model: object.value(forKey: "model") as? String,
            sourceLanguage: object.value(forKey: "sourceLanguage") as? String,
            targetLanguage: object.value(forKey: "targetLanguage") as? String,
            keepsLineBreaks: object.value(forKey: "keepsLineBreaks") as? Bool ?? false, text: text,
            textDigest: textDigest,
            usage: inputTokens == nil && outputTokens == nil
                ? nil : GenerationUsage(inputTokens: inputTokens, outputTokens: outputTokens),
            requestID: requestID, createdAt: createdAt
        )
    }
}
