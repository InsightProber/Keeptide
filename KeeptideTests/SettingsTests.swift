import AppKit
import ApplicationServices
import SwiftUI
import Observation
import XCTest
@testable import Keeptide

@MainActor
final class SettingsTests: XCTestCase {
    func testSettingsTabsHaveTheProductOrder() {
        XCTAssertEqual(SettingsTab.allCases.map(\.title), [
            "General", "Shortcuts", "Privacy", "AI", "iCloud",
        ])
        XCTAssertEqual(SettingsTab.ai.systemImage, "sparkles")
    }

    func testAppleIntelligenceIsSaidAsTheSystemReportsItAndNothingClaimsToUseIt() {
        XCTAssertEqual(AppleIntelligenceState(.available), .available)
        XCTAssertEqual(AppleIntelligenceState(.unavailable(.deviceNotEligible)), .notOnThisMac)
        XCTAssertEqual(AppleIntelligenceState(.unavailable(.appleIntelligenceNotEnabled)), .turnedOff)
        XCTAssertEqual(AppleIntelligenceState(.unavailable(.modelNotReady)), .gettingReady)
        // Where it is missing, the page says what still works without it; where it is there, nothing uses it yet, and
        // the page says so rather than offering it as an engine.
        for missing in [AppleIntelligenceState.notOnThisMac, .turnedOff, .gettingReady] {
            XCTAssertTrue(missing.sentence.hasSuffix("Translation and text recognition still work on this Mac."),
                          missing.sentence)
        }
        XCTAssertEqual(AppleIntelligenceState.available.sentence,
                       "Apple Intelligence is available on this Mac. Keeptide doesn't use it yet.")
    }

