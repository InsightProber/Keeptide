import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum ExportProgress: Equatable, Sendable {
    case preparing
    case writing(completedEntries: Int)
    case verifying
    case publishing
}

struct ExportRequest: Sendable {
    var scope: SnapshotScope
    var destinationParent: URL
    var pageSize: Int
    var leaseLifetime: TimeInterval

    init(scope: SnapshotScope, destinationParent: URL, pageSize: Int = 1, leaseLifetime: TimeInterval = 3600) {
        self.scope = scope
        self.destinationParent = destinationParent
        self.pageSize = pageSize
        self.leaseLifetime = leaseLifetime
    }
}

struct ExportResult: Equatable, Sendable {
    let destination: URL
    let verification: ArchiveVerification
}

enum ExportError: Error, Equatable, Sendable {
    case cancelled
    case diskWriteFailed
    case changedSelection
    case snapshotExpired
    case destinationExists
    case unsupportedDestination
    case verificationFailed
    case unknown
}

protocol Exporting: Sendable {
    func export(_ request: ExportRequest,
                progress: @escaping @Sendable (ExportProgress) -> Void) async throws -> ExportResult
}

struct ExportService: Exporting, Sendable {
    private let reader: ContentSnapshotReader
    private let permitProvider: @Sendable () async throws -> StorePermit
    private let verify: @Sendable (URL) async throws -> ArchiveVerification
    private let now: @Sendable () -> Date
    private let makeID: @Sendable () -> UUID
    private let writeBytes: StagedArchiveWriter.WriteBytes
    private let expectedIdentity: StoreIdentity?

    init(controller: PersistenceController, expecting expectedIdentity: StoreIdentity? = nil) {
        reader = ContentSnapshotReader(controller: controller)
        permitProvider = { try await StoreSafetyGate(controller: controller).permit(.completeArchive) }
        verify = { try await ArchiveVerifier().verify(at: $0) }
        now = Date.init
        makeID = UUID.init
        writeBytes = { try $0.write(contentsOf: $1) }
        self.expectedIdentity = expectedIdentity
    }

    init(reader: ContentSnapshotReader,
         permitProvider: @escaping @Sendable () async throws -> StorePermit,
         verify: @escaping @Sendable (URL) async throws -> ArchiveVerification,
         now: @escaping @Sendable () -> Date = Date.init,
         makeID: @escaping @Sendable () -> UUID = UUID.init,
         writeBytes: @escaping StagedArchiveWriter.WriteBytes = { try $0.write(contentsOf: $1) },
         expecting expectedIdentity: StoreIdentity? = nil) {
        self.reader = reader
        self.permitProvider = permitProvider
        self.verify = verify
        self.now = now
        self.makeID = makeID
        self.writeBytes = writeBytes
        self.expectedIdentity = expectedIdentity
    }

