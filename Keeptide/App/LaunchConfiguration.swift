import Foundation

struct LaunchConfiguration: Sendable {
    let shouldRegisterGlobalHotKey: Bool
    let shouldShowQuickAccess: Bool
    let shouldShowLibrary: Bool

    init(arguments: [String], environment: [String: String]) {
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
        shouldRegisterGlobalHotKey = !isRunningTests && !arguments.contains("--disable-global-hotkey")
        shouldShowQuickAccess = arguments.contains("--show-quick-access")
        shouldShowLibrary = arguments.contains("--show-library")
    }
}
