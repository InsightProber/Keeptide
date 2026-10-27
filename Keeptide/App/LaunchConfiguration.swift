import Foundation

struct LaunchConfiguration: Sendable {
    let shouldRegisterGlobalHotKey: Bool
    let shouldShowQuickAccess: Bool
    let shouldShowLibrary: Bool
    let usesSyntheticHotKey: Bool
    let shouldInitializeCaptureSession: Bool
    let captureTestSessionID: UUID?

    init(arguments: [String], environment: [String: String]) {
        let isUITesting = arguments.contains("--ui-testing")
        usesSyntheticHotKey = isUITesting && arguments.contains("--synthetic-hotkey")
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
        shouldRegisterGlobalHotKey = (usesSyntheticHotKey || !isRunningTests)
            && !arguments.contains("--disable-global-hotkey")
        shouldShowQuickAccess = arguments.contains("--show-quick-access")
        shouldShowLibrary = arguments.contains("--show-library")

        #if DEBUG
        if isUITesting,
           let flagIndex = arguments.firstIndex(of: "--capture-test-session"),
           arguments.indices.contains(flagIndex + 1) {
            captureTestSessionID = UUID(uuidString: arguments[flagIndex + 1])
        } else {
            captureTestSessionID = nil
        }
        #else
        captureTestSessionID = nil
        #endif
        shouldInitializeCaptureSession = captureTestSessionID != nil || (!isRunningTests && !isUITesting)
    }
}
