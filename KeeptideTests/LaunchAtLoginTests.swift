import Foundation
import XCTest
@testable import Keeptide

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testInitializationAndRefreshNeverRegisterAutomatically() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let model = LaunchAtLoginModel(service: service)

        XCTAssertEqual(model.state, .disabled)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(service.events, [])

        model.refresh()

        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(service.events, [])
    }

    func testExplicitEnableAndDisableUseActualServiceStatus() async {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let model = LaunchAtLoginModel(service: service)

        await model.setEnabled(true)
        XCTAssertEqual(model.state, .enabled)
        XCTAssertEqual(service.events, ["register"])

        await model.setEnabled(false)
        XCTAssertEqual(model.state, .disabled)
        XCTAssertEqual(service.events, ["register", "unregister"])
    }

    func testRegisterFailureKeepsActualStatusAndUsesSafeMessage() async {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestFailure.privatePath("/Users/alice/private")
        let model = LaunchAtLoginModel(service: service)

        await model.setEnabled(true)

        XCTAssertEqual(
            model.state,
            .failed(
                actual: .notRegistered,
                message: "Keeptide could not update Login Items. Try again."
            )
        )
        XCTAssertFalse(String(describing: model.state).contains("/Users/alice"))
        XCTAssertFalse(model.isBusy)
    }

    func testFailureReflectsStatusChangedByTheSystemDuringTheRequest() async {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.registerError = TestFailure.denied
        service.statusOnRegisterFailure = .requiresApproval
        let model = LaunchAtLoginModel(service: service)

        await model.setEnabled(true)

        XCTAssertEqual(
            model.state,
            .failed(
                actual: .requiresApproval,
                message: "Keeptide could not update Login Items. Try again."
            )
        )
    }

    func testUnregisterFailureKeepsActualEnabledStatus() async {
        let service = FakeLaunchAtLoginService(status: .enabled)
        service.unregisterError = TestFailure.denied
        let model = LaunchAtLoginModel(service: service)

        await model.setEnabled(false)

        XCTAssertEqual(
            model.state,
            .failed(
                actual: .enabled,
                message: "Keeptide could not update Login Items. Try again."
            )
        )
    }

    func testRequiresApprovalIsReportedWithoutRegisteringAgain() async {
        let service = FakeLaunchAtLoginService(status: .requiresApproval)
        let model = LaunchAtLoginModel(service: service)

        await model.setEnabled(true)

        XCTAssertEqual(model.state, .requiresApproval)
        XCTAssertEqual(service.events, [])
    }

    func testRefreshAdoptsExternalSystemChanges() {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let model = LaunchAtLoginModel(service: service)

        service.status = .enabled
        model.refresh()
        XCTAssertEqual(model.state, .enabled)

        service.status = .requiresApproval
        model.refresh()
        XCTAssertEqual(model.state, .requiresApproval)

        service.status = .notRegistered
        model.refresh()
        XCTAssertEqual(model.state, .disabled)
    }

    func testUnavailableNeverAttemptsRegistration() async {
        let service = FakeLaunchAtLoginService(status: .unavailable)
        let model = LaunchAtLoginModel(service: service)

        await model.setEnabled(true)

        XCTAssertEqual(model.state, .unavailable)
        XCTAssertEqual(service.events, [])
    }

    func testConcurrentRequestsRunSeriallyAndLatestSelectionWins() async throws {
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        service.suspendRegister = true
        let model = LaunchAtLoginModel(service: service)

        let enable = Task { await model.setEnabled(true) }
        try await waitUntil { service.hasSuspendedRegister }
        XCTAssertTrue(model.isBusy)

        let disable = Task { await model.setEnabled(false) }
        await Task.yield()
        model.refresh()
        XCTAssertEqual(service.events, ["register"])

        service.resumeRegister()
        await enable.value
        await disable.value

        XCTAssertEqual(service.events, ["register", "unregister"])
        XCTAssertEqual(service.maximumConcurrentOperations, 1)
        XCTAssertEqual(model.state, .disabled)
        XCTAssertFalse(model.isBusy)
    }

    private func waitUntil(
        attempts: Int = 1_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            await Task.yield()
        }
        throw TestFailure.timedOut
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus
    var registerError: Error?
    var unregisterError: Error?
    var statusOnRegisterFailure: LaunchAtLoginServiceStatus?
    var suspendRegister = false
    private(set) var events: [String] = []
    private(set) var maximumConcurrentOperations = 0
    private var concurrentOperations = 0
    private var registerContinuation: CheckedContinuation<Void, Error>?

    var hasSuspendedRegister: Bool { registerContinuation != nil }

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() async throws {
        events.append("register")
        concurrentOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
        defer { concurrentOperations -= 1 }
        if suspendRegister {
            try await withCheckedThrowingContinuation { registerContinuation = $0 }
        }
        if let registerError {
            if let statusOnRegisterFailure { status = statusOnRegisterFailure }
            throw registerError
        }
        status = .enabled
    }

    func unregister() async throws {
        events.append("unregister")
        concurrentOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, concurrentOperations)
        defer { concurrentOperations -= 1 }
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }

    func resumeRegister() {
        suspendRegister = false
        registerContinuation?.resume()
        registerContinuation = nil
    }
}

private enum TestFailure: Error {
    case denied
    case privatePath(String)
    case timedOut
}
