import Foundation

struct LaunchConfiguration: Sendable {
    let shouldRegisterGlobalHotKey: Bool
    let shouldShowQuickAccess: Bool
    let shouldShowLibrary: Bool
    let usesSyntheticHotKey: Bool

    init(arguments: [String], environment: [String: String]) {
        usesSyntheticHotKey = arguments.contains("--ui-testing") && arguments.contains("--synthetic-hotkey")
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
        shouldRegisterGlobalHotKey = !isRunningTests && !arguments.contains("--disable-global-hotkey")
        shouldShowQuickAccess = arguments.contains("--show-quick-access")
        shouldShowLibrary = arguments.contains("--show-library")
    }
}
