import CryptoKit
import Foundation

enum ArchiveVerificationError: Error, Equatable, Sendable {
    case unsupportedSchema
    case malformedArchive
    case unsafePath
    case integrityMismatch
    case unexpectedFile
    case ioFailure
}

struct ArchiveVerifier: Sendable {
    static let maximumManifestByteCount = 1 * 1_024 * 1_024
    static let maximumEntryLineByteCount = 8 * 1_024 * 1_024
    private static let readChunkByteCount = 1 * 1_024 * 1_024

    func verify(at root: URL) async throws -> ArchiveVerification {
        let child = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            return try Self.verifySynchronously(at: root)
        }
        return try await withTaskCancellationHandler {
            try await child.value
        } onCancel: {
            child.cancel()
        }
    }
}

private extension ArchiveVerifier {
    struct VerifiedFile {
        let path: String
        let byteCount: Int64
        let sha256: String
    }

    struct RepresentationIdentity: Equatable {
        let id: UUID
        let itemIndex: Int
        let representationIndex: Int
        let typeIdentifier: String
        let storage: ArchiveRepresentationStorage
        let byteCount: Int64
        let digestSHA256: String?
        let relocationTokenHex: String?
        let payloadPath: String?

        init(_ representation: ArchiveRepresentation) {
            id = representation.id
            itemIndex = representation.itemIndex
            representationIndex = representation.representationIndex
            typeIdentifier = representation.typeIdentifier
            storage = representation.storage
            byteCount = representation.byteCount
            digestSHA256 = representation.digestSHA256
            relocationTokenHex = representation.relocationTokenHex
            payloadPath = representation.payloadPath
        }
    }

    struct EntryReadResult {
        let file: VerifiedFile
    }

    struct CanonicalCaptureManifest: Encodable {
        let version: Int
        let itemCount: Int
        let entries: [CanonicalManifestEntry]
    }

    struct CanonicalManifestEntry: Encodable {
        let itemIndex: Int
        let representationIndex: Int
        let typeIdentifier: String
        let storage: ArchiveRepresentationStorage
        let byteCount: Int64
        let digest: Data
    }

    struct CanonicalIdentifier: Encodable { let rawValue: UUID }
    enum CanonicalFacet: String, Encodable { case history, memo }
    struct CanonicalContentRef: Encodable {
        let itemID: CanonicalIdentifier
        let facet: CanonicalFacet
        let version: CanonicalIdentifier
        let digest: Data
    }

