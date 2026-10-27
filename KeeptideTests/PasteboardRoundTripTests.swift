import AppKit
import XCTest
@testable import Keeptide

@MainActor
final class PasteboardRoundTripTests: XCTestCase {
    func testAsynchronousReadMaterializesDeferredDataAwayFromMainThread() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let provider = ThreadCheckingDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        board.clearContents()
        XCTAssertTrue(board.writeObjects([item]))
        let result = try await SnapshotReader(pasteboard: board).readAsynchronously(sourceApp: "synthetic")
        XCTAssertEqual(result.items.first?.representations.first?.bytes, Data("deferred".utf8))
        XCTAssertFalse(provider.wasMainThread)
    }
    nonisolated(unsafe) private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        pasteboards.forEach { $0.releaseGlobally() }
        pasteboards.removeAll()
        super.tearDown()
    }

    func testSnapshotReaderPreservesItemTypeAndByteOrderWithObservedSource() throws {
        let pasteboard = makePasteboard()
        let first = NSPasteboardItem()
        first.setData(Data("plain".utf8), forType: .string)
        first.setData(Data("<b>plain</b>".utf8), forType: .html)
        let second = NSPasteboardItem()
        second.setData(Data([0, 1, 2, 3]), forType: .png)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let reader = SnapshotReader(pasteboard: pasteboard)
        let source = "untrusted.observed.bundle.identifier"
        let snapshot = try reader.read(sourceApp: source)

        XCTAssertEqual(snapshot.changeCount, pasteboard.changeCount)
        XCTAssertEqual(snapshot.sourceApp, source)
        XCTAssertEqual(snapshot.items, [
            CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                       bytes: Data("plain".utf8)),
                CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.html.rawValue,
                                       bytes: Data("<b>plain</b>".utf8))
            ]),
            CapturedPasteboardItem(representations: [
                CapturedRepresentation(typeIdentifier: NSPasteboard.PasteboardType.png.rawValue,
                                       bytes: Data([0, 1, 2, 3]))
            ])
        ])
    }

    func testSnapshotReaderRejectsAnEmptyPasteboard() {
        let pasteboard = makePasteboard()

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(error as? SnapshotReaderError, .emptyPasteboard)
        }
    }

    func testSnapshotReaderScansPrivacyTypesBeforeRequestingAnyBody() {
        let pasteboard = makePasteboard()
        let provider = DeferredDataProvider()
        let ordinary = NSPasteboardItem()
        ordinary.setDataProvider(provider, forTypes: [.string])
        let privateItem = NSPasteboardItem()
        privateItem.setData(Data(), forType: NSPasteboard.PasteboardType(CapturePolicy.concealedType))
        XCTAssertTrue(pasteboard.writeObjects([ordinary, privateItem]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(error as? SnapshotReaderError, .privacyRestricted)
        }
        XCTAssertEqual(provider.requestedTypes, [])
    }

    func testSnapshotReaderRejectsPromisedRepresentationThatProvidesNoData() {
        let pasteboard = makePasteboard()
        let provider = DeferredDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(
                error as? SnapshotReaderError,
                .incompleteRepresentation(itemIndex: 0, typeIdentifier: NSPasteboard.PasteboardType.string.rawValue)
            )
        }
        XCTAssertEqual(provider.requestedTypes, [.string])
    }

    func testSnapshotReaderRejectsMoreThanFiftyMiBWithoutTruncation() {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(
            Data(repeating: 0xA5, count: SnapshotReader.maximumPayloadBytes + 1),
            forType: NSPasteboard.PasteboardType("public.data")
        )
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            XCTAssertEqual(error as? SnapshotReaderError, .payloadTooLarge(maximumBytes: 50 * 1_024 * 1_024))
        }
    }

    func testSnapshotReaderRejectsAChangeCountMutationDuringBodyRead() {
        let pasteboard = makePasteboard()
        let provider = MutatingDataProvider()
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        XCTAssertTrue(pasteboard.writeObjects([item]))

        XCTAssertThrowsError(try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)) { error in
            guard case .changedDuringRead = error as? SnapshotReaderError else {
                return XCTFail("Expected changedDuringRead, got \(error)")
            }
        }
    }

    func testSnapshotReaderOmitsOwnWriteMarkerFromCapturedIdentity() throws {
        let pasteboard = makePasteboard()
        let item = NSPasteboardItem()
        item.setData(Data("body".utf8), forType: .string)
        item.setData(Data("marker".utf8), forType: NSPasteboard.PasteboardType(OwnWriteToken.typeIdentifier))
        XCTAssertTrue(pasteboard.writeObjects([item]))

        let snapshot = try SnapshotReader(pasteboard: pasteboard).read(sourceApp: nil)

        XCTAssertEqual(snapshot.items.count, 1)
        XCTAssertEqual(snapshot.items[0].representations.map(\.typeIdentifier), [
            NSPasteboard.PasteboardType.string.rawValue
        ])
    }

    func testCapturedRepresentationUsesTheSharedFileReferenceClassifier() {
        XCTAssertTrue(CapturedRepresentation(
            typeIdentifier: "public.file-url",
            bytes: Data("file:///Synthetic/report.txt".utf8)
        ).isLocalFileReference)
        XCTAssertTrue(CapturedRepresentation(
            typeIdentifier: "public.url",
            bytes: Data("file:///Synthetic/report.txt".utf8)
        ).isLocalFileReference)
        XCTAssertFalse(CapturedRepresentation(
            typeIdentifier: "public.url",
            bytes: Data("https://example.invalid/report".utf8)
        ).isLocalFileReference)
    }

    func testWriterPreservesEveryItemRepresentationAndByteInCoordinateOrder() throws {
        let pasteboard = makePasteboard()
        let content = resolvedContent([
            representation(item: 1, representation: 0, type: .png, bytes: Data([7, 8, 9])),
            representation(item: 0, representation: 1, type: .html, bytes: Data("<p>A</p>".utf8)),
            representation(item: 0, representation: 0, type: .string, bytes: Data("A".utf8))
        ])

        let token = try PasteboardWriter(pasteboard: pasteboard).write(content)
        let items = try XCTUnwrap(pasteboard.pasteboardItems)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].types, [
            .string,
            .html,
            NSPasteboard.PasteboardType(OwnWriteToken.typeIdentifier)
        ])
        XCTAssertEqual(items[0].data(forType: .string), Data("A".utf8))
        XCTAssertEqual(items[0].data(forType: .html), Data("<p>A</p>".utf8))
        XCTAssertEqual(items[1].types, [.png])
        XCTAssertEqual(items[1].data(forType: .png), Data([7, 8, 9]))
        XCTAssertTrue(token.matches(pasteboard: pasteboard))
    }

    func testWriterPreservesFileURLRepresentationsAsBytes() throws {
        let pasteboard = makePasteboard()
        let bytes = Data("file:///Synthetic/report.txt".utf8)
        let content = resolvedContent([
            representation(item: 0, representation: 0,
                           type: NSPasteboard.PasteboardType("public.file-url"), bytes: bytes),
            representation(item: 0, representation: 1,
                           type: NSPasteboard.PasteboardType("public.url"), bytes: bytes)
        ])

        _ = try PasteboardWriter(pasteboard: pasteboard).write(content)
        let item = try XCTUnwrap(pasteboard.pasteboardItems?.first)

        XCTAssertEqual(item.data(forType: NSPasteboard.PasteboardType("public.file-url")), bytes)
        XCTAssertEqual(item.data(forType: NSPasteboard.PasteboardType("public.url")), bytes)
    }

    func testWriterRoundTripsResolvedLocalReferenceBytesWithoutChangingThem() throws {
        let pasteboard = makePasteboard()
        let bytes = Data("file:///Synthetic/report.txt".utf8)
        let content = resolvedContent([
            representation(
                item: 0,
                representation: 0,
                type: NSPasteboard.PasteboardType("public.file-url"),
                storage: .localReference,
                bytes: bytes
            )
        ])

        _ = try PasteboardWriter(pasteboard: pasteboard).write(content)

        XCTAssertEqual(
            pasteboard.pasteboardItems?.first?.data(
                forType: NSPasteboard.PasteboardType("public.file-url")
            ),
            bytes
        )
    }

    func testWriterRejectsNonActionableContentBeforeClearingExistingPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let content = ResolvedContent(
            ref: contentRef(),
            integrity: .recovering,
            representations: []
        )

        XCTAssertThrowsError(try PasteboardWriter(pasteboard: pasteboard).write(content)) { error in
            XCTAssertEqual(error as? PasteboardWriterError, .nonActionableContent)
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testWriterRejectsMissingBytesBeforeClearingExistingPasteboard() {
        let pasteboard = makePasteboard()
        pasteboard.setString("keep me", forType: .string)
        let content = resolvedContent([
            representation(item: 0, representation: 0, type: .string, bytes: nil)
        ])

        XCTAssertThrowsError(try PasteboardWriter(pasteboard: pasteboard).write(content)) { error in
            XCTAssertEqual(
                error as? PasteboardWriterError,
                .missingRepresentationBytes(itemIndex: 0, representationIndex: 0)
            )
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "keep me")
    }

    func testOwnWriteTokenDoesNotSwallowTheNextExternalCopy() throws {
        let pasteboard = makePasteboard()
        let content = resolvedContent([
            representation(item: 0, representation: 0, type: .string, bytes: Data("ours".utf8))
        ])
        let token = try PasteboardWriter(pasteboard: pasteboard).write(content)
        XCTAssertTrue(token.matches(pasteboard: pasteboard))
        XCTAssertFalse(
            OwnWriteToken(changeCount: token.changeCount, marker: "a different marker")
                .matches(pasteboard: pasteboard)
        )

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("external", forType: .string))

        XCTAssertFalse(token.matches(pasteboard: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "external")
    }

    private func makePasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        return pasteboard
    }

    private func contentRef() -> ContentRef {
        ContentRef(itemID: ItemID(), facet: .history, version: ContentVersion(), digest: Data(repeating: 1, count: 32))
    }

    private func resolvedContent(_ representations: [RepresentationValue]) -> ResolvedContent {
        ResolvedContent(ref: contentRef(), integrity: .complete, representations: representations)
    }

    private func representation(
        item: Int,
        representation: Int,
        type: NSPasteboard.PasteboardType,
        storage: RepresentationStorage = .portable,
        bytes: Data?
    ) -> RepresentationValue {
        RepresentationValue(
            snapshotID: UUID(),
            itemIndex: item,
            representationIndex: representation,
            typeIdentifier: type.rawValue,
            storage: storage,
            byteCount: Int64(bytes?.count ?? 0),
            digest: bytes.map(ContentDigest.sha256) ?? Data(repeating: 0, count: 32),
            bytes: bytes
        )
    }
}

private final class ThreadCheckingDataProvider: NSObject, NSPasteboardItemDataProvider {
    private let lock = NSLock()
    private var mainThread = false
    var wasMainThread: Bool { lock.withLock { mainThread } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        lock.withLock { mainThread = Thread.isMainThread }
        item.setData(Data("deferred".utf8), forType: type)
    }
}

private final class DeferredDataProvider: NSObject, NSPasteboardItemDataProvider {
    private(set) var requestedTypes: [NSPasteboard.PasteboardType] = []

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        requestedTypes.append(type)
    }
}

private final class MutatingDataProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setData(Data("stale".utf8), forType: type)
        pasteboard?.clearContents()
        pasteboard?.setString("new value", forType: .string)
    }
}
