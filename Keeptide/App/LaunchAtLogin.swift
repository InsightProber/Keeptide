import Foundation
import Observation
import ServiceManagement

enum LaunchAtLoginServiceStatus: Equatable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case unavailable
}

enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
    case failed(actual: LaunchAtLoginServiceStatus, message: String)

    var actualStatus: LaunchAtLoginServiceStatus {
        switch self {
        case .disabled: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .unavailable: .unavailable
        case .failed(let actual, _): actual
        }
    }
}

@MainActor
protocol LaunchAtLoginServicing: AnyObject {
    var status: LaunchAtLoginServiceStatus { get }
    func register() async throws
    func unregister() async throws
}

@MainActor
final class SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginServiceStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .unavailable
        @unknown default: .unavailable
        }
    }

    func register() async throws {
        try SMAppService.mainApp.register()
    }

    func unregister() async throws {
        try await SMAppService.mainApp.unregister()
    }
}

@MainActor
protocol LaunchAtLoginControlling: AnyObject, Observable {
    var state: LaunchAtLoginState { get }
    var isBusy: Bool { get }
    func refresh()
    func setEnabled(_ enabled: Bool) async
}

@MainActor @Observable
final class LaunchAtLoginModel: LaunchAtLoginControlling {
    private static let safeFailureMessage = "Keeptide could not update Login Items. Try again."

    private let service: any LaunchAtLoginServicing
    @ObservationIgnored private var operationTail: Task<Void, Never>?
    @ObservationIgnored private var requestSequence = 0
    @ObservationIgnored private var queuedRequestCount = 0

    private(set) var state: LaunchAtLoginState
    private(set) var isBusy = false

    init(service: any LaunchAtLoginServicing = SystemLaunchAtLoginService()) {
        self.service = service
        state = Self.state(for: service.status)
    }

    func refresh() {
        guard !isBusy else { return }
        state = Self.state(for: service.status)
    }

    func setEnabled(_ enabled: Bool) async {
        requestSequence += 1
        let sequence = requestSequence
        let predecessor = operationTail
        queuedRequestCount += 1
        isBusy = true

        let operation = Task { @MainActor [weak self] in
            await predecessor?.value
            guard let self else { return }
            await self.performSetEnabled(enabled)
            self.queuedRequestCount -= 1
            self.isBusy = self.queuedRequestCount > 0
            if self.requestSequence == sequence {
                self.operationTail = nil
            }
        }
        operationTail = operation
        await operation.value
    }

    private func performSetEnabled(_ enabled: Bool) async {
        let current = service.status
        if enabled {
            switch current {
            case .enabled, .requiresApproval, .unavailable:
                state = Self.state(for: current)
                return
            case .notRegistered:
                break
            }
        } else {
            switch current {
            case .notRegistered, .unavailable:
                state = Self.state(for: current)
                return
            case .enabled, .requiresApproval:
                break
            }
        }

        do {
            if enabled {
                try await service.register()
            } else {
                try await service.unregister()
            }
            state = Self.state(for: service.status)
        } catch {
            state = .failed(actual: service.status, message: Self.safeFailureMessage)
        }
    }

    private static func state(for status: LaunchAtLoginServiceStatus) -> LaunchAtLoginState {
        switch status {
        case .notRegistered: .disabled
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .unavailable: .unavailable
        }
    }
}
