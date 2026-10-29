import AppKit
import XCTest
@testable import Keeptide

/// A temporary store and a uniquely named pasteboard, both removed when the test ends. Nothing here reads or
/// writes the general pasteboard.
@MainActor
final class PasteFixture {
    let controller: PersistenceController
    let board: NSPasteboard

    init(_ testCase: XCTestCase) throws {
        let directory = SearchTestSupport.directory()
        let controller = try PersistenceController(directory: directory)
        let board = NSPasteboard.withUniqueName()
        testCase.addTeardownBlock {
            try? await controller.close()
            try? FileManager.default.removeItem(at: directory)
        }
        testCase.addTeardownBlock { board.releaseGlobally() }
        self.controller = controller
        self.board = board
    }

    func insert(_ items: [[(String, Data)]]) async throws -> ContentRef {
        let capture = try ContentStoreFixtures.capture(items)
        let item = ContentStoreFixtures.item(capture)
        try await ContentStoreFixtures.insert(item, capture, into: controller)
        return ContentStoreFixtures.ref(item, capture)
    }

    /// A service that writes to this fixture's board and stores receipts in its store. `read` replaces the
    /// store read.
    func service(system: DirectPasteSystem, directPasteOnlyTo: String? = nil,
                 read: (@Sendable (ContentRef) async throws -> ResolvedContent)? = nil) -> PasteService {
        let repository = ContentRepository(controller: controller)
        let usage = LocalUsageStore(controller: controller)
        return PasteService(pasteboard: board, read: read ?? { try await repository.read($0) },
                            recordUse: { try await usage.record($0) }, didWrite: { _ in },
                            system: system, directPasteOnlyTo: directPasteOnlyTo)
    }

    func useCount(_ ref: ContentRef) async throws -> Int64 {
        try await LocalUsageStore(controller: controller).summaries(for: [ref]).first?.useCount ?? 0
    }
}

/// The system as direct paste sees it, set by the test. It posts nothing: a sent ⌘V is only recorded.
/// By default every check passes for TextEdit, with V on key code 9.
@MainActor
final class FakeDirectPasteSystem {
    var front: PasteTarget? = .textEdit
    var permitted = true
    var secureInput = false
    var keyCode: CGKeyCode? = 9
    var grantsOnRequest = false
    /// False makes the post itself fail, as when the keystroke cannot be built.
    var postSucceeds = true

    /// Every frontmostTarget call: the one that records a session's target, and the one in each check.
    private(set) var probes = 0
    private(set) var sent: [CGKeyCode] = []
    private(set) var accessRequests = 0
    private(set) var settingsOpened = 0

    var onProbe: (() -> Void)?
    var onSend: (() -> Void)?

    var system: DirectPasteSystem {
        DirectPasteSystem(
            frontmostTarget: {
                self.probes += 1
                self.onProbe?()
                return self.front
            },
            canPostEvents: { self.permitted },
            requestPostEventAccess: {
                self.accessRequests += 1
                return self.grantsOnRequest
            },
            openAccessibilitySettings: { self.settingsOpened += 1 },
            isSecureInputEnabled: { self.secureInput },
            commandVKeyCode: { self.keyCode },
            postCommandV: { keyCode in
                guard self.postSucceeds else { return false }
                self.sent.append(keyCode)
                self.onSend?()
                return true
            })
    }
}

extension PasteTarget {
    static let textEdit = PasteTarget(processIdentifier: 501, bundleIdentifier: "com.apple.TextEdit",
                                      name: "TextEdit", windowNumber: 11)
    static let notes = PasteTarget(processIdentifier: 502, bundleIdentifier: "com.apple.Notes",
                                   name: "Notes", windowNumber: 21)
    static let terminal = PasteTarget(processIdentifier: 503, bundleIdentifier: "com.apple.Terminal",
                                      name: "Terminal", windowNumber: 31)
    static let testHost = PasteTarget(processIdentifier: 504,
                                      bundleIdentifier: "io.github.insightprober.Keeptide.SystemTestHost",
                                      name: "Keeptide System Test Host", windowNumber: 41)
}

/// Holds a read until the test opens it.
actor PasteReadGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}
