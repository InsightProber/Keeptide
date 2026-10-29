import AppKit
import XCTest
@testable import Keeptide

/// Direct paste through `PasteService`, with a real temporary store, a named pasteboard and a fake system that
/// posts nothing. Unless a test says otherwise, TextEdit is in front, access is granted, V is key code 9, and
/// the request asks for a paste.
@MainActor
final class PasteGuardTests: XCTestCase {
    private let clip = "Synthetic paste note"
    /// TextEdit, with another of its windows in front.
    private static let otherTextEditWindow = PasteTarget(
        processIdentifier: PasteTarget.textEdit.processIdentifier,
        bundleIdentifier: PasteTarget.textEdit.bundleIdentifier, name: PasteTarget.textEdit.name, windowNumber: 12)

    func testAllChecksPassingWritesHidesThenSendsOneCommandV() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let log = PasteLog()
        fake.onSend = {
            log.boardAtSend = fixture.board.string(forType: .string)
            log.dismissalsAtSend = log.dismissals
            log.queuedJobRanAtSend = log.queuedJobRan
        }

        let outcome = await paste.execute(request(ref, session, dismiss: {
            log.dismissals += 1
            log.boardAtDismiss = fixture.board.string(forType: .string)
            // It runs at the main actor's next suspension, and there must be none before the keystroke.
            Task { @MainActor in log.queuedJobRan = true }
        }))

