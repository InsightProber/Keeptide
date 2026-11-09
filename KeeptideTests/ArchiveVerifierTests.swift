import CryptoKit
import Foundation
import XCTest
@testable import Keeptide

final class ArchiveVerifierTests: XCTestCase {
    func testValidArchiveVerifiesExactCountsAndRootDigest() async throws {
        let fixture = try makePortableFixture()

        let result = try await ArchiveVerifier().verify(at: fixture.root)

        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(result.representationCount, 1)
        XCTAssertEqual(result.portablePayloadCount, 1)
        XCTAssertEqual(result.readableFileCount, 1)
        XCTAssertTrue(isLowercaseSHA256(result.verifiedRootDigest))
    }

    func testFinderMetadataInArchiveDirectoriesDoesNotChangeVerifiedContent() async throws {
        let fixture = try makePortableFixture()
        let baseline = try await ArchiveVerifier().verify(at: fixture.root)
        for path in [".DS_Store", "payloads/.DS_Store", "readable/.DS_Store"] {
            // This data is deliberately not a parsed Finder metadata document.
            try Data("unverified Finder display metadata".utf8).write(to: fixture.root.appendingPathComponent(path))
            let result = try await ArchiveVerifier().verify(at: fixture.root)
            XCTAssertEqual(result, baseline, "Finder metadata must not enter verified counts or the root digest")
        }
    }

