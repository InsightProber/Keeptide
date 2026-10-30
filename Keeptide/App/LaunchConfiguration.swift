import Foundation

struct LaunchConfiguration: Sendable {
    let shouldRegisterGlobalHotKey: Bool
    let shouldShowQuickAccess: Bool
    let shouldShowLibrary: Bool
    let usesSyntheticHotKey: Bool
    let shouldInitializeCaptureSession: Bool
    let captureTestSessionID: UUID?
    let shouldCleanupCaptureTestSession: Bool
    let shouldSeedSyntheticClips: Bool
    /// `--manual-paste-qa`, for checking direct paste by hand: a throwaway library of harmless clips in place of the
    /// user's, and no recording. Debug builds only, and never under UI tests or XCTest.
    let shouldStartManualPasteQA: Bool

    init(arguments: [String], environment: [String: String]) {
        let isUITesting = arguments.contains("--ui-testing")
        usesSyntheticHotKey = isUITesting && arguments.contains("--synthetic-hotkey")
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
        shouldRegisterGlobalHotKey = (usesSyntheticHotKey || !isRunningTests)
            && !arguments.contains("--disable-global-hotkey")
        shouldShowQuickAccess = arguments.contains("--show-quick-access")
        shouldShowLibrary = arguments.contains("--show-library")

        #if DEBUG
        captureTestSessionID = isUITesting ? (try? CaptureTestConfiguration.parse(arguments))?.id : nil
        shouldCleanupCaptureTestSession = captureTestSessionID != nil && arguments.contains("--cleanup-capture-test-session")
        shouldSeedSyntheticClips = captureTestSessionID != nil && arguments.contains("--seed-synthetic-clips")
        shouldStartManualPasteQA = arguments.contains("--manual-paste-qa") && !isUITesting && !isRunningTests
        #else
        captureTestSessionID = nil
        shouldCleanupCaptureTestSession = false
        shouldSeedSyntheticClips = false
        shouldStartManualPasteQA = false
        #endif
        shouldInitializeCaptureSession = captureTestSessionID != nil || (!isRunningTests && !isUITesting)
    }
}