        XCTAssertEqual(outcome, .dispatched(.textEdit))
        XCTAssertEqual(fake.sent, [9])
        XCTAssertEqual(log.boardAtDismiss, clip)
        XCTAssertEqual(log.boardAtSend, clip)
        XCTAssertEqual(log.dismissalsAtSend, 1)
        XCTAssertEqual(log.queuedJobRanAtSend, false)
        XCTAssertEqual(log.dismissals, 1)
    }

    func testCopyDeliveryNeverSends() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let log = PasteLog()

        let outcome = await paste.execute(request(ref, session, delivery: .copy, dismiss: { log.dismissals += 1 }))

        XCTAssertEqual(outcome, .copied)
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.dismissals, 0)
        // A copy runs no target check: the only probe is the one that recorded the session's target.
        XCTAssertEqual(fake.probes, 1)
    }

    func testTargetAppSwitchedCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let log = PasteLog()
        fake.front = .notes

        let outcome = await paste.execute(request(ref, session, dismiss: { log.dismissals += 1 }))

        XCTAssertEqual(outcome, .copiedInstead(.targetChanged))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.dismissals, 0)
    }

    func testTargetQuitCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        fake.front = nil

        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .copiedInstead(.targetChanged))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
    }

    func testTargetWindowChangedCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        XCTAssertEqual(session.target?.windowNumber, 11)
        fake.front = Self.otherTextEditWindow

        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .copiedInstead(.targetChanged))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
    }

    func testANewerSessionCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        _ = paste.beginSession()

        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .copiedInstead(.targetChanged))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])

        // A session that keeps a recorded target is newer too.
        let reopened = paste.beginSession()
        _ = paste.beginSession(target: .textEdit)
        let afterKeptTarget = await paste.execute(request(ref, reopened))
        XCTAssertEqual(afterKeptTarget, .copiedInstead(.targetChanged))
        XCTAssertEqual(fake.sent, [])
    }

    func testSecureInputCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        fake.secureInput = true

        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .copiedInstead(.secureInput))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
    }

    func testWithoutPermissionCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        fake.permitted = false
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .copiedInstead(.notPermitted))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(fake.accessRequests, 0)
    }

    func testUnresolvedKeyCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let log = PasteLog()
        fake.keyCode = nil

        let outcome = await paste.execute(request(ref, paste.beginSession(), dismiss: { log.dismissals += 1 }))

        XCTAssertEqual(outcome, .copiedInstead(.cannotSendKeystroke))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.dismissals, 0)

        // A keystroke the system cannot post is the same failure, found after the panel hid.
        fake.keyCode = 9
        fake.postSucceeds = false
        let unposted = await paste.execute(request(ref, paste.beginSession(), dismiss: { log.dismissals += 1 }))
        XCTAssertEqual(unposted, .copiedInstead(.cannotSendKeystroke))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.dismissals, 1)
    }

    func testTestSessionsPasteOnlyIntoTheHost() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system,
                                    directPasteOnlyTo: CaptureTestConfiguration.systemTestHostBundleIdentifier)

        let intoTextEdit = await paste.execute(request(ref, paste.beginSession()))

        XCTAssertEqual(intoTextEdit, .copiedInstead(.testSessionTarget))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])

        // An app without a bundle identifier is not the host either.
        fake.front = PasteTarget(processIdentifier: 505, bundleIdentifier: nil, name: "App", windowNumber: 51)
        let intoUnidentified = await paste.execute(request(ref, paste.beginSession()))

        XCTAssertEqual(intoUnidentified, .copiedInstead(.testSessionTarget))
        XCTAssertEqual(fake.sent, [])

        fake.front = .testHost
        let intoHost = await paste.execute(request(ref, paste.beginSession()))

        XCTAssertEqual(intoHost, .dispatched(.testHost))
        XCTAssertEqual(fake.sent, [9])
    }

    func testTargetChangingWhileThePanelHidesCopiesInstead() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        let log = PasteLog()

        let outcome = await paste.execute(request(ref, session, dismiss: {
            log.dismissals += 1
            fake.front = Self.otherTextEditWindow
        }))

        XCTAssertEqual(outcome, .copiedInstead(.targetChanged))
        XCTAssertEqual(log.dismissals, 1)
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])

        // A panel that ends its session while it hides gives up the target too.
        fake.front = .textEdit
        let ending = paste.beginSession()
        let endedWhileHiding = await paste.execute(request(ref, ending, dismiss: { ending.end() }))
        XCTAssertEqual(endedWhileHiding, .copiedInstead(.targetChanged))
        XCTAssertEqual(fake.sent, [])
    }

    func testUnreadyOrStaleContentDoesNothing() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let log = PasteLog()
        let before = fixture.board.changeCount

        let unreadable = fixture.service(system: fake.system, read: { _ in throw StoreError.staleReference })
        let unread = await unreadable.execute(request(ref, unreadable.beginSession(),
                                                      dismiss: { log.dismissals += 1 }))
        XCTAssertEqual(unread, .refused(.contentUnavailable))

        let paste = fixture.service(system: fake.system)
        let changed = ContentRef(itemID: ref.itemID, facet: ref.facet, version: ref.version,
                                 digest: Data(repeating: 1, count: 32))
        let changedOutcome = await paste.execute(request(changed, paste.beginSession(),
                                                         dismiss: { log.dismissals += 1 }))
        XCTAssertEqual(changedOutcome, .refused(.contentUnavailable))

        let session = paste.beginSession()
        let old = request(ref, session, dismiss: { log.dismissals += 1 })
        session.advanceQueryGeneration()
        let oldOutcome = await paste.execute(old)
        XCTAssertEqual(oldOutcome, .refused(.stale))

        // The selection moves on while the clip is being read.
        let repository = ContentRepository(controller: fixture.controller)
        let gate = PasteReadGate()
        let started = expectation(description: "Read started")
        let held = fixture.service(system: fake.system, read: { ref in
            started.fulfill()
            await gate.wait()
            return try await repository.read(ref)
        })
        let heldSession = held.beginSession()
        let pending = Task { await held.execute(self.request(ref, heldSession, dismiss: { log.dismissals += 1 })) }
        await fulfillment(of: [started], timeout: 3)
        heldSession.advanceQueryGeneration()
        await gate.open()
        let heldOutcome = await pending.value
        XCTAssertEqual(heldOutcome, .refused(.stale))

        XCTAssertEqual(fixture.board.changeCount, before)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.dismissals, 0)
        try await Task.sleep(for: .milliseconds(100))
        let uses = try await fixture.useCount(ref)
        XCTAssertEqual(uses, 0)
    }

    func testNoTargetOnlyCopies() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        fake.front = nil
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        XCTAssertNil(session.target)
        XCTAssertEqual(paste.availability(for: session), .copy(.noTarget))
        // An app that comes forward later does not give the session a target.
        fake.front = .textEdit
        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .copiedInstead(.noTarget))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
    }

    func testKeyCodeIsResolvedWhenSending() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        XCTAssertEqual(paste.availability(for: session), .paste(.textEdit))
        fake.keyCode = 47

        let outcome = await paste.execute(request(ref, session))

        XCTAssertEqual(outcome, .dispatched(.textEdit))
        XCTAssertEqual(fake.sent, [47])

        // A layout that changes while the panel hides is the one the keystroke uses.
        let changedWhileHiding = await paste.execute(request(ref, paste.beginSession(), dismiss: { fake.keyCode = 9 }))
        XCTAssertEqual(changedWhileHiding, .dispatched(.textEdit))
        XCTAssertEqual(fake.sent, [47, 9])
    }

    func testAvailabilityReflectsTheChecksAtOpen() throws {
        let fixture = try PasteFixture(self)
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)

        XCTAssertEqual(paste.availability(for: paste.beginSession()), .paste(.textEdit))
        fake.permitted = false
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.notPermitted))
        fake.permitted = true
        fake.secureInput = true
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.secureInput))
        fake.secureInput = false
        fake.keyCode = nil
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.cannotSendKeystroke))

        // With several checks failing, the first one in order is the reason.
        fake.secureInput = true
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.secureInput))
        fake.permitted = false
        XCTAssertEqual(paste.availability(for: paste.beginSession()), .copy(.notPermitted))
        // Checking only asks: it neither sends nor asks for access.
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(fake.accessRequests, 0)
        XCTAssertEqual(fake.settingsOpened, 0)
    }

    /// Each pair of neighbouring checks fails together here, and the earlier one must be the reason.
    /// `testAvailabilityReflectsTheChecksAtOpen` pins secure input before the key code.
    func testAnEarlierCheckWinsOverTheNextOne() throws {
        let fixture = try PasteFixture(self)
        let fake = FakeDirectPasteSystem()
        let testSession = fixture.service(system: fake.system,
                                          directPasteOnlyTo: CaptureTestConfiguration.systemTestHostBundleIdentifier)

        // No target comes before the test session's host rule.
        XCTAssertEqual(testSession.availability(for: testSession.beginSession(target: nil)), .copy(.noTarget))

        // The host rule comes before permission.
        let nonHost = testSession.beginSession()
        fake.permitted = false
        XCTAssertEqual(testSession.availability(for: nonHost), .copy(.testSessionTarget))

        // Permission comes before the target, and without it the window list is not read.
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()
        fake.front = Self.otherTextEditWindow
        let probes = fake.probes
        XCTAssertEqual(paste.availability(for: session), .copy(.notPermitted))
        XCTAssertEqual(fake.probes, probes)

        // The target comes before secure input.
        fake.permitted = true
        fake.secureInput = true
        XCTAssertEqual(paste.availability(for: session), .copy(.targetChanged))
    }

    func testBeginSessionProbesOnceAndAnExplicitTargetIsNotProbed() throws {
        let fixture = try PasteFixture(self)
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)

        let session = paste.beginSession()
        XCTAssertEqual(fake.probes, 1)
        XCTAssertEqual(session.target, .textEdit)

        let kept = paste.beginSession(target: .notes)
        XCTAssertEqual(fake.probes, 1)
        XCTAssertEqual(kept.target, .notes)
        XCTAssertNotEqual(kept.sessionGeneration, session.sessionGeneration)
        XCTAssertNil(paste.beginSession(target: nil).target)
        XCTAssertEqual(fake.probes, 1)
    }

    func testEachFinishedActionRecordsOneReceipt() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let session = paste.beginSession()

        let dispatched = await paste.execute(request(ref, session))
        XCTAssertEqual(dispatched, .dispatched(.textEdit))
        try await SearchTestSupport.waitUntil { try await fixture.useCount(ref) == 1 }

        fake.secureInput = true
        let copiedBeforeHiding = await paste.execute(request(ref, session))
        XCTAssertEqual(copiedBeforeHiding, .copiedInstead(.secureInput))
        try await SearchTestSupport.waitUntil { try await fixture.useCount(ref) == 2 }

        fake.secureInput = false
        let copiedAfterHiding = await paste.execute(request(ref, session, dismiss: { fake.front = .notes }))
        XCTAssertEqual(copiedAfterHiding, .copiedInstead(.targetChanged))
        try await SearchTestSupport.waitUntil { try await fixture.useCount(ref) == 3 }

        let copied = await paste.execute(request(ref, session, delivery: .copy))
        XCTAssertEqual(copied, .copied)
        try await SearchTestSupport.waitUntil { try await fixture.useCount(ref) == 4 }

        let stale = request(ref, session)
        session.advanceQueryGeneration()
        let refused = await paste.execute(stale)
        XCTAssertEqual(refused, .refused(.stale))
        try await Task.sleep(for: .milliseconds(100))
        let uses = try await fixture.useCount(ref)
        XCTAssertEqual(uses, 4)
        XCTAssertEqual(fake.sent, [9])
    }

    func testRequestingAccessOpensSettingsWhenTheSystemDoesNotGrantIt() throws {
        let fixture = try PasteFixture(self)
        let refusing = FakeDirectPasteSystem()
        let granting = FakeDirectPasteSystem()
        granting.grantsOnRequest = true

        fixture.service(system: refusing.system).requestDirectPasteAccess()
        fixture.service(system: granting.system).requestDirectPasteAccess()

        XCTAssertEqual(refusing.accessRequests, 1)
        XCTAssertEqual(refusing.settingsOpened, 1)
        XCTAssertEqual(granting.accessRequests, 1)
        XCTAssertEqual(granting.settingsOpened, 0)
    }

    func testAPasteRequestThatCannotHideThePanelOnlyCopies() async throws {
        let (fixture, ref) = try await makeFixture()
        let fake = FakeDirectPasteSystem()
        let paste = fixture.service(system: fake.system)
        let log = PasteLog()
        // A debug build stops at the report; the test records it instead.
        paste.reportProgrammingError = { log.programmingErrors.append($0) }
        let session = paste.beginSession()
        let unhidable = PasteRequest(ref: ref, queryGeneration: session.queryGeneration, mode: .original,
                                     session: session, delivery: .paste)

        let outcome = await paste.execute(unhidable)

        XCTAssertEqual(outcome, .copiedInstead(.cannotSendKeystroke))
        XCTAssertEqual(fixture.board.string(forType: .string), clip)
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.programmingErrors.count, 1)

        // It is the reason whatever the checks would say.
        fake.permitted = false
        let withoutPermission = await paste.execute(unhidable)
        XCTAssertEqual(withoutPermission, .copiedInstead(.cannotSendKeystroke))
        XCTAssertEqual(fake.sent, [])
        XCTAssertEqual(log.programmingErrors.count, 2)
    }

    private func makeFixture() async throws -> (PasteFixture, ContentRef) {
        let fixture = try PasteFixture(self)
        let ref = try await fixture.insert([[("public.utf8-plain-text", Data(clip.utf8))]])
        return (fixture, ref)
    }

    /// Every request can hide the panel, as the panel's are: a paste request without `dismiss` is a programming
    /// error, which `testAPasteRequestThatCannotHideThePanelOnlyCopies` covers.
    private func request(_ ref: ContentRef, _ session: PasteSession, delivery: PasteDelivery = .paste,
                         dismiss: @escaping @MainActor () -> Void = {}) -> PasteRequest {
        PasteRequest(ref: ref, queryGeneration: session.queryGeneration, mode: .original, session: session,
                     delivery: delivery, dismiss: dismiss)
    }
}

/// What the panel and the system saw during one paste.
@MainActor
private final class PasteLog {
    var dismissals = 0
    var boardAtDismiss: String?
    var boardAtSend: String?
    var dismissalsAtSend: Int?
    var queuedJobRan = false
    var queuedJobRanAtSend: Bool?
    var programmingErrors: [String] = []
}