    func testFinderMetadataExceptionRejectsSymlinksHardLinksAndDirectories() async throws {
        for path in [".DS_Store", "payloads/.DS_Store", "readable/.DS_Store"] {
            for type in ["symlink", "hardlink", "directory"] {
                let fixture = try makePortableFixture()
                let metadata = fixture.root.appendingPathComponent(path)
                let outside = fixture.root.deletingLastPathComponent().appendingPathComponent("outside")
                try Data("not archive metadata".utf8).write(to: outside)
                switch type {
                case "symlink":
                    try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: outside)
                case "hardlink":
                    try FileManager.default.linkItem(at: outside, to: metadata)
                default:
                    try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: false)
                }
                await assertVerificationFails(fixture.root)
            }
        }
    }

    func testFinderMetadataExceptionRejectsCaseVariantsOtherHiddenFilesAndExtraDirectories() async throws {
        for path in [".ds_store", ".DS_STORE", ".hidden", "payloads/.ds_store", "readable/.localized"] {
            let fixture = try makePortableFixture()
            try Data("unexpected".utf8).write(to: fixture.root.appendingPathComponent(path))
            await assertVerificationFails(fixture.root)
        }
        let extra = try makePortableFixture()
        let extraDirectory = extra.root.appendingPathComponent("extra")
        try FileManager.default.createDirectory(at: extraDirectory, withIntermediateDirectories: false)
        try Data("metadata".utf8).write(to: extraDirectory.appendingPathComponent(".DS_Store"))
        await assertVerificationFails(extra.root)
    }

    func testFinderMetadataDoesNotHideChangedPayloadBytes() async throws {
        let fixture = try makePortableFixture()
        try Data("metadata".utf8).write(to: fixture.root.appendingPathComponent(".DS_Store"))
        let payload = fixture.root.appendingPathComponent("payloads/text.bin")
        let original = try Data(contentsOf: payload)
        try Data(repeating: 88, count: original.count).write(to: payload)
        do {
            _ = try await ArchiveVerifier().verify(at: fixture.root)
            XCTFail("Finder metadata must not relax payload integrity checks")
        } catch let error as ArchiveVerificationError {
            XCTAssertEqual(error, .integrityMismatch)
        }
    }

    func testEmptyAllVisibleArchiveIsValid() async throws {
        let root = try temporaryRoot()
        let readme = Data("Keeptide local export\n".utf8)
        try readme.write(to: root.appendingPathComponent("README.txt"))
        let entries = Data()
        try entries.write(to: root.appendingPathComponent("entries.ndjson"))
        let manifest = ArchiveManifest(
            format: ArchiveManifest.currentFormat,
            schemaVersion: ArchiveManifest.currentSchemaVersion,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: ArchiveSource(token: .currentLocalSnapshot, label: "Current Local Snapshot"),
            scope: ArchiveScopeDescriptor(
                kind: .allVisible, label: "All Visible Content", requestedRefCount: nil, selectedRefsSHA256: nil
            ),
            exportID: UUID(),
            snapshotBoundarySHA256: try boundaryHex(for: []),
            expectedEntryCount: 0,
            expectedRepresentationCount: 0,
            expectedPortablePayloadCount: 0,
            expectedReadableFileCount: 0,
            containsFileReferencesRequiringRelocation: false,
            readme: ArchiveFileDigest(path: "README.txt", byteCount: Int64(readme.count), sha256: sha256Hex(readme)),
            entries: ArchiveFileDigest(path: "entries.ndjson", byteCount: 0, sha256: sha256Hex(entries)),
            verifierSchemaVersion: ArchiveManifest.currentVerifierSchemaVersion
        )
        try manifestEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))

        let result = try await ArchiveVerifier().verify(at: root)

        XCTAssertEqual(result.entryCount, 0)
        XCTAssertEqual(result.representationCount, 0)
    }

    func testHistoryAndInheritedMemoCanShareOneRepresentationAndPayload() async throws {
        let fixture = try makePortableFixture()
        var memo = fixture.entry
        memo.ordinal = 2
        memo.facet = .memo
        memo.facetLabel = "Memo"
        memo.contentVersion = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        memo.representations[0].readable = nil
        let entries = [fixture.entry, memo]
        let data = try encodeLines(entries)
        try data.write(to: fixture.root.appendingPathComponent("entries.ndjson"))
        fixture.manifest.expectedEntryCount = 2
        fixture.manifest.snapshotBoundarySHA256 = try boundaryHex(for: entries)
        fixture.manifest.entries = ArchiveFileDigest(
            path: "entries.ndjson", byteCount: Int64(data.count), sha256: sha256Hex(data)
        )
        try fixture.writeManifest()

        let result = try await ArchiveVerifier().verify(at: fixture.root)

        XCTAssertEqual(result.entryCount, 2)
        XCTAssertEqual(result.representationCount, 1)
        XCTAssertEqual(result.portablePayloadCount, 1)
        XCTAssertEqual(result.readableFileCount, 1)
    }

    func testSchemaAndPublicLabelsAreStrict() async throws {
        for mutation: (inout ArchiveManifest) -> Void in [
            { $0.schemaVersion = 0 },
            { $0.schemaVersion = 3 },
            { $0.verifierSchemaVersion = 2 },
            { $0.format = "example.invalid" },
            { $0.source.label = "Local Backup" },
            { $0.scope.label = "Everything" },
            { $0.expectedEntryCount = -1 },
            { $0.entries.sha256 = String(repeating: "A", count: 64) },
        ] {
            let fixture = try makePortableFixture()
            mutation(&fixture.manifest)
            try fixture.writeManifest()

            await assertVerificationFails(fixture.root)
        }
    }

    func testSchemaOneEntriesKeepTheirOneCollectionAndSchemaTwoEntriesListTheirs() async throws {
        let shell = ArchiveCollection(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                                      name: "Shell", color: "blue")
        let prompts = ArchiveCollection(id: UUID(uuidString: "66666666-6666-6666-6666-666666666666")!,
                                        name: "Prompts", color: "green")
        let schemaOne = try makePortableFixture(schemaVersion: 1)
        XCTAssertEqual(schemaOne.entry.collection, shell)
        _ = try await ArchiveVerifier().verify(at: schemaOne.root)

        let several = try makePortableFixture()
        several.entry.collections = [shell, prompts]
        try several.rewriteEntriesAndManifest()
        _ = try await ArchiveVerifier().verify(at: several.root)

        // Each schema has its own key, a list is never empty, and no collection is listed twice.
        for change: (ArchiveFixture) -> Void in [
            { $0.manifest.schemaVersion = 1 },
            { $0.entry.collection = shell },
            { $0.entry.collections = [] },
            { $0.entry.collections = [shell, shell] },
        ] {
            let fixture = try makePortableFixture()
            change(fixture)
            try fixture.rewriteEntriesAndManifest()
            await assertVerificationFails(fixture.root)
        }
        let schemaOneWithList = try makePortableFixture(schemaVersion: 1)
        schemaOneWithList.entry.collections = [shell]
        try schemaOneWithList.rewriteEntriesAndManifest()
        await assertVerificationFails(schemaOneWithList.root)
    }

    func testMalformedJSONIsReportedAsMalformedArchive() async throws {
        let fixture = try makePortableFixture()
        try Data("{".utf8).write(to: fixture.root.appendingPathComponent("manifest.json"))

        do {
            _ = try await ArchiveVerifier().verify(at: fixture.root)
            XCTFail("Expected malformed manifest to fail")
        } catch let error as ArchiveVerificationError {
            XCTAssertEqual(error, .malformedArchive)
        }
    }

    func testEntryTokensLabelsAndDatesAreStrict() async throws {
        let fixture = try makePortableFixture()
        fixture.entry.facetLabel = "History"
        try fixture.rewriteEntriesAndManifest()
        await assertVerificationFails(fixture.root)

        let badDate = try makePortableFixture()
        let manifestURL = badDate.root.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        object["createdAt"] = "not-a-date"
        try JSONSerialization.data(withJSONObject: object).write(to: manifestURL)
        await assertVerificationFails(badDate.root)
    }

    func testUnsafeRelativePathsAndCaseInsensitiveCollisionsAreRejected() async throws {
        for path in ["/tmp/escape", "../escape", "payloads/../escape", #"payloads\escape"#, "manifest.json"] {
            let fixture = try makePortableFixture()
            fixture.entry.representations[0].payloadPath = path
            try fixture.rewriteEntriesAndManifest()
            await assertVerificationFails(fixture.root)
        }

        let collision = try makePortableFixture()
        var second = collision.entry.representations[0]
        second.id = UUID()
        second.representationIndex = 1
        second.payloadPath = "PAYLOADS/TEXT.BIN"
        collision.entry.representations.append(second)
        collision.manifest.expectedRepresentationCount = 2
        collision.manifest.expectedPortablePayloadCount = 2
        try collision.rewriteEntriesAndManifest()
        await assertVerificationFails(collision.root)

        for unsafeName in ["bad name.bin", "é.bin"] {
            let fixture = try makePortableFixture()
            let oldURL = fixture.root.appendingPathComponent("payloads/text.bin")
            let newPath = "payloads/\(unsafeName)"
            try FileManager.default.moveItem(at: oldURL, to: fixture.root.appendingPathComponent(newPath))
            fixture.entry.representations[0].payloadPath = newPath
            try fixture.rewriteEntriesAndManifest()
            await assertVerificationFails(fixture.root)
        }
    }

    func testSymlinksHardLinksAndDirectoriesMasqueradingAsFilesAreRejected() async throws {
        let symlink = try makePortableFixture()
        let payload = symlink.root.appendingPathComponent("payloads/text.bin")
        let external = symlink.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("/Users/alice/command".utf8).write(to: external)
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(at: payload, withDestinationURL: external)
        await assertVerificationFails(symlink.root)

        let hardLink = try makePortableFixture()
        let hardPayload = hardLink.root.appendingPathComponent("payloads/text.bin")
        let hardExternal = hardLink.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try FileManager.default.removeItem(at: hardPayload)
        try Data("/Users/alice/command".utf8).write(to: hardExternal)
        try FileManager.default.linkItem(at: hardExternal, to: hardPayload)
        await assertVerificationFails(hardLink.root)

        let directory = try makePortableFixture()
        let directoryPayload = directory.root.appendingPathComponent("payloads/text.bin")
        try FileManager.default.removeItem(at: directoryPayload)
        try FileManager.default.createDirectory(at: directoryPayload, withIntermediateDirectories: false)
        await assertVerificationFails(directory.root)
    }

    func testTamperedMissingAndUnexpectedFilesAreRejected() async throws {
        let tampered = try makePortableFixture()
        try Data("changed".utf8).write(to: tampered.root.appendingPathComponent("payloads/text.bin"))
        await assertVerificationFails(tampered.root)

        let missing = try makePortableFixture()
        try FileManager.default.removeItem(at: missing.root.appendingPathComponent("readable/entry.txt"))
        await assertVerificationFails(missing.root)

        let extra = try makePortableFixture()
        try Data("extra".utf8).write(to: extra.root.appendingPathComponent("unexpected.txt"))
        await assertVerificationFails(extra.root)

        let appended = try makePortableFixture()
        let handle = try FileHandle(forWritingTo: appended.root.appendingPathComponent("entries.ndjson"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        await assertVerificationFails(appended.root)

        let readme = try makePortableFixture()
        try Data("tampered readme".utf8).write(to: readme.root.appendingPathComponent("README.txt"))
        await assertVerificationFails(readme.root)
    }

    func testManifestCountsMetadataOrderingAndDuplicateRepresentationCollisionsAreRejected() async throws {
        let wrongCount = try makePortableFixture()
        wrongCount.manifest.expectedPortablePayloadCount = 2
        try wrongCount.writeManifest()
        await assertVerificationFails(wrongCount.root)

        let wrongOrdinal = try makePortableFixture()
        wrongOrdinal.entry.ordinal = 2
        try wrongOrdinal.rewriteEntriesAndManifest(recomputeBoundary: false)
        await assertVerificationFails(wrongOrdinal.root)

        let coordinateGap = try makePortableFixture()
        coordinateGap.entry.representations[0].representationIndex = 1
        try coordinateGap.rewriteEntriesAndManifest()
        await assertVerificationFails(coordinateGap.root)

        let missingFirstItem = try makePortableFixture()
        missingFirstItem.entry.representations[0].itemIndex = 1
        try missingFirstItem.rewriteEntriesAndManifest()
        await assertVerificationFails(missingFirstItem.root)

        let duplicate = try makePortableFixture()
        var second = duplicate.entry.representations[0]
        second.representationIndex = 1
        second.payloadPath = "payloads/other.bin"
        duplicate.entry.representations.append(second)
        duplicate.manifest.expectedRepresentationCount = 2
        duplicate.manifest.expectedPortablePayloadCount = 2
        try duplicate.rewriteEntriesAndManifest()
        await assertVerificationFails(duplicate.root)

        let changedMetadata = try makePortableFixture()
        changedMetadata.entry.representations[0].typeIdentifier = "public.png"
        try changedMetadata.rewriteEntriesOnly()
        await assertVerificationFails(changedMetadata.root)
    }

    func testBoundaryIsRecomputedFromOrderedEntryReferences() async throws {
        let fixture = try makePortableFixture()
        fixture.manifest.snapshotBoundarySHA256 = sha256Hex(Data("self-declared".utf8))
        try fixture.writeManifest()

        await assertVerificationFails(fixture.root)
    }

    func testPayloadMetadataCannotBeDetachedFromCaptureContentDigest() async throws {
        let fixture = try makePortableFixture()
        let changed = Data("different portable source".utf8)
        try changed.write(to: fixture.root.appendingPathComponent("payloads/text.bin"))
        fixture.entry.representations[0].byteCount = Int64(changed.count)
        fixture.entry.representations[0].digestSHA256 = sha256Hex(changed)
        try fixture.rewriteEntriesAndManifest(recomputeBoundary: false)

        await assertVerificationFails(fixture.root)
    }

    func testOwnedMemoDigestMustEqualItsOnlyPortablePayloadDigest() async throws {
        let valid = try makePortableFixture()
        valid.entry.facet = .memo
        valid.entry.facetLabel = "Memo"
        valid.entry.origin = ArchiveContentOrigin(kind: .ownedPlainText,
                                                  captureManifestVersion: nil, captureItemCount: nil)
        valid.entry.contentKind = .text
        valid.entry.contentKindLabel = "Text"
        valid.entry.contentDigestSHA256 = try XCTUnwrap(valid.entry.representations[0].digestSHA256)
        try valid.rewriteEntriesAndManifest()
        _ = try await ArchiveVerifier().verify(at: valid.root)

        let mismatch = try makePortableFixture()
        mismatch.entry.facet = .memo
        mismatch.entry.facetLabel = "Memo"
        mismatch.entry.origin = ArchiveContentOrigin(kind: .ownedPlainText,
                                                     captureManifestVersion: nil, captureItemCount: nil)
        mismatch.entry.contentKind = .text
        mismatch.entry.contentKindLabel = "Text"
        mismatch.entry.contentDigestSHA256 = sha256Hex(Data("different memo body".utf8))
        try mismatch.rewriteEntriesAndManifest()
        await assertVerificationFails(mismatch.root)

        let wrongType = try makePortableFixture()
        wrongType.entry.facet = .memo
        wrongType.entry.facetLabel = "Memo"
        wrongType.entry.origin = ArchiveContentOrigin(kind: .ownedPlainText,
                                                      captureManifestVersion: nil, captureItemCount: nil)
        wrongType.entry.contentDigestSHA256 = try XCTUnwrap(wrongType.entry.representations[0].digestSHA256)
        wrongType.entry.representations[0].typeIdentifier = "public.png"
        try wrongType.rewriteEntriesAndManifest()
        await assertVerificationFails(wrongType.root)

        let wrongKind = try makePortableFixture()
        wrongKind.entry.facet = .memo
        wrongKind.entry.facetLabel = "Memo"
        wrongKind.entry.origin = ArchiveContentOrigin(kind: .ownedMarkdown,
                                                      captureManifestVersion: nil, captureItemCount: nil)
        wrongKind.entry.contentDigestSHA256 = try XCTUnwrap(wrongKind.entry.representations[0].digestSHA256)
        wrongKind.entry.contentKind = .text
        wrongKind.entry.contentKindLabel = "Text"
        try wrongKind.rewriteEntriesAndManifest()
        await assertVerificationFails(wrongKind.root)

        let wrongOrigin = try makePortableFixture()
        wrongOrigin.entry.facet = .memo
        wrongOrigin.entry.facetLabel = "Memo"
        wrongOrigin.entry.origin = ArchiveContentOrigin(kind: .ownedPlainText,
                                                        captureManifestVersion: nil, captureItemCount: nil)
        wrongOrigin.entry.contentDigestSHA256 = try XCTUnwrap(wrongOrigin.entry.representations[0].digestSHA256)
        wrongOrigin.entry.contentKind = .markdown
        wrongOrigin.entry.contentKindLabel = "Markdown"
        try wrongOrigin.rewriteEntriesAndManifest()
        await assertVerificationFails(wrongOrigin.root)
    }

    func testCancellingVerifierCancelsDetachedDiskWork() async throws {
        let fixture = try makePortableFixture()
        let root = fixture.root
        let task = Task { try await ArchiveVerifier().verify(at: root) }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled verifier returned success")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testLocalReferenceRelocationHasNoPayloadOrReadableFile() async throws {
        let fixture = try makeRelocationFixture()

        let result = try await ArchiveVerifier().verify(at: fixture.root)

        XCTAssertEqual(result.entryCount, 1)
        XCTAssertEqual(result.representationCount, 1)
        XCTAssertEqual(result.portablePayloadCount, 0)
        XCTAssertEqual(result.readableFileCount, 0)
    }

    func testLocalReferenceCannotClaimPayloadAndRelocationFlagMustMatch() async throws {
        let payloadClaim = try makeRelocationFixture()
        payloadClaim.entry.representations[0].payloadPath = "payloads/forbidden.bin"
        try payloadClaim.rewriteEntriesAndManifest()
        await assertVerificationFails(payloadClaim.root)

        let wrongFlag = try makeRelocationFixture()
        wrongFlag.manifest.containsFileReferencesRequiringRelocation = false
        try wrongFlag.writeManifest()
        await assertVerificationFails(wrongFlag.root)
    }

    func testEntriesMustEndWithNewlineAndStayWithinLineLimit() async throws {
        let truncated = try makePortableFixture()
        let entriesURL = truncated.root.appendingPathComponent("entries.ndjson")
        var bytes = try Data(contentsOf: entriesURL)
        bytes.removeLast()
        try bytes.write(to: entriesURL)
        truncated.manifest.entries = ArchiveFileDigest(
            path: "entries.ndjson",
            byteCount: Int64(bytes.count),
            sha256: sha256Hex(bytes)
        )
        try truncated.writeManifest()
        await assertVerificationFails(truncated.root)

        let oversized = try makePortableFixture()
        oversized.entry.note = String(repeating: "x", count: ArchiveVerifier.maximumEntryLineByteCount + 1)
        try oversized.rewriteEntriesAndManifest()
        await assertVerificationFails(oversized.root)
    }
}

private final class ArchiveFixture {
    let root: URL
    var manifest: ArchiveManifest
    var entry: ArchiveEntry

    init(root: URL, manifest: ArchiveManifest, entry: ArchiveEntry) {
        self.root = root
        self.manifest = manifest
        self.entry = entry
    }

    func rewriteEntriesOnly() throws {
        let data = try encodeLine(entry)
        try data.write(to: root.appendingPathComponent("entries.ndjson"))
    }

    func rewriteEntriesAndManifest(recomputeBoundary: Bool = true) throws {
        let data = try encodeLine(entry)
        try data.write(to: root.appendingPathComponent("entries.ndjson"))
        manifest.entries = ArchiveFileDigest(
            path: "entries.ndjson", byteCount: Int64(data.count), sha256: sha256Hex(data)
        )
        if recomputeBoundary {
            manifest.snapshotBoundarySHA256 = try boundaryHex(for: [entry])
        }
        try writeManifest()
    }

    func writeManifest() throws {
        try manifestEncoder().encode(manifest).write(to: root.appendingPathComponent("manifest.json"))
    }
}

private extension ArchiveVerifierTests {
    func makePortableFixture(schemaVersion: Int = ArchiveManifest.currentSchemaVersion) throws -> ArchiveFixture {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("payloads"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("readable"), withIntermediateDirectories: false)

        let payload = Data("/Users/alice/command".utf8)
        let readable = Data("command\n".utf8)
        let readme = Data("Keeptide local export\n".utf8)
        try readme.write(to: root.appendingPathComponent("README.txt"))
        try payload.write(to: root.appendingPathComponent("payloads/text.bin"))
        try readable.write(to: root.appendingPathComponent("readable/entry.txt"))

        var entry = ArchiveEntry(
            ordinal: 1,
            itemID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            facet: .clipboardHistory,
            facetLabel: "Clipboard History",
            contentVersion: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            contentDigestSHA256: String(repeating: "0", count: 64),
            origin: ArchiveContentOrigin(kind: .capture, captureManifestVersion: 1, captureItemCount: 1),
            contentKind: .text,
            contentKindLabel: "Text",
            availability: .complete,
            availabilityLabel: "Complete",
            title: "Command",
            note: nil,
            sourceApplicationIdentifier: "com.example.Terminal",
            representations: [
                ArchiveRepresentation(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    itemIndex: 0,
                    representationIndex: 0,
                    typeIdentifier: "public.utf8-plain-text",
                    storage: .portable,
                    byteCount: Int64(payload.count),
                    digestSHA256: sha256Hex(payload),
                    relocationTokenHex: nil,
                    payloadPath: "payloads/text.bin",
                    readable: ArchiveFileDigest(
                        path: "readable/entry.txt", byteCount: Int64(readable.count), sha256: sha256Hex(readable)
                    )
                ),
            ]
        )
        let shell = ArchiveCollection(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, name: "Shell", color: "blue"
        )
        if schemaVersion == 1 { entry.collection = shell } else { entry.collections = [shell] }
        entry.contentDigestSHA256 = try captureDigestHex(for: entry)
        let line = try encodeLine(entry)
        try line.write(to: root.appendingPathComponent("entries.ndjson"))
        let manifest = ArchiveManifest(
            format: ArchiveManifest.currentFormat,
            schemaVersion: schemaVersion,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            source: ArchiveSource(token: .currentLocalSnapshot, label: "Current Local Snapshot"),
            scope: ArchiveScopeDescriptor(
                kind: .allVisible, label: "All Visible Content", requestedRefCount: nil, selectedRefsSHA256: nil
            ),
            exportID: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
            snapshotBoundarySHA256: try boundaryHex(for: [entry]),
            expectedEntryCount: 1,
            expectedRepresentationCount: 1,
            expectedPortablePayloadCount: 1,
            expectedReadableFileCount: 1,
            containsFileReferencesRequiringRelocation: false,
            readme: ArchiveFileDigest(
                path: "README.txt", byteCount: Int64(readme.count), sha256: sha256Hex(readme)
            ),
            entries: ArchiveFileDigest(path: "entries.ndjson", byteCount: Int64(line.count), sha256: sha256Hex(line)),
            verifierSchemaVersion: ArchiveManifest.currentVerifierSchemaVersion
        )
        let fixture = ArchiveFixture(root: root, manifest: manifest, entry: entry)
        try fixture.writeManifest()
        return fixture
    }

    func makeRelocationFixture() throws -> ArchiveFixture {
        let fixture = try makePortableFixture()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("payloads"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("readable"))
        fixture.entry.contentKind = .fileReference
        fixture.entry.contentKindLabel = "File Reference"
        fixture.entry.availability = .requiresFileRelocation
        fixture.entry.availabilityLabel = "Requires File Relocation"
        fixture.entry.representations = [
            ArchiveRepresentation(
                id: fixture.entry.representations[0].id,
                itemIndex: 0,
                representationIndex: 0,
                typeIdentifier: "public.file-url",
                storage: .localReference,
                byteCount: 0,
                digestSHA256: nil,
                relocationTokenHex: String(repeating: "59", count: 32),
                payloadPath: nil,
                readable: nil
            ),
        ]
        fixture.entry.origin = ArchiveContentOrigin(
            kind: .capture, captureManifestVersion: LocalReferencePrivacy.opaqueLocalReferenceManifestVersion,
            captureItemCount: 1
        )
        fixture.entry.contentDigestSHA256 = try captureDigestHex(for: fixture.entry)
        fixture.manifest.expectedPortablePayloadCount = 0
        fixture.manifest.expectedReadableFileCount = 0
        fixture.manifest.containsFileReferencesRequiringRelocation = true
        try fixture.rewriteEntriesAndManifest()
        return fixture
    }

    func temporaryRoot() throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveVerifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("archive")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    func assertVerificationFails(_ root: URL, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ArchiveVerifier().verify(at: root)
            XCTFail("Expected archive verification to fail", file: file, line: line)
        } catch {
            XCTAssertTrue(error is ArchiveVerificationError, "Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private func manifestEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func encodeLine(_ entry: ArchiveEntry) throws -> Data {
    var data = try manifestEncoder().encode(entry)
    data.append(0x0A)
    return data
}

private func encodeLines(_ entries: [ArchiveEntry]) throws -> Data {
    try entries.reduce(into: Data()) { data, entry in
        data.append(try encodeLine(entry))
    }
}

private func boundaryHex(for entries: [ArchiveEntry]) throws -> String {
    let refs = try entries.map { entry in
        ContentRef(
            itemID: ItemID(rawValue: entry.itemID),
            facet: entry.facet == .clipboardHistory ? .history : .memo,
            version: ContentVersion(rawValue: entry.contentVersion),
            digest: try XCTUnwrap(Data(hexadecimalSHA256: entry.contentDigestSHA256))
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return sha256Hex(try encoder.encode(refs))
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func captureDigestHex(for entry: ArchiveEntry) throws -> String {
    let version = try XCTUnwrap(entry.origin.captureManifestVersion)
    let itemCount = try XCTUnwrap(entry.origin.captureItemCount)
    let values = try entry.representations.map { representation -> ManifestEntry in
        let hex = representation.storage == .portable
            ? try XCTUnwrap(representation.digestSHA256)
            : try XCTUnwrap(representation.relocationTokenHex)
        return ManifestEntry(itemIndex: representation.itemIndex,
            representationIndex: representation.representationIndex,
            typeIdentifier: representation.typeIdentifier,
            storage: representation.storage == .portable ? .portable : .localReference,
            byteCount: representation.byteCount,
            digest: try XCTUnwrap(Data(hexadecimalSHA256: hex)))
    }
    return sha256Hex(try CaptureManifest(version: version, itemCount: itemCount, entries: values).canonicalData())
}

private func isLowercaseSHA256(_ value: String) -> Bool {
    value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
}

private extension Data {
    init?(hexadecimalSHA256 value: String) {
        guard value.count == 64 else { return nil }
        var bytes = Data(capacity: 32)
        var index = value.startIndex
        for _ in 0..<32 {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
