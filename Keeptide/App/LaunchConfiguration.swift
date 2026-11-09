import Foundation

struct LaunchConfiguration: Sendable {
    let shouldRegisterGlobalHotKey: Bool
    let shouldShowQuickAccess: Bool
    let shouldShowLibrary: Bool
    let shouldShowSettings: Bool
    let usesSyntheticHotKey: Bool
    /// Normal launches may show the welcome window when its version has not been completed. Automated and manual
    /// QA launches stay deterministic and quiet unless an isolated UI test explicitly asks for it.
    let shouldPresentOnboardingIfNeeded: Bool
    let shouldForceOnboarding: Bool
    let shouldUseEphemeralApplicationState: Bool
    let shouldInitializeCaptureSession: Bool
    let captureTestSessionID: UUID?
    let shouldCleanupCaptureTestSession: Bool
    let shouldSeedSyntheticClips: Bool
    /// `--seed-synthetic-snippets` with the clips: two collections and three snippets as well, for UI tests of the
    /// quick-access lists.
    let shouldSeedSyntheticSnippets: Bool
    /// `--fake-text-recognition`: text in images is recognized by a stand-in that finds the same synthetic text in
    /// any image, for UI tests. Debug builds and test sessions only.
    let usesFakeTextRecognition: Bool
    /// `--manual-paste-qa`, for checking direct paste by hand: a throwaway library of harmless clips in place of the
    /// user's, and no recording. Debug builds only, and never under UI tests or XCTest.
    let shouldStartManualPasteQA: Bool

    init(arguments: [String], environment: [String: String]) {
        let isUITesting = arguments.contains("--ui-testing")
        usesSyntheticHotKey = isUITesting && arguments.contains("--synthetic-hotkey")
        let isRunningTests = Self.isRunningTests(environment)
        shouldRegisterGlobalHotKey = (usesSyntheticHotKey || !isRunningTests)
            && !arguments.contains("--disable-global-hotkey")
        shouldShowQuickAccess = arguments.contains("--show-quick-access")
        shouldShowLibrary = arguments.contains("--show-library")
        shouldShowSettings = arguments.contains("--show-settings")

        #if DEBUG
        captureTestSessionID = isUITesting ? (try? CaptureTestConfiguration.parse(arguments))?.id : nil
        shouldCleanupCaptureTestSession = captureTestSessionID != nil && arguments.contains("--cleanup-capture-test-session")
        shouldSeedSyntheticClips = captureTestSessionID != nil && arguments.contains("--seed-synthetic-clips")
        shouldSeedSyntheticSnippets = shouldSeedSyntheticClips && arguments.contains("--seed-synthetic-snippets")
        usesFakeTextRecognition = captureTestSessionID != nil && arguments.contains("--fake-text-recognition")
        shouldStartManualPasteQA = arguments.contains("--manual-paste-qa") && !isUITesting && !isRunningTests
        #else
        captureTestSessionID = nil
        shouldCleanupCaptureTestSession = false
        shouldSeedSyntheticClips = false
        shouldSeedSyntheticSnippets = false
        usesFakeTextRecognition = false
        shouldStartManualPasteQA = false
        #endif
        shouldForceOnboarding = captureTestSessionID != nil && arguments.contains("--show-onboarding")
        shouldUseEphemeralApplicationState = captureTestSessionID == nil && (isUITesting || isRunningTests)
        shouldPresentOnboardingIfNeeded = !isRunningTests && !isUITesting && !shouldStartManualPasteQA
        shouldInitializeCaptureSession = captureTestSessionID != nil || (!isRunningTests && !isUITesting)
    }

    /// Whether XCTest runs in the process `environment` belongs to, as in the app that hosts the unit tests.
    static func isRunningTests(_ environment: [String: String]) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
    }
}