    func export(_ request: ExportRequest,
                progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) async throws -> ExportResult {
        progress(.preparing)
        let exportID = makeID(), createdAt = now()
        let destinationName = SafeExportName.exportDirectoryName(createdAt: createdAt, exportID: exportID)
        var writer: StagedArchiveWriter?
        var lease: SnapshotLease?
        do {
            try Task.checkCancellation()
            let permit = try await permitProvider()
            guard expectedIdentity == nil || expectedIdentity == permit.identity else {
                throw StoreError.preconditionFailed
            }
            let opened = try await reader.begin(SnapshotRequest(pageSize: request.pageSize, permit: permit,
                                                                 lifetime: request.leaseLifetime, scope: request.scope))
            lease = opened
            let archive = try StagedArchiveWriter(destinationParent: request.destinationParent,
                                                   destinationName: destinationName, stagingID: makeID(),
                                                   writeBytes: writeBytes)
            writer = archive
            var cursor: Data?
            var ordinal = 0
            var representationsByID: [UUID: ArchiveRepresentation] = [:]
            var payloadIDs = Set<UUID>()
            var readablePaths = Set<String>()
            var containsRelocation = false
            repeat {
                try Task.checkCancellation()
                let page = try await reader.page(opened, after: cursor)
                cursor = page.next
                for content in page.contents {
                    ordinal += 1
                    let entry = try makeEntry(content: content, records: page.portableRecords, ordinal: ordinal,
                                              writer: archive, payloadIDs: &payloadIDs,
                                              readablePaths: &readablePaths)
                    for representation in entry.representations {
                        var identity = representation
                        identity.readable = nil
                        if var existing = representationsByID[representation.id] {
                            existing.readable = nil
                            guard existing == identity else { throw StoreError.snapshotUnavailable }
                        } else {
                            representationsByID[representation.id] = identity
                        }
                    }
                    containsRelocation = containsRelocation || entry.availability == .requiresFileRelocation
                    try archive.appendEntry(entry)
                    progress(.writing(completedEntries: ordinal))
                }
            } while cursor != nil

            let entries = try archive.finishEntries()
            let readme = try archive.write(Self.readmeData, relativePath: "README.txt")
            let scope = makeScope(request.scope, boundary: opened.boundary, exportedCount: ordinal)
            let manifest = ArchiveManifest(format: ArchiveManifest.currentFormat,
                schemaVersion: ArchiveManifest.currentSchemaVersion, createdAt: createdAt,
                source: ArchiveSource(token: .currentLocalSnapshot, label: ArchiveSourceKind.currentLocalSnapshot.publicLabel),
                scope: scope, exportID: exportID, snapshotBoundarySHA256: Self.hex(opened.boundary),
                expectedEntryCount: ordinal, expectedRepresentationCount: representationsByID.count,
                expectedPortablePayloadCount: payloadIDs.count, expectedReadableFileCount: readablePaths.count,
                containsFileReferencesRequiringRelocation: containsRelocation, readme: readme, entries: entries,
                verifierSchemaVersion: ArchiveManifest.currentVerifierSchemaVersion)
            try archive.writeManifest(manifest)
            try archive.preparePublication()
            try Task.checkCancellation()
            progress(.verifying)
            let verification = try await verify(archive.stagingURL)
            try Task.checkCancellation()
            progress(.publishing)
            let destination = try await reader.withValidatedLease(opened, permit: permit) {
                try archive.publish()
            }
            await reader.end(opened)
            lease = nil
            writer = nil
            return ExportResult(destination: destination, verification: verification)
        } catch {
            if let lease { await reader.end(lease) }
            writer?.cleanup()
            throw Self.publicError(error)
        }
    }
}