    static func verifySynchronously(at root: URL) throws -> ArchiveVerification {
        do {
            try validateRoot(root)
            let manifestURL = root.appendingPathComponent("manifest.json", isDirectory: false)
            let manifestData = try readBoundedRegularFile(
                manifestURL, maximumByteCount: maximumManifestByteCount
            )
            try StrictJSON.validateManifest(manifestData)
            let manifest = try decode(ArchiveManifest.self, from: manifestData)
            try validate(manifest)

            var expectedFiles: Set<String> = ["manifest.json", "README.txt", "entries.ndjson"]
            var expectedDirectories: Set<String> = []
            var caseFoldedPaths: Set<String> = [
                folded("manifest.json"), folded("README.txt"), folded("entries.ndjson"),
            ]
            var representationsByID: [UUID: RepresentationIdentity] = [:]
            var payloadOwners: [String: UUID] = [:]
            var readableFiles: [String: ArchiveFileDigest] = [:]
            var verifiedFiles = [VerifiedFile(
                path: "manifest.json",
                byteCount: Int64(manifestData.count),
                sha256: sha256Hex(manifestData)
            )]
            verifiedFiles.append(try verifyFile(
                at: resolve(manifest.readme.path, under: root, expectedPrefix: nil),
                relativePath: manifest.readme.path,
                expectedByteCount: manifest.readme.byteCount,
                expectedSHA256: manifest.readme.sha256
            ))
            var containsRelocation = false
            var entryCount = 0
            var boundaryHasher = SHA256()
            boundaryHasher.update(data: Data("[".utf8))

            let entriesURL = try resolve(manifest.entries.path, under: root, expectedPrefix: nil)
            let readResult = try readEntries(at: entriesURL) { entry in
                try Task.checkCancellation()
                try validate(entry, expectedOrdinal: entryCount + 1)
                try validateContentDigest(entry)
                if entryCount > 0 { boundaryHasher.update(data: Data(",".utf8)) }
                boundaryHasher.update(data: try canonicalContentRefData(for: entry))
                entryCount += 1
                var entryRepresentationIDs = Set<UUID>()
                for representation in entry.representations {
                    guard entryRepresentationIDs.insert(representation.id).inserted else {
                        throw ArchiveVerificationError.integrityMismatch
                    }
                    let identity = RepresentationIdentity(representation)
                    if let existing = representationsByID[representation.id] {
                        guard existing == identity else {
                            throw ArchiveVerificationError.integrityMismatch
                        }
                    } else {
                        representationsByID[representation.id] = identity
                    }

                    switch representation.storage {
                    case .portable:
                        guard let payloadPath = representation.payloadPath,
                              let digest = representation.digestSHA256 else {
                            throw ArchiveVerificationError.malformedArchive
                        }
                        if let owner = payloadOwners[payloadPath] {
                            guard owner == representation.id else {
                                throw ArchiveVerificationError.integrityMismatch
                            }
                        } else {
                            try claimPath(
                                payloadPath,
                                expectedPrefix: "payloads",
                                caseFoldedPaths: &caseFoldedPaths
                            )
                            payloadOwners[payloadPath] = representation.id
                            expectedFiles.insert(payloadPath)
                            expectedDirectories.insert("payloads")
                            let file = try verifyFile(
                                at: resolve(payloadPath, under: root, expectedPrefix: "payloads"),
                                relativePath: payloadPath,
                                expectedByteCount: representation.byteCount,
                                expectedSHA256: digest
                            )
                            verifiedFiles.append(file)
                        }
                    case .localReference:
                        containsRelocation = true
                    }

                    if let readable = representation.readable {
                        try claimPath(readable.path, expectedPrefix: "readable", caseFoldedPaths: &caseFoldedPaths)
                        guard readableFiles[readable.path] == nil else {
                            throw ArchiveVerificationError.integrityMismatch
                        }
                        readableFiles[readable.path] = readable
                        expectedFiles.insert(readable.path)
                        expectedDirectories.insert("readable")
                        let file = try verifyFile(
                            at: resolve(readable.path, under: root, expectedPrefix: "readable"),
                            relativePath: readable.path,
                            expectedByteCount: readable.byteCount,
                            expectedSHA256: readable.sha256
                        )
                        verifiedFiles.append(file)
                    }
                }
            }
            boundaryHasher.update(data: Data("]".utf8))

            guard readResult.file.byteCount == manifest.entries.byteCount,
                  readResult.file.sha256 == manifest.entries.sha256,
                  entryCount == manifest.expectedEntryCount,
                  hex(boundaryHasher.finalize()) == manifest.snapshotBoundarySHA256 else {
                throw ArchiveVerificationError.integrityMismatch
            }
            verifiedFiles.append(readResult.file)

            guard representationsByID.count == manifest.expectedRepresentationCount,
                  payloadOwners.count == manifest.expectedPortablePayloadCount,
                  readableFiles.count == manifest.expectedReadableFileCount,
                  containsRelocation == manifest.containsFileReferencesRequiringRelocation else {
                throw ArchiveVerificationError.integrityMismatch
            }
            if manifest.scope.kind == .selected {
                guard manifest.scope.requestedRefCount == entryCount,
                      manifest.scope.selectedRefsSHA256 == manifest.snapshotBoundarySHA256 else {
                    throw ArchiveVerificationError.integrityMismatch
                }
            }
            try validateInventory(
                root: root, expectedFiles: expectedFiles, expectedDirectories: expectedDirectories
            )
            return ArchiveVerification(
                entryCount: entryCount,
                representationCount: representationsByID.count,
                portablePayloadCount: payloadOwners.count,
                readableFileCount: readableFiles.count,
                verifiedRootDigest: rootDigest(verifiedFiles)
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ArchiveVerificationError {
            throw error
        } catch {
            throw ArchiveVerificationError.ioFailure
        }
    }

    static func validateRoot(_ root: URL) throws {
        guard root.isFileURL else { throw ArchiveVerificationError.unsafePath }
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ArchiveVerificationError.unsafePath
        }
    }

    static func validate(_ manifest: ArchiveManifest) throws {
        guard manifest.format == ArchiveManifest.currentFormat,
              manifest.schemaVersion == ArchiveManifest.currentSchemaVersion,
              manifest.verifierSchemaVersion == ArchiveManifest.currentVerifierSchemaVersion else {
            throw ArchiveVerificationError.unsupportedSchema
        }
        guard manifest.createdAt.timeIntervalSinceReferenceDate.isFinite,
              manifest.source.label == manifest.source.token.publicLabel,
              manifest.scope.label == manifest.scope.kind.publicLabel,
              manifest.expectedEntryCount >= 0,
              manifest.expectedRepresentationCount >= 0,
              manifest.expectedPortablePayloadCount >= 0,
              manifest.expectedReadableFileCount >= 0,
              manifest.readme.path == "README.txt",
              manifest.readme.byteCount >= 0,
              isLowercaseSHA256(manifest.readme.sha256),
              manifest.entries.path == "entries.ndjson",
              manifest.entries.byteCount >= 0,
              isLowercaseSHA256(manifest.entries.sha256),
              isLowercaseSHA256(manifest.snapshotBoundarySHA256) else {
            throw ArchiveVerificationError.malformedArchive
        }
        switch manifest.scope.kind {
        case .allVisible:
            guard manifest.scope.requestedRefCount == nil,
                  manifest.scope.selectedRefsSHA256 == nil else {
                throw ArchiveVerificationError.malformedArchive
            }
        case .selected:
            guard let count = manifest.scope.requestedRefCount, count > 0,
                  let digest = manifest.scope.selectedRefsSHA256,
                  isLowercaseSHA256(digest) else {
                throw ArchiveVerificationError.malformedArchive
            }
        }
    }

    static func validate(_ entry: ArchiveEntry, expectedOrdinal: Int) throws {
        guard entry.ordinal == expectedOrdinal,
              entry.facetLabel == entry.facet.publicLabel,
              entry.contentKindLabel == entry.contentKind.publicLabel,
              entry.availabilityLabel == entry.availability.publicLabel,
              isLowercaseSHA256(entry.contentDigestSHA256) else {
            throw ArchiveVerificationError.malformedArchive
        }
        var currentItemIndex = 0
        var nextRepresentationIndex = 0
        var hasLocalReference = false
        for representation in entry.representations {
            guard representation.itemIndex >= 0,
                  representation.representationIndex >= 0,
                  representation.byteCount >= 0,
                  validTypeIdentifier(representation.typeIdentifier) else {
                throw ArchiveVerificationError.malformedArchive
            }
            if representation.itemIndex == currentItemIndex {
                guard representation.representationIndex == nextRepresentationIndex else {
                    throw ArchiveVerificationError.integrityMismatch
                }
                nextRepresentationIndex += 1
            } else if representation.itemIndex == currentItemIndex + 1 {
                guard nextRepresentationIndex > 0, representation.representationIndex == 0 else {
                    throw ArchiveVerificationError.integrityMismatch
                }
                currentItemIndex += 1
                nextRepresentationIndex = 1
            } else {
                throw ArchiveVerificationError.integrityMismatch
            }
            switch representation.storage {
            case .portable:
                guard representation.byteCount >= 0,
                      representation.relocationTokenHex == nil,
                      representation.payloadPath != nil,
                      let digest = representation.digestSHA256,
                      isLowercaseSHA256(digest) else {
                    throw ArchiveVerificationError.malformedArchive
                }
            case .localReference:
                hasLocalReference = true
                guard representation.byteCount == 0,
                      representation.digestSHA256 == nil,
                      representation.payloadPath == nil,
                      representation.readable == nil,
                      let token = representation.relocationTokenHex,
                      isLowercaseSHA256(token) else {
                    throw ArchiveVerificationError.malformedArchive
                }
            }
            if let readable = representation.readable {
                guard readable.byteCount >= 0, isLowercaseSHA256(readable.sha256) else {
                    throw ArchiveVerificationError.malformedArchive
                }
            }
        }
        guard hasLocalReference == (entry.availability == .requiresFileRelocation) else {
            throw ArchiveVerificationError.malformedArchive
        }
    }

    static func validateContentDigest(_ entry: ArchiveEntry) throws {
        switch entry.origin.kind {
        case .ownedPlainText, .ownedMarkdown:
            let expectedKind: ArchiveContentKind = entry.origin.kind == .ownedMarkdown ? .markdown : .text
            guard entry.origin.captureManifestVersion == nil,
                  entry.origin.captureItemCount == nil,
                  entry.facet == .memo,
                  entry.contentKind == expectedKind,
                  entry.representations.count == 1,
                  let representation = entry.representations.first,
                  representation.storage == .portable,
                  representation.itemIndex == 0,
                  representation.representationIndex == 0,
                  representation.typeIdentifier == "public.utf8-plain-text",
                  representation.digestSHA256 == entry.contentDigestSHA256 else {
                throw ArchiveVerificationError.integrityMismatch
            }
        case .capture:
            guard let version = entry.origin.captureManifestVersion,
                  let itemCount = entry.origin.captureItemCount,
                  version == 1 || version == 2,
                  itemCount >= 0 else {
                throw ArchiveVerificationError.malformedArchive
            }
            if entry.representations.contains(where: { $0.storage == .localReference }), version != 2 {
                throw ArchiveVerificationError.integrityMismatch
            }
            let values = try entry.representations.map { representation -> CanonicalManifestEntry in
                let digestHex: String
                switch representation.storage {
                case .portable:
                    guard let digest = representation.digestSHA256 else {
                        throw ArchiveVerificationError.malformedArchive
                    }
                    digestHex = digest
                case .localReference:
                    guard let token = representation.relocationTokenHex else {
                        throw ArchiveVerificationError.malformedArchive
                    }
                    digestHex = token
                }
                guard let digest = data(fromLowercaseSHA256: digestHex) else {
                    throw ArchiveVerificationError.malformedArchive
                }
                return CanonicalManifestEntry(itemIndex: representation.itemIndex,
                    representationIndex: representation.representationIndex,
                    typeIdentifier: representation.typeIdentifier, storage: representation.storage,
                    byteCount: representation.byteCount, digest: digest)
            }
            guard (values.isEmpty ? itemCount == 0 : values.last!.itemIndex + 1 == itemCount) else {
                throw ArchiveVerificationError.integrityMismatch
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let manifest = CanonicalCaptureManifest(version: version, itemCount: itemCount, entries: values)
            guard sha256Hex(try encoder.encode(manifest)) == entry.contentDigestSHA256 else {
                throw ArchiveVerificationError.integrityMismatch
            }
        }
    }

    static func canonicalContentRefData(for entry: ArchiveEntry) throws -> Data {
        guard let digest = data(fromLowercaseSHA256: entry.contentDigestSHA256) else {
            throw ArchiveVerificationError.malformedArchive
        }
        let ref = CanonicalContentRef(
            itemID: CanonicalIdentifier(rawValue: entry.itemID),
            facet: entry.facet == .clipboardHistory ? .history : .memo,
            version: CanonicalIdentifier(rawValue: entry.contentVersion),
            digest: digest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ref)
    }

    static func readEntries(
        at url: URL, onEntry: (ArchiveEntry) throws -> Void
    ) throws -> EntryReadResult {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        var pending = Data()
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: readChunkByteCount), !chunk.isEmpty else { break }
            total = try adding(Int64(chunk.count), to: total)
            hasher.update(data: chunk)
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[..<newline]
                guard !line.isEmpty, line.count <= maximumEntryLineByteCount else {
                    throw ArchiveVerificationError.malformedArchive
                }
                let data = Data(line)
                try StrictJSON.validateEntry(data)
                try onEntry(decode(ArchiveEntry.self, from: data))
                pending.removeSubrange(...newline)
            }
            guard pending.count <= maximumEntryLineByteCount else {
                throw ArchiveVerificationError.malformedArchive
            }
        }
        guard pending.isEmpty else { throw ArchiveVerificationError.malformedArchive }
        return EntryReadResult(
            file: VerifiedFile(path: "entries.ndjson", byteCount: total, sha256: hex(hasher.finalize()))
        )
    }

    static func verifyFile(
        at url: URL, relativePath: String, expectedByteCount: Int64, expectedSHA256: String
    ) throws -> VerifiedFile {
        try validateRegularFile(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: readChunkByteCount), !chunk.isEmpty else { break }
            total = try adding(Int64(chunk.count), to: total)
            hasher.update(data: chunk)
        }
        let digest = hex(hasher.finalize())
        guard total == expectedByteCount, digest == expectedSHA256 else {
            throw ArchiveVerificationError.integrityMismatch
        }
        return VerifiedFile(path: relativePath, byteCount: total, sha256: digest)
    }

    static func readBoundedRegularFile(_ url: URL, maximumByteCount: Int) throws -> Data {
        try validateRegularFile(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              size.int64Value >= 0,
              size.int64Value <= Int64(maximumByteCount) else {
            throw ArchiveVerificationError.malformedArchive
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    static func validateRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ArchiveVerificationError.unsafePath
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let count = attributes[.referenceCount] as? NSNumber, count.intValue > 1 {
            throw ArchiveVerificationError.unsafePath
        }
    }

    static func claimPath(
        _ path: String, expectedPrefix: String, caseFoldedPaths: inout Set<String>
    ) throws {
        _ = try validatedComponents(path, expectedPrefix: expectedPrefix)
        guard caseFoldedPaths.insert(folded(path)).inserted else {
            throw ArchiveVerificationError.unsafePath
        }
    }

    static func resolve(_ path: String, under root: URL, expectedPrefix: String?) throws -> URL {
        let components = try validatedComponents(path, expectedPrefix: expectedPrefix)
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(component, isDirectory: false)
        }
    }

    static func validatedComponents(_ path: String, expectedPrefix: String?) throws -> [String] {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            throw ArchiveVerificationError.unsafePath
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard components.allSatisfy({ component in
            !component.isEmpty
                && component != "."
                && component != ".."
                && !component.hasPrefix(".")
                && component.unicodeScalars.allSatisfy { scalar in
                    switch scalar.value {
                    case 48...57, 65...90, 97...122, 45, 46, 95: true
                    default: false
                    }
                }
        }) else {
            throw ArchiveVerificationError.unsafePath
        }
        if let expectedPrefix {
            guard components.count == 2, components[0] == expectedPrefix else {
                throw ArchiveVerificationError.unsafePath
            }
        } else {
            guard components == ["entries.ndjson"] || components == ["README.txt"] else {
                throw ArchiveVerificationError.unsafePath
            }
        }
        return components
    }

    static func validateInventory(
        root: URL, expectedFiles: Set<String>, expectedDirectories: Set<String>
    ) throws {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [],
            errorHandler: { _, _ in false }
        ) else { throw ArchiveVerificationError.ioFailure }
        var actualFiles = Set<String>()
        var actualDirectories = Set<String>()
        var foldedInventory = Set<String>()
        for case let url as URL in enumerator {
            let components = url.standardizedFileURL.pathComponents
            guard components.starts(with: canonicalRoot.pathComponents) else {
                throw ArchiveVerificationError.unsafePath
            }
            let relative = components.dropFirst(canonicalRoot.pathComponents.count).joined(separator: "/")
            guard foldedInventory.insert(folded(relative)).inserted else {
                throw ArchiveVerificationError.unsafePath
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ArchiveVerificationError.unsafePath }
            if values.isRegularFile == true {
                try validateRegularFile(url)
                actualFiles.insert(relative)
            } else if values.isDirectory == true {
                actualDirectories.insert(relative)
            } else {
                throw ArchiveVerificationError.unsafePath
            }
        }
        guard actualFiles == expectedFiles,
              actualDirectories.isSubset(of: ["payloads", "readable"]),
              expectedDirectories.isSubset(of: actualDirectories) else {
            throw ArchiveVerificationError.unexpectedFile
        }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try decoder().decode(type, from: data)
        } catch {
            throw ArchiveVerificationError.malformedArchive
        }
    }

    static func validTypeIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.contains(".")
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    static func adding(_ value: Int64, to total: Int64) throws -> Int64 {
        let (result, overflow) = total.addingReportingOverflow(value)
        guard !overflow else { throw ArchiveVerificationError.malformedArchive }
        return result
    }

    static func rootDigest(_ files: [VerifiedFile]) -> String {
        let transcript = files.sorted { $0.path < $1.path }.reduce(into: Data()) { data, file in
            data.append(Data(file.path.utf8))
            data.append(0)
            data.append(Data(String(file.byteCount).utf8))
            data.append(0)
            data.append(Data(file.sha256.utf8))
            data.append(0x0A)
        }
        return sha256Hex(transcript)
    }

    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        data(fromLowercaseSHA256: value) != nil
    }

    static func data(fromLowercaseSHA256 value: String) -> Data? {
        guard value.count == 64, value.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            return nil
        }
        var result = Data(capacity: 32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

private enum StrictJSON {
    static let manifestKeys: Set<String> = [
        "format", "schemaVersion", "createdAt", "source", "scope", "exportID",
        "snapshotBoundarySHA256", "expectedEntryCount", "expectedRepresentationCount",
        "expectedPortablePayloadCount", "expectedReadableFileCount",
        "containsFileReferencesRequiringRelocation", "entries", "verifierSchemaVersion",
        "readme",
    ]
    static let entryRequiredKeys: Set<String> = [
        "ordinal", "itemID", "facet", "facetLabel", "contentVersion", "contentDigestSHA256",
        "origin", "contentKind", "contentKindLabel", "availability", "availabilityLabel", "title", "representations",
    ]
    static let entryOptionalKeys: Set<String> = ["note", "sourceApplicationIdentifier", "collection"]
    static let representationRequiredKeys: Set<String> = [
        "id", "itemIndex", "representationIndex", "typeIdentifier", "storage", "byteCount",
    ]
    static let representationOptionalKeys: Set<String> = [
        "digestSHA256", "relocationTokenHex", "payloadPath", "readable",
    ]

    static func validateManifest(_ data: Data) throws {
        let object = try dictionary(data)
        try exactKeys(object, manifestKeys)
        try exactKeys(try child(object, "source"), ["token", "label"])
        try allowedKeys(try child(object, "scope"), required: ["kind", "label"], optional: ["requestedRefCount", "selectedRefsSHA256"])
        try exactKeys(try child(object, "readme"), ["path", "byteCount", "sha256"])
        try exactKeys(try child(object, "entries"), ["path", "byteCount", "sha256"])
    }

    static func validateEntry(_ data: Data) throws {
        let object = try dictionary(data)
        try allowedKeys(object, required: entryRequiredKeys, optional: entryOptionalKeys)
        if let collection = object["collection"] as? [String: Any] {
            try exactKeys(collection, ["id", "name", "color"])
        }
        try allowedKeys(try child(object, "origin"), required: ["kind"],
                        optional: ["captureManifestVersion", "captureItemCount"])
        guard let representations = object["representations"] as? [[String: Any]] else {
            throw ArchiveVerificationError.malformedArchive
        }
        for representation in representations {
            try allowedKeys(
                representation, required: representationRequiredKeys, optional: representationOptionalKeys
            )
            if let readable = representation["readable"] as? [String: Any] {
                try exactKeys(readable, ["path", "byteCount", "sha256"])
            }
        }
    }

    static func dictionary(_ data: Data) throws -> [String: Any] {
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ArchiveVerificationError.malformedArchive
        }
        guard let object = decoded as? [String: Any] else {
            throw ArchiveVerificationError.malformedArchive
        }
        return object
    }

    static func child(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let child = object[key] as? [String: Any] else {
            throw ArchiveVerificationError.malformedArchive
        }
        return child
    }

    static func exactKeys(_ object: [String: Any], _ expected: Set<String>) throws {
        guard Set(object.keys) == expected else { throw ArchiveVerificationError.malformedArchive }
    }

    static func allowedKeys(
        _ object: [String: Any], required: Set<String>, optional: Set<String>
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw ArchiveVerificationError.malformedArchive
        }
    }
}