    func testAFixedLanguageToTranslateIntoIsKeptApartFromTheLastUsedOne() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)
        XCTAssertNil(preferences.fixedTranslationTarget, "The last used language until one is fixed in Settings")
        XCTAssertEqual(QuickAccessPreferences.fixedTranslationTargetKey, "translation.fixedTargetLanguage")

        preferences.fixedTranslationTarget = "ja"
        preferences.translationTarget = "fr"

        let reopened = QuickAccessPreferences(defaults: defaults)
        XCTAssertEqual(reopened.fixedTranslationTarget, "ja")
        XCTAssertEqual(reopened.translationTarget, "fr", "Choosing in the language menu still keeps the last used one")
        reopened.fixedTranslationTarget = nil
        XCTAssertNil(QuickAccessPreferences(defaults: defaults).fixedTranslationTarget)
        // What is stored is not trusted: anything but a code reads as no fixed language.
        for stored: Any in [3, ""] {
            defaults.set(stored, forKey: QuickAccessPreferences.fixedTranslationTargetKey)
            XCTAssertNil(QuickAccessPreferences(defaults: defaults).fixedTranslationTarget, "\(stored)")
        }
    }

    func testTheAIPageSaysWhatEachOfThePersonsLanguagesNeedsToBeTranslatedIntoTheTarget() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "en-GB", "ja-JP", "fr-FR", "zh-Hans-CN", "de-DE"], statuses: [
            ("ja-JP", "zh-Hans-CN", .needsDownload), ("fr-FR", "zh-Hans-CN", .unsupported),
        ])
        let model = AISettingsModel(preferences: QuickAccessPreferences(defaults: try makeDefaults()),
                                    translator: translator, appleIntelligence: { .notOnThisMac },
                                    preferredLanguages: { ["zh-Hans-CN", "ja-JP", "fr-FR"] })

        await model.refresh()

        XCTAssertEqual(model.appleIntelligence, .notOnThisMac)
        XCTAssertEqual(model.target?.name, "Chinese (Simplified)")
        // The person's languages and English, as Translation offers them, but the one translations go into: each says
        // what translating from it into that one needs, as the language menu says it.
        XCTAssertEqual(model.languages.map(\.name), ["Japanese", "French", "English"])
        XCTAssertEqual(model.languages.map(\.status), ["Not Downloaded", "Not Available on This Mac", "Downloaded"])
        XCTAssertEqual(model.languages.map(\.spokenName),
                       ["Japanese, not downloaded", "French, not available on this Mac", "English, downloaded"])
    }

    func testTheAIPageSpeaksOfTheLanguageFixedInSettingsElseTheLastUsedOne() async throws {
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"])
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        preferences.translationTarget = "en"
        let model = AISettingsModel(preferences: preferences, translator: translator, appleIntelligence: { .available },
                                    preferredLanguages: { ["zh-Hans-CN"] })
        await model.refresh()
        XCTAssertEqual(model.target?.name, "English", "The last used language")
        XCTAssertEqual(model.languages.map(\.name), ["Chinese (Simplified)"])

        preferences.fixedTranslationTarget = "ja"
        await model.refresh()

        XCTAssertEqual(model.target?.name, "Japanese")
        XCTAssertEqual(model.languages.map(\.name), ["Chinese (Simplified)", "English"])
        // Translate to offers every language Translation does, the person's first, then the others by name.
        XCTAssertEqual(model.targetChoices.preferred.map(\.name), ["Chinese (Simplified)", "English"])
        XCTAssertEqual(model.targetChoices.others.map(\.name), ["Japanese"])
        XCTAssertEqual(model.targetChoices.others.map(\.code), ["ja"])
    }

    func testTheAIPageSaysWhatTheEnginesOnThisMacDoAndFollowsTheLanguageToTranslateInto() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"], statuses: [("ja-JP", "zh-Hans-CN", .needsDownload)])
        var opened: [URL] = []
        let ai = AISettingsModel(preferences: preferences, translator: translator, appleIntelligence: { .turnedOff },
                                 preferredLanguages: { ["zh-Hans-CN", "ja-JP"] }, open: { opened.append($0) })
        let (hosting, window, status) = showAIPage(makeSettingsModel(quickAccess: preferences, ai: ai))
        defer { window.close() }
        func elements() -> [NSObject] { accessibilityElements(in: hosting) }
        let built = waitUntil { elements().contains(where: reads("Japanese, not downloaded")) }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        let described = elements().map {
            "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
        }

        // What Apple Intelligence is doing on this Mac, and what still works without it.
        XCTAssertTrue(built, "\(described)")
        XCTAssertTrue(elements().contains(where: reads(AppleIntelligenceState.turnedOff.sentence)), "\(described)")
        // Each engine is this Mac's own, named for what it does; recognized text keeps its line breaks until they are
        // joined, as the panel's capsule does; translations are made in the last used language until one is fixed.
        func identified(_ identifier: String) -> NSObject? {
            elements().first { attribute(of: $0, "accessibilityIdentifier") as? String == identifier }
        }
        XCTAssertEqual(identified("TextRecognitionEngine").map(reads("Text recognition engine, On This Mac")), true,
                       "\(described)")
        XCTAssertEqual(identified("TranslationEngine").map(reads("Translation engine, On This Mac")), true, "\(described)")
        func popUp(_ title: String) -> NSObject? {
            elements().first { role(of: $0) == .popUpButton && name(of: $0) == title }
        }
        func value(_ title: String) -> String? { popUp(title).flatMap { attribute(of: $0, "accessibilityValue") as? String } }
        XCTAssertEqual(value("Line breaks"), "Keep Line Breaks", "\(described)")
        XCTAssertEqual(value("Translate to"), "Last Used", "\(described)")
        preferences.keepsLineBreaks = false
        XCTAssertTrue(waitUntil { value("Line breaks") == "Join Lines into Paragraphs" })
        // The person's languages, but the one translations go into, which is said before them, say what translating
        // from them into it needs.
        XCTAssertTrue(elements().contains(where: reads("Into Chinese (Simplified)")), "\(described)")
        XCTAssertTrue(elements().contains(where: reads("English, downloaded")), "\(described)")
        XCTAssertFalse(elements().contains(where: reads("Chinese (Simplified), ")), "\(described)")

        // A language chosen in quick access, the last used one, is the one the page speaks of next.
        preferences.translationTarget = "ja"
        XCTAssertTrue(waitUntil { elements().contains(where: reads("Into Japanese")) }, "\(described)")
        XCTAssertTrue(waitUntil { elements().contains(where: reads("Chinese (Simplified), downloaded")) }, "\(described)")
        XCTAssertFalse(elements().contains(where: reads("Japanese, ")), "\(described)")
        // So is one fixed here.
        preferences.fixedTranslationTarget = "en"
        XCTAssertTrue(waitUntil { value("Translate to") == "English" }, "\(described)")
        XCTAssertTrue(waitUntil { elements().contains(where: reads("Japanese, downloaded")) }, "\(described)")
        XCTAssertTrue(elements().contains(where: reads("Into English")), "\(described)")
        // A stored code is shown as quick access takes it, and one Translation doesn't offer is shown as unavailable.
        preferences.fixedTranslationTarget = "ja-JP"
        XCTAssertTrue(waitUntil { value("Translate to") == "Japanese" }, "\(described)")
        preferences.fixedTranslationTarget = "sw"
        XCTAssertTrue(waitUntil { value("Translate to") == "Swahili (Not Available on This Mac)" }, "\(described)")

        // Languages are downloaded and removed in System Settings, which the page opens at Language & Region.
        let manage = try XCTUnwrap(elements().first { role(of: $0) == .button && name(of: $0) == "Manage in System Settings…" },
                                   "\(described)")
        press(manage)
        XCTAssertTrue(waitUntil { !opened.isEmpty })
        XCTAssertEqual(opened, [URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")])
    }

    func testTheAIPageSaysWhereOtherLanguagesComeFromWhenThePersonHasOnlyOne() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "ja-JP"])
        let ai = AISettingsModel(preferences: preferences, translator: translator, appleIntelligence: { .notOnThisMac },
                                 preferredLanguages: { ["en-US"] })
        let (hosting, window, status) = showAIPage(makeSettingsModel(quickAccess: preferences, ai: ai))
        defer { window.close() }
        func elements() -> [NSObject] { accessibilityElements(in: hosting) }
        let built = waitUntil { elements().contains(where: reads("Into English")) }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        let described = elements().map {
            "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
        }

        // The only language in the person's list is the one translations go into: there is nothing to list, and the
        // page says where the languages to translate from come from.
        XCTAssertTrue(built, "\(described)")
        XCTAssertTrue(elements().contains(where: reads("Languages you add in Language & Region show here.")),
                      "\(described)")
        XCTAssertFalse(elements().contains(where: reads(", downloaded")), "\(described)")
    }

    func testTheSettingsWindowReadsTheAIPageAgainAsItOpensAndAsKeeptideBecomesActiveWhileItShows() async throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"], statuses: [("ja-JP", "zh-Hans-CN", .needsDownload)])
        let ai = AISettingsModel(preferences: preferences, translator: translator, appleIntelligence: { .notOnThisMac },
                                 preferredLanguages: { ["zh-Hans-CN", "ja-JP"] })
        // The window opens on another page, so nothing but the window reads the AI page.
        let controller = SettingsWindowController(model: makeSettingsModel(quickAccess: preferences, ai: ai),
                                                  setActivationPolicy: { _ in })
        defer { controller.window?.close() }
        func japanese() -> String? { ai.languages.first { $0.name == "Japanese" }?.status }

        controller.show()
        try await SearchTestSupport.waitUntil { japanese() == "Not Downloaded" }
        // Coming back to Keeptide while the window shows, as from System Settings once a language is downloaded.
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"])
        controller.refreshIfOpen()
        try await SearchTestSupport.waitUntil { japanese() == "Downloaded" }
        // Closed, it reads nothing; opened again, it reads it all.
        controller.window?.close()
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"], statuses: [("ja-JP", "zh-Hans-CN", .unsupported)])
        controller.refreshIfOpen()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(japanese(), "Downloaded")
        controller.show()
        try await SearchTestSupport.waitUntil { japanese() == "Not Available on This Mac" }
    }

    func testAReadOfTheAIPageThatANewerOneOvertakesChangesNothing() async throws {
        let translator = GatedTranslator(first: ["en-US", "zh-Hans-CN"], later: ["en-US", "zh-Hans-CN", "ja-JP"])
        let model = AISettingsModel(preferences: QuickAccessPreferences(defaults: try makeDefaults()),
                                    translator: translator, appleIntelligence: { .notOnThisMac },
                                    preferredLanguages: { ["zh-Hans-CN"] })
        let overtaken = Task { await model.refresh() }
        try await SearchTestSupport.waitUntil { translator.isWaiting }
        await model.refresh()
        XCTAssertEqual(model.targetChoices.others.map(\.name), ["Japanese"])

        translator.open()
        await overtaken.value

        XCTAssertEqual(model.targetChoices.others.map(\.name), ["Japanese"], "The newer read's languages stay")
    }

    func testAFixedLanguageOutsideTheChoicesIsStillShownAndTheLastLanguagesListedAreKept() async throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        preferences.translationTarget = "en"
        preferences.fixedTranslationTarget = "ja"
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"])
        let model = AISettingsModel(preferences: preferences, translator: translator, appleIntelligence: { .notOnThisMac },
                                    preferredLanguages: { ["zh-Hans-CN"] })
        // Before Translation's languages are read, the fixed one is still a choice, so Translate to shows it.
        XCTAssertEqual(model.unlistedFixedTarget?.name, "Japanese")
        await model.refresh()
        XCTAssertNil(model.unlistedFixedTarget, "It is among the choices once they are read")

        // One Translation doesn't offer stays a choice, said to be unavailable, and translations are made in the last
        // used language.
        preferences.fixedTranslationTarget = "sw"
        await model.refresh()
        XCTAssertEqual(model.unlistedFixedTarget?.name, "Swahili")
        XCTAssertEqual(model.target?.name, "English")
        // Where Translation lists nothing for a moment, the languages read before stay.
        translator.script(languages: [])
        await model.refresh()
        XCTAssertEqual(model.targetChoices.others.map(\.name), ["Japanese"])
    }

    func testAppleIntelligenceIsSaidAsTheSystemHasItNow() throws {
        var state = AppleIntelligenceState.gettingReady
        let model = AISettingsModel(preferences: QuickAccessPreferences(defaults: try makeDefaults()),
                                    translator: ScriptedTranslator(), appleIntelligence: { state })
        XCTAssertEqual(model.appleIntelligence, .gettingReady, "Before anything else is read")
        // Its model finishing getting ready shows without reading the rest again.
        state = .available
        XCTAssertEqual(model.appleIntelligence, .available)
    }

    func testTranslatingNewTextAutomaticallyIsOffUntilTurnedOnAndIsKept() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)
        XCTAssertFalse(preferences.translatesAutomatically)
        XCTAssertEqual(QuickAccessPreferences.translatesAutomaticallyKey, "translation.automatic")

        preferences.translatesAutomatically = true

        XCTAssertTrue(QuickAccessPreferences(defaults: defaults).translatesAutomatically)
        // What is stored is not trusted: anything but a flag reads as off.
        defaults.set("yes", forKey: QuickAccessPreferences.translatesAutomaticallyKey)
        XCTAssertFalse(QuickAccessPreferences(defaults: defaults).translatesAutomatically)
    }

    func testTranslateAutomaticallyGivesNewTextTheLanguagesQuickAccessUses() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let environment = AppEnvironment(quickAccessPreferences: preferences)
        func languages() -> (fixed: String?, lastUsed: String?)? { environment.captureSession.automaticTranslation?() ?? nil }
        XCTAssertNil(languages(), "Off at first, so nothing copied is translated")

        preferences.translatesAutomatically = true
        preferences.fixedTranslationTarget = "ja"
        preferences.translationTarget = "fr"

        XCTAssertEqual(languages()?.fixed, "ja")
        XCTAssertEqual(languages()?.lastUsed, "fr")
        preferences.translatesAutomatically = false
        XCTAssertNil(languages())
    }

    func testTheAIPageOffersToTranslateNewTextAutomaticallyAndSaysHow() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let translator = ScriptedTranslator()
        translator.script(languages: ["en-US", "ja-JP", "zh-Hans-CN"])
        let ai = AISettingsModel(preferences: preferences, translator: translator, appleIntelligence: { .notOnThisMac },
                                 preferredLanguages: { ["zh-Hans-CN", "ja-JP"] })
        let (hosting, window, status) = showAIPage(makeSettingsModel(quickAccess: preferences, ai: ai))
        defer { window.close() }
        func elements() -> [NSObject] { accessibilityElements(in: hosting) }
        let title = "Translate automatically"
        func toggle() -> NSObject? { elements().first { role(of: $0) == .checkBox && name(of: $0)?.hasPrefix(title) == true } }
        let built = waitUntil { toggle() != nil }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        let described = elements().map {
            "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
        }
        func isOn() -> Int? { (toggle()?.value(forKey: "accessibilityValue") as? NSNumber)?.intValue }

        XCTAssertEqual(isOn(), 0, "Off to begin with: \(described)")
        XCTAssertEqual(toggle().flatMap { attribute(of: $0, "accessibilityIdentifier") as? String },
                       "TranslateAutomaticallyToggle")
        XCTAssertTrue(elements().contains(where: reads(
            "Translates new text in other languages into your target language on this Mac. When off, text is "
                + "translated only when you ask.")), "\(described)")
        preferences.translatesAutomatically = true
        XCTAssertTrue(waitUntil { isOn() == 1 })
    }

    func testManagingIgnoredAppsPresentsTheSheetOverSettings() {
        let model = makeSettingsModel()
        XCTAssertFalse(model.showsIgnoredApplications)

        model.presentIgnoredApplications()

        XCTAssertTrue(model.showsIgnoredApplications)
    }

    func testThePrivacyPageManagesIgnoredAppsAndHasNoRecordingSwitch() throws {
        let model = makeSettingsModel()
        model.selectedTab = .privacy
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        func identified(_ identifier: String) -> (NSObject) -> Bool {
            { self.attribute(of: $0, "accessibilityIdentifier") as? String == identifier }
        }
        let built = waitUntil { accessibilityElements(in: hosting).contains(where: identified("ManageIgnoredApplicationsButton")) }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        let elements = accessibilityElements(in: hosting)
        let described = elements.map {
            "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
        }

        // The ignored apps are managed here, and history and storage are set here as before.
        XCTAssertTrue(built, "\(described)")
        XCTAssertTrue(elements.contains(where: identified("LifecycleSettingsUnavailable")), "\(described)")
        // There is no switch for new copies, no state of one, and nothing speaks of recording, the page's tab included.
        for identifier in ["CaptureEnabledToggle", "RecordingAvailabilityStatus"] {
            XCTAssertFalse(elements.contains(where: identified(identifier)), "\(identifier): \(described)")
        }
        XCTAssertFalse(elements.contains { element in
            ["accessibilityLabel", "accessibilityValue", "accessibilityTitle", "accessibilityHelp"].contains {
                (attribute(of: element, $0) as? String)?.localizedCaseInsensitiveContains("record") == true
            }
        }, "\(described)")
    }

    func testTheGeneralPageSaysWhetherDirectPasteIsOnAndWhatFinishesIt() throws {
        var current: DirectPasteAccessState? = .off
        var turnOns = 0
        var quits = 0
        let directPaste = DirectPasteSettingsModel(read: { current }, turnOn: { turnOns += 1 }, quit: { quits += 1 })
        directPaste.refresh()
        XCTAssertEqual(directPaste.state, .off)
        let hosting = NSHostingView(rootView: SettingsView(model: makeSettingsModel(directPaste: directPaste)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        func identified(_ identifier: String) -> (NSObject) -> Bool {
            { self.attribute(of: $0, "accessibilityIdentifier") as? String == identifier }
        }
        func shows(_ identifier: String) -> Bool {
            accessibilityElements(in: hosting).contains(where: identified(identifier))
        }
        func statusSays(_ text: String) -> Bool {
            accessibilityElements(in: hosting).filter(identified("DirectPasteStatus")).contains { element in
                ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains {
                    (self.attribute(of: element, $0) as? String)?.contains(text) == true
                }
            }
        }
        let built = waitUntil { shows("DirectPasteStatus") }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        func described() -> String {
            accessibilityElements(in: hosting).map {
                "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
            }.joined(separator: " | ")
        }

        // Off: it says so, and offers to turn it on.
        XCTAssertTrue(built, described())
        XCTAssertTrue(statusSays("Off"), described())
        XCTAssertTrue(shows("TurnOnDirectPasteButton"), described())
        XCTAssertFalse(shows("QuitToFinishDirectPasteButton"), described())

        // Allowed, but this run cannot send keystrokes yet: it says to reopen Keeptide, and offers to quit it.
        current = .awaitsReopen
        directPaste.refresh()
        XCTAssertTrue(waitUntil { shows("QuitToFinishDirectPasteButton") }, described())
        XCTAssertTrue(statusSays("Reopen Keeptide"), described())
        XCTAssertFalse(shows("TurnOnDirectPasteButton"), described())

        // On: nothing left to do.
        current = .on
        directPaste.refresh()
        XCTAssertTrue(waitUntil { statusSays("On") && !shows("QuitToFinishDirectPasteButton") }, described())
        XCTAssertFalse(shows("TurnOnDirectPasteButton"), described())

        // Without a library to paste from, the page says nothing about it.
        current = nil
        directPaste.refresh()
        XCTAssertTrue(waitUntil { !shows("DirectPasteStatus") }, described())

        directPaste.turnOn()
        directPaste.quit()
        XCTAssertEqual(turnOns, 1)
        XCTAssertEqual(quits, 1)
    }

    func testSettingsModelKeepsSharedReferencesAndCanReleaseAStoreScopedLifecycle() throws {
        let quickAccess = QuickAccessPreferences(defaults: try makeDefaults())
        let capture = CapturePreferences(defaults: try makeDefaults())
        let shortcut = makeShortcutCoordinator()
        let login = SettingsLaunchAtLoginFake()
        weak var released: LifecycleSettingsModel?
        let model: SettingsModel
        do {
            let lifecycle = LifecycleSettingsModel(preferences: LifecyclePreferences(defaults: try makeDefaults()))
            released = lifecycle
            model = SettingsModel(
                quickAccess: quickAccess,
                capture: capture,
                lifecycle: lifecycle,
                shortcut: shortcut,
                launchAtLogin: login
            )
            XCTAssertTrue(model.quickAccess === quickAccess)
            XCTAssertTrue(model.capture === capture)
            XCTAssertTrue(model.shortcut === shortcut)
            XCTAssertTrue(model.launchAtLogin === login)
            XCTAssertTrue(model.lifecycle === lifecycle)
        }
        XCTAssertNotNil(released)
        model.updateLifecycle(nil)
        XCTAssertNil(released)
        XCTAssertEqual(model.cloud, .unavailableInThisBuild)
        XCTAssertNil(model.actions.exportArchive)
    }

    func testLifecycleRebindPreservesTheSelectedSettingsTab() throws {
        let model = makeSettingsModel()
        let controller = SettingsWindowController(model: model, setActivationPolicy: { _ in })
        defer { controller.close() }
        model.selectedTab = .privacy

        controller.updateLifecycle(
            LifecycleSettingsModel(preferences: LifecyclePreferences(defaults: try makeDefaults()))
        )

        XCTAssertEqual(model.selectedTab, .privacy)
    }

    func testClosingSettingsDoesNotRestoreAccessoryWhileAnotherWindowNeedsTheDock() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = SettingsWindowController(
            model: makeSettingsModel(),
            setActivationPolicy: { policies.append($0) },
            shouldRestoreAccessory: { false }
        )
        controller.show()
        controller.close()

        XCTAssertEqual(policies, [.regular])
    }

    func testTheEndsFadeUntilTurnedOff() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)
        XCTAssertTrue(preferences.fadesStripEnds)
        XCTAssertNil(defaults.object(forKey: "quickAccess.fadesStripEnds"))
        preferences.fadesStripEnds = false
        XCTAssertEqual(defaults.object(forKey: "quickAccess.fadesStripEnds") as? Bool, false)
        XCTAssertEqual(QuickAccessPreferences.fadesStripEndsKey, "quickAccess.fadesStripEnds")
        XCTAssertFalse(preferences.stripStyle.fadesEnds)
        XCTAssertFalse(QuickAccessPreferences(defaults: defaults).fadesStripEnds)
    }

    func testTheLanguageChosenToTranslateIntoIsKept() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)
        XCTAssertNil(preferences.translationTarget, "None until one is chosen")
        XCTAssertEqual(QuickAccessPreferences.translationTargetKey, "translation.targetLanguage")

        preferences.translationTarget = "ja"

        XCTAssertEqual(defaults.string(forKey: QuickAccessPreferences.translationTargetKey), "ja")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).translationTarget, "ja")
        // What is stored is not trusted: anything but a code reads as no choice.
        defaults.set(3, forKey: QuickAccessPreferences.translationTargetKey)
        XCTAssertNil(QuickAccessPreferences(defaults: defaults).translationTarget)
        defaults.set("", forKey: QuickAccessPreferences.translationTargetKey)
        XCTAssertNil(QuickAccessPreferences(defaults: defaults).translationTarget)
    }

    func testTheFadeSwitchReadsWithItsTitle() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        func fadeSwitch() -> NSObject? {
            accessibilityElements(in: hosting).first {
                role(of: $0) == .checkBox && name(of: $0) == "Fade the ends of the strip"
            }
        }
        let built = waitUntil { fadeSwitch() != nil }
        if !built, status != .success { throw XCTSkip("Accessibility is not available to the test host") }
        func value() -> Int? { (fadeSwitch()?.value(forKey: "accessibilityValue") as? NSNumber)?.intValue }
        XCTAssertEqual(value(), 1)
        preferences.fadesStripEnds = false
        XCTAssertTrue(waitUntil { value() == 0 })
    }

    func testEnlargementTextUsesTheNormalizedScaleWithoutAccessibilityPermission() {
        for (scale, expected) in [(1.0, "None"), (1.13, "13% larger"), (0.9, "None"), (1.3, "25% larger"),
                                  (Double.nan, "6% larger"), (.infinity, "6% larger"), (-.infinity, "6% larger")] {
            XCTAssertEqual(SettingsView.enlargement(scale), expected)
        }
    }

    func testRetentionConfirmationNamesExactImpactAndStorageUsageStatesPartialCoverage() {
        XCTAssertEqual(
            SettingsView.confirmationMessage(historyCount: 1),
            "This will expire 1 active clip from clipboard history. Saved snippets are kept."
        )
        XCTAssertEqual(
            SettingsView.confirmationMessage(historyCount: 12),
            "This will expire 12 active clips from clipboard history. Saved snippets are kept."
        )
        let complete = StorageUsageReport(allocatedBytes: [.contentDatabase: 2_000], issues: [])
        let partial = StorageUsageReport(
            allocatedBytes: [.contentDatabase: 2_000],
            issues: [StorageUsageIssue(relativePath: "Content_SUPPORT", reason: .unreadable)]
        )
        XCTAssertFalse(SettingsView.usageDescription(complete).hasPrefix("At least "))
        XCTAssertTrue(SettingsView.usageDescription(partial).hasPrefix("At least "))
    }

    func testDefaultsAreMediumAndTicksOn() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())

        XCTAssertEqual(preferences.cardSize, .medium)
        XCTAssertTrue(preferences.trackpadTicks)
    }

    func testStoredClipsInARowBecomeACardSize() throws {
        // Where no card size is stored, the old clips-in-a-row choice stands in for it: 7 gave the largest
        // previews and 11 the smallest; any other value, and none, give the default.
        let cases: [(stored: Int?, size: CardSize)] = [
            (7, .large), (9, .medium), (11, .small), (5, .medium), (nil, .medium),
        ]
        for (stored, size) in cases {
            let defaults = try makeDefaults()
            if let stored { defaults.set(stored, forKey: "quickAccessClipsPerRow") }

            XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, size, "\(String(describing: stored))")
            // The old key stays where it is; reading it changes nothing.
            XCTAssertEqual(defaults.object(forKey: "quickAccessClipsPerRow") as? Int, stored)
            XCTAssertNil(defaults.object(forKey: "quickAccess.cardSize"))
        }

        // A stored card size wins over the old key, and is taken as it is: one that is not a card size reads as
        // the default instead of looking at the old key.
        let defaults = try makeDefaults()
        defaults.set(7, forKey: "quickAccessClipsPerRow")
        defaults.set("small", forKey: "quickAccess.cardSize")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .small)
        defaults.set("huge", forKey: "quickAccess.cardSize")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .medium)
    }

    func testSettingsOffersThreeCardSizes() throws {
        // The radio group lists the sizes in this order, by these names; Medium is the one chosen to begin with.
        XCTAssertEqual(CardSize.allCases.map(\.title), ["Small", "Medium", "Large"])
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)
        XCTAssertEqual(preferences.cardSize, .medium)

        // Choosing Large stores it as "large", and the next launch reads it back.
        preferences.cardSize = .large

        XCTAssertEqual(defaults.object(forKey: "quickAccess.cardSize") as? String, "large")
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .large)
    }

    func testAStoredCardSizeThatIsNotTextReadsAsMedium() throws {
        // A number, a flag, data or a list under the card size key is not a card size. It reads as the default, and
        // the old clips-in-a-row key is not consulted in its place, even where it would give another size.
        let stored: [Any] = [11, true, 2.5, Data("large".utf8), ["large"]]
        for value in stored {
            let defaults = try makeDefaults()
            defaults.set(7, forKey: "quickAccessClipsPerRow")
            defaults.set(value, forKey: "quickAccess.cardSize")

            XCTAssertEqual(QuickAccessPreferences(defaults: defaults).cardSize, .medium, "\(value)")
        }
    }

    func testTheCardSizeChoiceReadsAsThreeRadioButtons() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // SwiftUI builds what VoiceOver reads only once an assistive client asks the app for anything; asking the
        // app's own accessibility element for its role is enough. A host that may not use accessibility at all
        // cannot run this test.
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        func radioButtons() -> [NSObject] {
            accessibilityElements(in: hosting).first { role(of: $0) == .radioGroup }
                .map { accessibilityElements(in: $0).filter { role(of: $0) == .radioButton } } ?? []
        }
        func chosen() -> [Int?] {
            radioButtons().map { ($0.value(forKey: "accessibilityValue") as? NSNumber)?.intValue }
        }
        let built = waitUntil { radioButtons().count == 3 }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }

        XCTAssertEqual(radioButtons().map { label(of: $0) }, ["Small", "Medium", "Large"])
        XCTAssertEqual(chosen(), [0, 1, 0], "Medium is the one chosen")

        // The group follows the preference: once Large is chosen, Large reads as the chosen one.
        preferences.cardSize = .large
        XCTAssertTrue(waitUntil { chosen() == [0, 0, 1] }, "\(chosen())")
    }

    func testFrequentClipsShowUntilTurnedOff() throws {
        let defaults = try makeDefaults()
        // Absent means on, and reading it stores nothing.
        XCTAssertTrue(QuickAccessPreferences(defaults: defaults).showsFrequentClips)
        XCTAssertNil(defaults.object(forKey: "quickAccess.showsFrequentClips"))

        // Turned off, it is stored as a flag under its own key, and the next launch reads it back.
        let preferences = QuickAccessPreferences(defaults: defaults)
        preferences.showsFrequentClips = false

        XCTAssertEqual(defaults.object(forKey: "quickAccess.showsFrequentClips") as? Bool, false)
        XCTAssertFalse(QuickAccessPreferences(defaults: defaults).showsFrequentClips)
        // The other settings keep their own keys.
        XCTAssertNil(defaults.object(forKey: "quickAccessTrackpadTicks"))
    }

    func testTheFrequentSwitchReadsWithItsExplanation() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // As in the card size test: SwiftUI builds what VoiceOver reads once an assistive client asks the app for
        // anything, and a host that may not use accessibility at all cannot run this test.
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        let title = "Show frequent clips in the strip"
        let explanation = "Clips you've copied or pasted from Keeptide more than once, and used in the last 90 days, "
            + "appear to the left of the newest clip."
        // The switches, in the order the form shows them. A switch reads as a checkbox. Its name is its label, or where
        // it has none, as here, the text that titles it; the explanation is a text of its own.
        func switches() -> [NSObject] { accessibilityElements(in: hosting).filter { role(of: $0) == .checkBox } }
        func named(_ title: String) -> (NSObject) -> Bool {
            { self.name(of: $0)?.hasPrefix(title) == true }
        }
        func isOn() -> Int? {
            switches().first(where: named(title))
                .flatMap { ($0.value(forKey: "accessibilityValue") as? NSNumber)?.intValue }
        }
        let built = waitUntil { switches().contains(where: named(title)) }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        let described = accessibilityElements(in: hosting).map {
            "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
        }

        XCTAssertEqual(isOn(), 1, "On to begin with: \(described)")
        // Below the card sizes and their picture, above the trackpad's ticks.
        XCTAssertEqual(switches().map(named(title)), [false, true, false], "\(described)")
        XCTAssertEqual(switches().map(named("Tick on the trackpad")), [false, false, true], "\(described)")
        XCTAssertEqual(switches().map(named("Fade the ends of the strip")), [true, false, false])
        // The explanation is read too: here as a text of its own, and on a release that reads it with the switch, in
        // the switch's label or help.
        XCTAssertTrue(accessibilityElements(in: hosting).contains { element in
            ["accessibilityLabel", "accessibilityValue", "accessibilityHelp"].contains {
                (attribute(of: element, $0) as? String)?.contains(explanation) == true
            }
        }, "\(described)")

        // The switch follows the preference: once the frequent clips are turned off, it reads as off.
        preferences.showsFrequentClips = false
        XCTAssertTrue(waitUntil { isOn() == 0 }, "\(String(describing: isOn()))")
    }

    func testTheSelectedCardIsEnlargedByDefaultAndTheChoiceStaysInRange() throws {
        let defaults = try makeDefaults()
        // Absent means 1.06, the standard enlargement, and reading it stores nothing.
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).selectedCardScale, 1.06, accuracy: 0.0001)
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).stripStyle, .standard)
        XCTAssertNil(defaults.object(forKey: "quickAccess.selectedCardScale"))

        // Stored values are not trusted: a number is kept between 1.00 and 1.25 and to hundredths, and one that is not
        // finite reads as the default.
        let numbers: [(stored: Double, read: Double)] = [(1.2, 1.2), (1.234, 1.23), (2, 1.25), (0.5, 1.0),
                                                         (Double.nan, 1.06)]
        for (stored, read) in numbers {
            defaults.set(stored, forKey: "quickAccess.selectedCardScale")
            XCTAssertEqual(QuickAccessPreferences(defaults: defaults).selectedCardScale, read, accuracy: 0.0001,
                           "\(stored)")
        }
        // Nor is anything that is not a number: text, data, or a flag, which would otherwise read as 1.
        for stored in ["1.2", true, Data([1])] as [Any] {
            defaults.set(stored, forKey: "quickAccess.selectedCardScale")
            XCTAssertEqual(QuickAccessPreferences(defaults: defaults).selectedCardScale, 1.06, accuracy: 0.0001,
                           "\(stored)")
        }

        // A choice is stored kept to the range and to hundredths, and the strip takes what is stored, now and at the
        // next launch.
        let preferences = QuickAccessPreferences(defaults: defaults)
        for (chosen, stored) in [(1.3, 1.25), (0.9, 1.0), (1.204, 1.2)] as [(Double, Double)] {
            preferences.selectedCardScale = chosen
            XCTAssertEqual(defaults.object(forKey: "quickAccess.selectedCardScale") as? Double, stored, "\(chosen)")
            XCTAssertEqual(preferences.stripStyle, StripStyle(selectedScale: stored), "\(chosen)")
        }
        XCTAssertEqual(QuickAccessPreferences(defaults: defaults).stripStyle, StripStyle(selectedScale: 1.2))
        // The other settings keep their own keys.
        XCTAssertNil(defaults.object(forKey: "quickAccess.cardSize"))
    }

    func testTheEnlargementSliderReadsFromNoneToMore() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // As in the card size test: SwiftUI builds what VoiceOver reads once an assistive client asks the app for
        // anything, and a host that may not use accessibility at all cannot run this test.
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        let title = "Enlarge the selected card"
        func slider() -> NSObject? {
            accessibilityElements(in: hosting).first { role(of: $0) == .slider && name(of: $0) == title }
        }
        // What VoiceOver reads for the slider's value: its description where it has one, as SwiftUI may give it, and
        // otherwise the value itself.
        func spoken() -> String? {
            guard let slider = slider() else { return nil }
            if let description = attribute(of: slider, "accessibilityValueDescription") as? String,
               !description.isEmpty {
                return description
            }
            return attribute(of: slider, "accessibilityValue") as? String
        }
        let built = waitUntil { slider() != nil }
        if !built, status != .success {
            throw XCTSkip("Accessibility is not available to the test host (AXError \(status.rawValue))")
        }
        let described = accessibilityElements(in: hosting).map {
            "\(role(of: $0)?.rawValue ?? "?") \(name(of: $0) ?? "") \(attribute(of: $0, "accessibilityValue") ?? "")"
        }

        // The standard enlargement reads as how much larger the selected card is.
        XCTAssertEqual(spoken(), "6% larger", "\(described)")
        // The slider's ends are named in the form: None at the left, More at the right.
        let words = accessibilityElements(in: hosting).compactMap { element in
            name(of: element) ?? attribute(of: element, "accessibilityValue") as? String
        }
        XCTAssertTrue(words.contains("None"), "\(described)")
        XCTAssertTrue(words.contains("More"), "\(described)")
        // Below the card sizes and their picture, above every switch.
        let order = accessibilityElements(in: hosting).compactMap { element -> String? in
            if role(of: element) == .slider { return "slider" }
            if role(of: element) == .radioGroup { return "sizes" }
            if role(of: element) == .checkBox { return "switch" }
            return nil
        }
        XCTAssertEqual(Array(order.prefix(2)), ["sizes", "slider"], "\(described)")
        XCTAssertEqual(Set(order.dropFirst(2)), ["switch"], "\(described)")

        // The slider follows the preference: none at 1.00, and the most at 1.25. The percentage is rounded, not cut
        // short: 1.13 is held as a hair under it.
        preferences.selectedCardScale = 1
        XCTAssertTrue(waitUntil { spoken() == "None" }, "\(String(describing: spoken()))")
        preferences.selectedCardScale = 1.13
        XCTAssertTrue(waitUntil { spoken() == "13% larger" }, "\(String(describing: spoken()))")
        preferences.selectedCardScale = 1.25
        XCTAssertTrue(waitUntil { spoken() == "25% larger" }, "\(String(describing: spoken()))")
    }

    func testChangesPersistImmediately() throws {
        let defaults = try makeDefaults()
        let preferences = QuickAccessPreferences(defaults: defaults)

        preferences.cardSize = .small
        preferences.trackpadTicks = false

        // The stored names and types are what an update must keep reading.
        XCTAssertEqual(defaults.object(forKey: "quickAccess.cardSize") as? String, "small")
        XCTAssertEqual(defaults.object(forKey: "quickAccessTrackpadTicks") as? Bool, false)
        let reopened = QuickAccessPreferences(defaults: defaults)
        XCTAssertEqual(reopened.cardSize, .small)
        XCTAssertFalse(reopened.trackpadTicks)
    }

    func testSettingsWindowIsReusedAndRestoresTheAccessoryPolicy() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = try makeController(onPolicy: { policies.append($0) })
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        controller.show()

        XCTAssertTrue(controller.window === window)
        XCTAssertEqual(window.title, "Keeptide Settings")
        let shown = NSApplication.shared.windows.filter { $0.identifier == window.identifier && $0.isVisible }
        XCTAssertEqual(shown.count, 1)
        XCTAssertEqual(policies, [.regular])

        window.close()

        XCTAssertEqual(policies, [.regular, .accessory])
    }

    func testSettingsWindowCanBeOpenedAgainAfterItIsClosed() throws {
        var policies: [NSApplication.ActivationPolicy] = []
        let controller = try makeController(onPolicy: { policies.append($0) })
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        window.close()
        controller.show()

        XCTAssertTrue(controller.window === window)
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(policies, [.regular, .accessory, .regular])
    }

    func testSettingsWindowRebindsLifecycleModelAfterStoreInitializationAndClose() throws {
        let controller = try makeController()
        weak var releasedModel: LifecycleSettingsModel?
        do {
            let defaults = try makeDefaults()
            let model = LifecycleSettingsModel(preferences: LifecyclePreferences(defaults: defaults))
            releasedModel = model
            controller.updateLifecycle(model)
            controller.updateLifecycle(model)
            XCTAssertNotNil(releasedModel)
        }
        XCTAssertNotNil(releasedModel, "The hosted Settings view owns the active store-scoped model")

        controller.updateLifecycle(nil)

        XCTAssertNil(releasedModel, "Closing the store must release its lifecycle model")
    }

    func testSettingsWindowIs600PointsWideAndFitsVisibleScreen() throws {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        settleLayout()

        let content = window.contentRect(forFrameRect: window.frame)
        let form = try XCTUnwrap(window.contentView).fittingSize
        XCTAssertEqual(content.width, 600)
        // A form that took no height of its own would leave a bare title bar.
        XCTAssertGreaterThan(form.height, 150)
        // Pages scroll: their intrinsic form height may exceed the screen-bounded viewport.
        let screen = try XCTUnwrap(window.screen)
        XCTAssertGreaterThanOrEqual(content.height, 420)
        XCTAssertLessThanOrEqual(content.height, screen.visibleFrame.height * 0.85 + 1)
        XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame))
        XCTAssertTrue(window.styleMask.contains(.resizable))
    }

    func testSettingsWindowOpensWithoutFocusingAControl() throws {
        let controller = try makeController()
        let window = try XCTUnwrap(controller.window)
        defer { window.close() }

        controller.show()
        settleLayout()

        // SwiftUI makes its hosting view the initial first responder, which hands the first
        // control the focus under full keyboard access.
        XCTAssertNil(window.initialFirstResponder)
        XCTAssertTrue(window.firstResponder === window)
    }

    func testEnvironmentCreatesTheSettingsWindowOnFirstUseAndReusesIt() throws {
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        var created = 0
        let environment = AppEnvironment(quickAccessPreferences: preferences, makeSettings: {
            created += 1
            return SettingsWindowController(preferences: preferences, setActivationPolicy: { _ in })
        })
        XCTAssertEqual(created, 0)

        XCTAssertTrue(environment.settingsWindowController === environment.settingsWindowController)

        XCTAssertEqual(created, 1)
    }

    func testDockClickWhileSettingsIsOpenLeavesTheLibraryClosed() throws {
        var libraries = 0
        let preferences = QuickAccessPreferences(defaults: try makeDefaults())
        let environment = AppEnvironment(quickAccessPreferences: preferences, makeLibrary: {
            libraries += 1
            return LibraryWindowController(session: CaptureSession(), autosaveName: nil)
        })
        let delegate = AppDelegate()
        delegate.environment = environment

        // With a window on screen, such as Settings, Keeptide comes forward as it is; the Library is not made.
        XCTAssertTrue(delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        XCTAssertEqual(libraries, 0)
    }

    /// The real activation policy stays untouched: the controller reports it through `onPolicy`.
    private func makeController(onPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { _ in }) throws
        -> SettingsWindowController {
        SettingsWindowController(preferences: QuickAccessPreferences(defaults: try makeDefaults()),
                                 setActivationPolicy: onPolicy)
    }

    private func makeSettingsModel(directPaste: DirectPasteSettingsModel = DirectPasteSettingsModel(),
                                   quickAccess: QuickAccessPreferences? = nil,
                                   ai: AISettingsModel? = nil) -> SettingsModel {
        let defaults = UserDefaults(suiteName: "SettingsModelTests-\(UUID().uuidString)")!
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        return SettingsModel(
            quickAccess: quickAccess ?? QuickAccessPreferences(defaults: defaults),
            capture: CapturePreferences(defaults: defaults),
            lifecycle: nil,
            shortcut: GlobalShortcutCoordinator(preferences: GlobalShortcutPreferences(defaults: defaults)),
            launchAtLogin: SettingsLaunchAtLoginFake(),
            directPaste: directPaste,
            ai: ai
        )
    }

    private func makeShortcutCoordinator() -> GlobalShortcutCoordinator {
        let defaults = UserDefaults(suiteName: "SettingsShortcutTests-\(UUID().uuidString)")!
        defaults.set(QuickAccessShortcut.disabled.rawValue, forKey: GlobalShortcutPreferences.selectionKey)
        return GlobalShortcutCoordinator(preferences: GlobalShortcutPreferences(defaults: defaults))
    }

    private func settleLayout() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    }

    /// Runs the main run loop in short turns until `condition` holds or five seconds have passed, and says which.
    private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 5)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        return true
    }

    /// Every element below `element` that VoiceOver could reach, depth first. SwiftUI's elements do not declare the
    /// accessibility protocol to Swift, so their children are asked for by name.
    private func accessibilityElements(in element: NSObject) -> [NSObject] {
        let children = (element.value(forKey: "accessibilityChildren") as? [Any] ?? []).compactMap { $0 as? NSObject }
        return children.flatMap { [$0] + accessibilityElements(in: $0) }
    }

    private func role(of element: NSObject) -> NSAccessibility.Role? {
        (element.value(forKey: "accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
    }

    private func label(of element: NSObject) -> String? {
        element.value(forKey: "accessibilityLabel") as? String
    }

    /// What VoiceOver names an element by: its label, or where it has none, the text of the element that titles it.
    private func name(of element: NSObject) -> String? {
        if let label = label(of: element), !label.isEmpty { return label }
        guard let title = attribute(of: element, "accessibilityTitleUIElement") as? NSObject else { return nil }
        if let label = label(of: title), !label.isEmpty { return label }
        return attribute(of: title, "accessibilityValue") as? String
    }

    /// Settings on its AI page in a window of its own, and whether accessibility answers the test host.
    private func showAIPage(_ model: SettingsModel) -> (NSHostingView<SettingsView>, NSWindow, AXError) {
        model.selectedTab = .ai
        let hosting = NSHostingView(rootView: SettingsView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        var applicationRole: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(AXUIElementCreateApplication(getpid()),
                                                   kAXRoleAttribute as CFString, &applicationRole)
        return (hosting, window, status)
    }

    /// Whether an element reads `text` in its label, value or title, as SwiftUI puts a static text's words in its
    /// value and a control's in its label.
    private func reads(_ text: String) -> (NSObject) -> Bool {
        { element in
            ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains {
                (self.attribute(of: element, $0) as? String)?.contains(text) == true
            }
        }
    }

    /// Presses an accessibility element, as VoiceOver does. The press answers whether it was handled, which is not an
    /// object, so the answer is left unread.
    private func press(_ element: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: selector))
        _ = element.perform(selector)
    }

    /// An accessibility attribute asked for by its getter's name, or nil where the element has no such getter.
    private func attribute(of element: NSObject, _ getter: String) -> Any? {
        let selector = NSSelectorFromString(getter)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    /// Each test reads and writes its own suite, removed when the test ends.
    private func makeDefaults() throws -> UserDefaults {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}

/// A translator whose first list of languages waits until it is let go, and whose later lists answer at once.
private final class GatedTranslator: TranslationEngine, @unchecked Sendable {
    let tier = EngineTier.onThisMac
    private let lock = NSLock()
    private let first: [Locale.Language]
    private let later: [Locale.Language]
    private var calls = 0
    private var isLetGo = false
    private var waiting: CheckedContinuation<Void, Never>?

    init(first: [String], later: [String]) {
        self.first = first.map(Locale.Language.init(identifier:))
        self.later = later.map(Locale.Language.init(identifier:))
    }

    var isWaiting: Bool { lock.withLock { waiting != nil } }

    func open() {
        let waiting = lock.withLock {
            isLetGo = true
            defer { self.waiting = nil }
            return self.waiting
        }
        waiting?.resume()
    }

    func supportedLanguages() async -> [Locale.Language] {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        guard call == 1 else { return later }
        await withCheckedContinuation { continuation in
            let goesNow = lock.withLock {
                if isLetGo { return true }
                waiting = continuation
                return false
            }
            if goesNow { continuation.resume() }
        }
        return first
    }

    func status(of pair: TranslationPair) async -> TranslationPairStatus { .installed }

    func translate(_ text: @escaping @Sendable () async throws -> String, from source: Locale.Language?,
                   to target: Locale.Language) -> any GenerationSource {
        ControlledSource()
    }
}

@MainActor @Observable
private final class SettingsLaunchAtLoginFake: LaunchAtLoginControlling {
    var state: LaunchAtLoginState = .disabled
    var isBusy = false
    func refresh() {}
    func setEnabled(_ enabled: Bool) async { state = enabled ? .enabled : .disabled }
}