private extension ExportService {
    func makeEntry(content: ResolvedContent, records: [RecordValue], ordinal: Int,
                   writer: StagedArchiveWriter, payloadIDs: inout Set<UUID>,
                   readablePaths: inout Set<String>) throws -> ArchiveEntry {
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        guard case .item(let item)? = byKey[.item(content.ref.itemID)] else { throw StoreError.corruptStore }
        let memo: MemoValue? = item.memoID.flatMap { id in
            guard case .memo(let value)? = byKey[.memo(id)] else { return nil }; return value
        }
        let collection: CollectionValue? = item.collectionID.flatMap { id in
            guard case .collection(let value)? = byKey[.collection(id)] else { return nil }; return value
        }
        let capture: CaptureValue? = item.captureID.flatMap { id in
            guard case .capture(let value)? = byKey[.capture(id)] else { return nil }; return value
        }
        let ownedMemo = content.ref.facet == .memo && memo?.bodyMode != .inheritedCapture
        let values = ownedMemo ? content.representations : (capture?.representations ?? content.representations)
        let readable = ReadableExportEncoder().encode(content: content, records: records)
        let kind = classify(readable: readable, representations: values)
        let readablePath = readable.map { SafeExportName.readablePath(ordinal: ordinal, ref: content.ref, kind: $0.kind) }
        var archiveRepresentations: [ArchiveRepresentation] = []
        for value in values.sorted(by: { ($0.itemIndex, $0.representationIndex) < ($1.itemIndex, $1.representationIndex) }) {
            if value.storage == .localReference {
                archiveRepresentations.append(ArchiveRepresentation(id: value.id, itemIndex: value.itemIndex,
                    representationIndex: value.representationIndex, typeIdentifier: value.typeIdentifier,
                    storage: .localReference, byteCount: 0, digestSHA256: nil,
                    relocationTokenHex: Self.hex(value.digest), payloadPath: nil, readable: nil))
                continue
            }
            guard let bytes = value.bytes, Int64(bytes.count) == value.byteCount,
                  ContentDigest.sha256(bytes) == value.digest else { throw StoreError.snapshotUnavailable }
            let payloadPath = SafeExportName.payloadPath(for: value.id, typeIdentifier: value.typeIdentifier)
            if payloadIDs.insert(value.id).inserted { _ = try writer.write(bytes, relativePath: payloadPath) }
            var readableDigest: ArchiveFileDigest?
            if let readable, readable.representationID == value.id, let readablePath,
               readablePaths.insert(readablePath).inserted {
                readableDigest = try writer.write(readable.data, relativePath: readablePath)
            }
            archiveRepresentations.append(ArchiveRepresentation(id: value.id, itemIndex: value.itemIndex,
                representationIndex: value.representationIndex, typeIdentifier: value.typeIdentifier,
                storage: .portable, byteCount: value.byteCount, digestSHA256: Self.hex(value.digest),
                relocationTokenHex: nil, payloadPath: payloadPath, readable: readableDigest))
        }
        let availability: ArchiveAvailability = values.contains { $0.storage == .localReference }
            ? .requiresFileRelocation : .complete
        return ArchiveEntry(ordinal: ordinal, itemID: content.ref.itemID.rawValue,
            facet: content.ref.facet == .history ? .clipboardHistory : .memo,
            facetLabel: content.ref.facet == .history ? ArchiveFacetKind.clipboardHistory.publicLabel : ArchiveFacetKind.memo.publicLabel,
            contentVersion: content.ref.version.rawValue, contentDigestSHA256: Self.hex(content.ref.digest),
            origin: ownedMemo
                ? ArchiveContentOrigin(
                    kind: memo?.bodyMode == .ownedMarkdown ? .ownedMarkdown : .ownedPlainText,
                    captureManifestVersion: nil, captureItemCount: nil
                )
                : ArchiveContentOrigin(kind: .capture, captureManifestVersion: capture?.manifest.version,
                                       captureItemCount: capture?.manifest.itemCount),
            contentKind: kind, contentKindLabel: kind.publicLabel, availability: availability,
            availabilityLabel: availability.publicLabel, title: ownedMemo ? (memo?.title ?? item.title) : item.title,
            note: content.ref.facet == .memo ? memo?.note.nilIfEmpty : nil,
            sourceApplicationIdentifier: item.sourceApp,
            collection: collection.map { ArchiveCollection(id: $0.id.rawValue, name: $0.name, color: $0.color) },
            representations: archiveRepresentations)
    }

    func classify(readable: ReadableExport?, representations: [RepresentationValue]) -> ArchiveContentKind {
        if let readable { return readable.kind }
        for representation in representations where representation.storage == .portable {
            guard let type = UTType(representation.typeIdentifier) else { continue }
            if type.conforms(to: .image) { return .image }
        }
        if representations.contains(where: { $0.storage == .localReference }) { return .fileReference }
        return .other
    }

    func makeScope(_ scope: SnapshotScope, boundary: Data, exportedCount: Int) -> ArchiveScopeDescriptor {
        switch scope {
        case .allVisible:
            return ArchiveScopeDescriptor(kind: .allVisible, label: ArchiveScopeKind.allVisible.publicLabel,
                                          requestedRefCount: nil, selectedRefsSHA256: nil)
        case .selected:
            return ArchiveScopeDescriptor(kind: .selected, label: ArchiveScopeKind.selected.publicLabel,
                                          requestedRefCount: exportedCount, selectedRefsSHA256: Self.hex(boundary))
        }
    }

    static func publicError(_ error: Error) -> ExportError {
        if error is CancellationError { return .cancelled }
        if let error = error as? StagedArchiveWriterError {
            switch error {
            case .destinationExists: return .destinationExists
            case .exclusivePublishUnsupported, .unsafeDestination: return .unsupportedDestination
            case .ioFailure: return .diskWriteFailed
            }
        }
        if error is ArchiveVerificationError { return .verificationFailed }
        if let error = error as? StoreError {
            switch error {
            case .snapshotUnavailable, .staleReference: return .changedSelection
            case .invalidLease, .preconditionFailed: return .snapshotExpired
            default: return .unknown
            }
        }
        return .unknown
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static let readmeData = Data("""
    Keeptide Local Export

    This directory is a verified local export. Portable source bytes are in payloads, and human-readable derivatives are in readable. Entries marked Requires File Relocation do not contain the original local file or its path.
    """.utf8)
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
