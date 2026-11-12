import Observation
import XCTest
@testable import Keeptide

/// What a person chose for cloud models: the engine each task uses, the model each provider uses for each task, when
/// they're asked before a clip is sent and what they answered, and what this month's requests came to. Preferences are
/// a suite of each test's own, and months are counted in Shanghai's time zone unless a test says otherwise.
@MainActor
final class CloudModelPreferencesTests: XCTestCase {
    private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = shanghai
        return calendar
    }

    private func preferences() throws -> UserDefaults {
        let suiteName = "CloudModelPreferencesTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func choices(_ defaults: UserDefaults) -> CloudModelPreferences {
        CloudModelPreferences(defaults: defaults, timeZone: shanghai)
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour,
                                                         minute: minute)))
    }

    private func assertUsage(_ usage: CloudUsage, requests: Int, dollars: Double, unpriced: Int,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(usage.requests, requests, "requests \(message)", file: file, line: line)
        XCTAssertEqual(usage.dollars, dollars, accuracy: 1e-12, "dollars \(message)", file: file, line: line)
        XCTAssertEqual(usage.unpriced, unpriced, "unpriced \(message)", file: file, line: line)
    }

    func testEachTaskUsesThisMacUntilAnotherEngineIsChosen() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        XCTAssertEqual(choices.engine(for: .translate), .onThisMac)
        XCTAssertEqual(choices.engine(for: .extractText), .onThisMac)

        choices.setEngine(.cloud(.anthropic), for: .translate)
        choices.setEngine(.cloud(.openAI), for: .extractText)

        XCTAssertEqual(defaults.object(forKey: "translation.engine") as? String, "anthropic")
        XCTAssertEqual(defaults.object(forKey: "textRecognition.engine") as? String, "openai")
        let reopened = self.choices(defaults)
        XCTAssertEqual(reopened.engine(for: .translate), .cloud(.anthropic))
        XCTAssertEqual(reopened.engine(for: .extractText), .cloud(.openAI))
        choices.setEngine(.onThisMac, for: .translate)
        XCTAssertEqual(defaults.object(forKey: "translation.engine") as? String, "onThisMac")
        XCTAssertEqual(self.choices(defaults).engine(for: .translate), .onThisMac)
    }

    func testAnEngineThisVersionDoesntKnowIsThisMacAndIsLeftAsItIs() throws {
        let defaults = try preferences()
        defaults.set("mistral", forKey: "translation.engine")
        defaults.set(5, forKey: "textRecognition.engine")

        let choices = choices(defaults)

        XCTAssertEqual(choices.engine(for: .translate), .onThisMac)
        XCTAssertEqual(choices.engine(for: .extractText), .onThisMac)
        XCTAssertEqual(defaults.object(forKey: "translation.engine") as? String, "mistral",
                       "Left for the version that knows it")
    }

    func testEachProviderHasAModelOfItsOwnForEachTask() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        XCTAssertNil(choices.model(for: .translate, from: .anthropic))

        choices.setModel("claude-haiku-5-5", for: .translate, from: .anthropic)
        choices.setModel(" claude-sonnet-5-5\n", for: .extractText, from: .anthropic)
        choices.setModel("gpt-6-luna", for: .translate, from: .openAI)

        XCTAssertEqual(choices.model(for: .translate, from: .anthropic), "claude-haiku-5-5")
        XCTAssertEqual(choices.model(for: .extractText, from: .anthropic), "claude-sonnet-5-5")
        XCTAssertEqual(choices.model(for: .translate, from: .openAI), "gpt-6-luna")
        XCTAssertNil(choices.model(for: .extractText, from: .openAI))
        XCTAssertEqual(defaults.object(forKey: "cloudModels.anthropic.translationModel") as? String, "claude-haiku-5-5")
        XCTAssertEqual(defaults.object(forKey: "cloudModels.anthropic.textRecognitionModel") as? String,
                       "claude-sonnet-5-5")
        XCTAssertEqual(defaults.object(forKey: "cloudModels.openai.translationModel") as? String, "gpt-6-luna")
        let reopened = self.choices(defaults)
        XCTAssertEqual(reopened.model(for: .extractText, from: .anthropic), "claude-sonnet-5-5")
        XCTAssertEqual(reopened.model(for: .translate, from: .openAI), "gpt-6-luna")
        choices.setModel(" \n", for: .translate, from: .anthropic)
        choices.setModel(nil, for: .translate, from: .openAI)
        XCTAssertNil(choices.model(for: .translate, from: .anthropic), "Nothing is no model")
        XCTAssertNil(defaults.object(forKey: "cloudModels.anthropic.translationModel"))
        XCTAssertNil(defaults.object(forKey: "cloudModels.openai.translationModel"))
        defaults.set(" ", forKey: "cloudModels.openai.textRecognitionModel")
        XCTAssertNil(self.choices(defaults).model(for: .extractText, from: .openAI))
    }

    func testAPersonIsAskedTheFirstTimeEachKindOfContentGoesToEachProvider() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        XCTAssertEqual(choices.askBeforeSending, .firstTimeForEachProvider)
        XCTAssertTrue(choices.needsAsking(before: .text, to: .anthropic))

        choices.remember(.text, to: .anthropic)

        XCTAssertFalse(choices.needsAsking(before: .text, to: .anthropic))
        XCTAssertTrue(choices.needsAsking(before: .image, to: .anthropic))
        XCTAssertTrue(choices.needsAsking(before: .text, to: .openAI))
        XCTAssertEqual(defaults.object(forKey: "cloudModels.sendingAnswers") as? [String], ["anthropic.text"])
        choices.remember(.text, to: .anthropic)
        XCTAssertEqual(defaults.object(forKey: "cloudModels.sendingAnswers") as? [String], ["anthropic.text"])
        XCTAssertFalse(self.choices(defaults).needsAsking(before: .text, to: .anthropic))
    }

    func testEveryTimeAsksEveryTimeAndResettingForgetsTheAnswers() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        choices.remember(.text, to: .anthropic)

        choices.askBeforeSending = .everyTime

        XCTAssertTrue(choices.needsAsking(before: .text, to: .anthropic))
        XCTAssertEqual(defaults.object(forKey: "cloudModels.askBeforeSending") as? String, "everyTime")
        XCTAssertEqual(self.choices(defaults).askBeforeSending, .everyTime)
        choices.askBeforeSending = .firstTimeForEachProvider
        XCTAssertEqual(defaults.object(forKey: "cloudModels.askBeforeSending") as? String, "firstTime")
        XCTAssertFalse(choices.needsAsking(before: .text, to: .anthropic), "The answers stay while it asks every time")
        choices.resetAnswers()
        XCTAssertTrue(choices.needsAsking(before: .text, to: .anthropic))
        XCTAssertTrue(self.choices(defaults).needsAsking(before: .text, to: .anthropic))
        choices.askBeforeSending = .everyTime
        choices.remember(.image, to: .openAI)
        choices.askBeforeSending = .firstTimeForEachProvider
        XCTAssertTrue(choices.needsAsking(before: .image, to: .openAI),
                      "An answer given while asking every time isn't kept")
        defaults.set("sometimes", forKey: "cloudModels.askBeforeSending")
        XCTAssertEqual(self.choices(defaults).askBeforeSending, .everyTime,
                       "A way of asking this version doesn't know asks every time")
        XCTAssertEqual(defaults.object(forKey: "cloudModels.askBeforeSending") as? String, "sometimes",
                       "And is left as it is")
    }

    func testAnswersThisVersionDoesntKnowAreKeptUntilReset() throws {
        let defaults = try preferences()
        defaults.set(["mistral.text", "anthropic.audio", "anthropic.image"], forKey: "cloudModels.sendingAnswers")
        let choices = choices(defaults)

        choices.remember(.text, to: .openAI)

        XCTAssertFalse(choices.needsAsking(before: .image, to: .anthropic))
        XCTAssertTrue(choices.needsAsking(before: .text, to: .anthropic))
        XCTAssertEqual(defaults.object(forKey: "cloudModels.sendingAnswers") as? [String],
                       ["mistral.text", "anthropic.audio", "anthropic.image", "openai.text"])
        choices.resetAnswers()
        XCTAssertNil(defaults.object(forKey: "cloudModels.sendingAnswers"))
    }

    func testUsageAddsUpWithinAMonthAndStartsAtNothingInTheNext() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        let november = try date(11, 12)
        let endOfNovember = try date(11, 30, 23, 59)
        let december = try date(12, 1, 0, 0)
        assertUsage(choices.usage(asOf: november), requests: 0, dollars: 0, unpriced: 0)

        choices.record(cost: 0.001, at: november)
        choices.record(cost: nil, at: november.addingTimeInterval(3_600))
        choices.record(cost: 0.0125, at: endOfNovember)

        assertUsage(choices.usage(asOf: endOfNovember), requests: 3, dollars: 0.0135, unpriced: 1)
        assertUsage(self.choices(defaults).usage(asOf: november), requests: 3, dollars: 0.0135, unpriced: 1)
        assertUsage(choices.usage(asOf: december), requests: 0, dollars: 0, unpriced: 0)
        let novemberNextYear = try XCTUnwrap(calendar.date(byAdding: .year, value: 1, to: november))
        assertUsage(choices.usage(asOf: novemberNextYear), requests: 0, dollars: 0, unpriced: 0, "Nor a year later")
        choices.record(cost: 0.002, at: december)
        assertUsage(choices.usage(asOf: december), requests: 1, dollars: 0.002, unpriced: 0)
        assertUsage(choices.usage(asOf: endOfNovember), requests: 0, dollars: 0, unpriced: 0)
        choices.record(cost: 0.003, at: november)
        assertUsage(choices.usage(asOf: november), requests: 1, dollars: 0.003, unpriced: 0,
                    "A clock set back starts its month at nothing too")
    }

    func testACostThatIsntOneCountsAsUnpricedAndResettingStartsAtNothing() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        let november = try date(11, 12)

        for cost in [-0.01, .nan, .infinity] { choices.record(cost: cost, at: november) }

        assertUsage(choices.usage(asOf: november), requests: 3, dollars: 0, unpriced: 3)
        choices.resetUsage()
        assertUsage(choices.usage(asOf: november), requests: 0, dollars: 0, unpriced: 0)
        assertUsage(self.choices(defaults).usage(asOf: november), requests: 0, dollars: 0, unpriced: 0)
        choices.record(cost: 0.01, at: november)
        assertUsage(choices.usage(asOf: november), requests: 1, dollars: 0.01, unpriced: 0)
    }

    func testForgettingAProviderLeavesWhatIsAnothersAndWhatWasUsed() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        let november = try date(11, 12)
        choices.setEngine(.cloud(.anthropic), for: .translate)
        choices.setEngine(.cloud(.openAI), for: .extractText)
        choices.setModel("claude-haiku-5-5", for: .translate, from: .anthropic)
        choices.setModel("claude-haiku-5-5", for: .extractText, from: .anthropic)
        choices.setModel("gpt-6-luna", for: .translate, from: .openAI)
        choices.remember(.text, to: .anthropic)
        choices.remember(.image, to: .anthropic)
        choices.remember(.text, to: .openAI)
        choices.record(cost: 0.01, at: november)
        let answers = defaults.object(forKey: "cloudModels.sendingAnswers") as? [String] ?? []
        defaults.set(answers + ["anthropic.audio", "mistral.text"], forKey: "cloudModels.sendingAnswers")

        choices.forget(.anthropic)

        XCTAssertEqual(defaults.object(forKey: "cloudModels.sendingAnswers") as? [String],
                       ["openai.text", "mistral.text"], "Answers about it that a later version gave are forgotten too")
        XCTAssertNil(defaults.object(forKey: "translation.engine"), "So that a later default reaches it")
        for choices in [choices, self.choices(defaults)] {
            XCTAssertEqual(choices.engine(for: .translate), .onThisMac)
            XCTAssertEqual(choices.engine(for: .extractText), .cloud(.openAI))
            XCTAssertNil(choices.model(for: .translate, from: .anthropic))
            XCTAssertNil(choices.model(for: .extractText, from: .anthropic))
            XCTAssertEqual(choices.model(for: .translate, from: .openAI), "gpt-6-luna")
            XCTAssertTrue(choices.needsAsking(before: .text, to: .anthropic))
            XCTAssertTrue(choices.needsAsking(before: .image, to: .anthropic))
            XCTAssertFalse(choices.needsAsking(before: .text, to: .openAI))
            assertUsage(choices.usage(asOf: november), requests: 1, dollars: 0.01, unpriced: 0)
        }
    }

    func testForgettingAProviderLeavesWhatItWasntChosenFor() throws {
        let defaults = try preferences()
        defaults.set("mistral", forKey: "translation.engine")
        let choices = choices(defaults)

        choices.forget(.anthropic)
        choices.forget(.openAI)

        XCTAssertEqual(defaults.object(forKey: "translation.engine") as? String, "mistral")
        XCTAssertNil(defaults.object(forKey: "textRecognition.engine"))
        XCTAssertNil(defaults.object(forKey: "cloudModels.openai.translationModel"))
        XCTAssertNil(defaults.object(forKey: "cloudModels.sendingAnswers"))
    }

    func testAnotherInstanceDoesntBringBackAnswersForgotten() throws {
        let defaults = try preferences()
        let first = choices(defaults)
        first.remember(.text, to: .anthropic)
        let second = choices(defaults)

        first.forget(.anthropic)
        second.remember(.image, to: .openAI)

        XCTAssertEqual(defaults.object(forKey: "cloudModels.sendingAnswers") as? [String], ["openai.image"])
        first.resetAnswers()
        second.remember(.text, to: .openAI)
        XCTAssertEqual(defaults.object(forKey: "cloudModels.sendingAnswers") as? [String], ["openai.text"])
    }

    func testOnlyWhatCouldBeAModelsIdentifierIsKeptAsOne() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        XCTAssertTrue(choices.setModel("claude-haiku-5-5", for: .translate, from: .anthropic))

        for notAModel in ["sk-ant-api03-synthetic-key-for-tests-only-AbCd", "sk-proj-synthetic-key", "claude haiku",
                          "claude-\u{200B}haiku", "claude-haikü"] {
            XCTAssertFalse(choices.setModel(notAModel, for: .translate, from: .anthropic), notAModel)
        }

        XCTAssertEqual(choices.model(for: .translate, from: .anthropic), "claude-haiku-5-5", "The model chosen stays")
        XCTAssertEqual(defaults.object(forKey: "cloudModels.anthropic.translationModel") as? String, "claude-haiku-5-5")
        for line in ["OPENAI_API_KEY=sk-proj-synthetic-key", "ANTHROPIC_API_KEY=sk-ant-api03-synthetic",
                     "OPENAI_API_KEY=sk-AbCdEf0123456789", "'sk-legacy-synthetic'", "desk-key=sk-legacy-synthetic"] {
            XCTAssertFalse(choices.setModel(line, for: .translate, from: .openAI), "A key after its name: \(line)")
        }
        XCTAssertTrue(choices.setModel("ft:gpt-4o-mini:acme:custom:abc123", for: .translate, from: .openAI),
                      "A fine-tuned model's identifier")
        for word in ["ft:gpt-4o-mini:acme:task-runner:abc123", "ft:gpt-4o-mini:acme:task-proj-x:abc123",
                     "ft:gpt-4o-mini:acme:risk-admin-v2:abc", "ft:gpt-4o-mini:acme:v2sk-test:abc"] {
            XCTAssertTrue(choices.setModel(word, for: .extractText, from: .openAI), "Within a word: \(word)")
        }
        XCTAssertTrue(choices.setModel("\u{FEFF}claude-sonnet-5-5\u{200B}", for: .extractText, from: .anthropic),
                      "Without the invisible characters around it, as a key is pasted")
        XCTAssertEqual(choices.model(for: .extractText, from: .anthropic), "claude-sonnet-5-5")
        XCTAssertTrue(choices.setModel("\u{200B}", for: .extractText, from: .anthropic), "Nothing visible is nothing")
        XCTAssertNil(choices.model(for: .extractText, from: .anthropic))
        XCTAssertTrue(choices.setModel("gpt-6-luna", for: .extractText, from: .openAI))
        XCTAssertTrue(choices.setModel("\u{FEFF}", for: .extractText, from: .openAI))
        XCTAssertNil(choices.model(for: .extractText, from: .openAI))
        XCTAssertTrue(choices.setModel(nil, for: .translate, from: .openAI))
        defaults.set("sk-ant-api03-synthetic", forKey: "cloudModels.openai.textRecognitionModel")
        XCTAssertNil(self.choices(defaults).model(for: .extractText, from: .openAI), "Nor is one read that couldn't be")
    }

    nonisolated func testAModelsIdentifierIsCheckedAwayFromTheMainActorToo() {
        XCTAssertEqual(CloudModelPreferences.modelIdentifier(" gpt-6-luna\n"), "gpt-6-luna")
        XCTAssertNil(CloudModelPreferences.modelIdentifier("sk-proj-synthetic-key"))
    }

    func testMonthsAreCountedOnTheGregorianCalendarInTheTimeZoneGiven() throws {
        let defaults = try preferences()
        let instant = try date(12, 1, 4)
        let choices = choices(defaults)

        choices.record(cost: 0.01, at: instant)

        assertUsage(choices.usage(asOf: try date(12, 15)), requests: 1, dollars: 0.01, unpriced: 0)
        let elsewhere = CloudModelPreferences(defaults: defaults, timeZone: TimeZone(identifier: "UTC")!)
        assertUsage(elsewhere.usage(asOf: instant), requests: 0, dollars: 0, unpriced: 0,
                    "Still November in UTC, so not the month counted")
    }

    func testUsageThePreferencesHoldIsCountedOnOnlyIfItCouldBeACount() throws {
        let defaults = try preferences()
        let november = try date(11, 12)
        for held in [#"{"year":2026,"month":11,"requests":-1,"dollars":0,"unpriced":0}"#,
                     #"{"year":2026,"month":11,"requests":2,"dollars":0,"unpriced":3}"#,
                     #"{"year":2026,"month":11,"requests":2,"dollars":-1,"unpriced":0}"#,
                     #"{"year":2026,"month":13,"requests":2,"dollars":0,"unpriced":0}"#,
                     "not a count"] {
            defaults.set(Data(held.utf8), forKey: "cloudModels.usage")
            let choices = choices(defaults)

            assertUsage(choices.usage(asOf: november), requests: 0, dollars: 0, unpriced: 0, held)
            choices.record(cost: 0.01, at: november)
            assertUsage(choices.usage(asOf: november), requests: 1, dollars: 0.01, unpriced: 0, held)
        }
        defaults.set(Data(#"{"year":2026,"month":11,"requests":\#(Int.max),"dollars":1.7e308,"unpriced":0}"#.utf8),
                     forKey: "cloudModels.usage")
        let full = choices(defaults)
        full.record(cost: 1.7e308, at: november)
        for choices in [full, self.choices(defaults)] {
            assertUsage(choices.usage(asOf: november), requests: Int.max, dollars: 1.7e308, unpriced: 1,
                        "A count as high as it goes stays there, and a sum that would be infinite isn't added")
        }
    }

    func testSettingsIsToldOfEachChangeItShows() throws {
        let defaults = try preferences()
        let choices = choices(defaults)
        let november = try date(11, 12)

        XCTAssertTrue(observes({ _ = choices.engine(for: .translate) }) {
            choices.setEngine(.cloud(.anthropic), for: .translate)
        })
        XCTAssertTrue(observes({ _ = choices.engine(for: .translate) }) { choices.forget(.anthropic) })
        XCTAssertTrue(observes({ _ = choices.model(for: .translate, from: .openAI) }) {
            choices.setModel("gpt-6-luna", for: .translate, from: .openAI)
        })
        XCTAssertTrue(observes({ _ = choices.needsAsking(before: .text, to: .anthropic) }) {
            choices.remember(.text, to: .anthropic)
        })
        XCTAssertTrue(observes({ _ = choices.needsAsking(before: .text, to: .anthropic) }) { choices.resetAnswers() })
        XCTAssertTrue(observes({ _ = choices.askBeforeSending }) { choices.askBeforeSending = .everyTime })
        XCTAssertTrue(observes({ _ = choices.usage(asOf: november) }) { choices.record(cost: 0.01, at: november) })
        XCTAssertTrue(observes({ _ = choices.usage(asOf: november) }) { choices.resetUsage() })
    }

    /// Whether reading with `read` is told of a change that `change` makes, as a view that read it would be.
    private func observes(_ read: () -> Void, _ change: () -> Void) -> Bool {
        let told = Flag()
        withObservationTracking(read, onChange: { told.raise() })
        change()
        return told.isRaised
    }
}

/// Whether something happened, from any thread.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isRaised: Bool { lock.withLock { raised } }

    func raise() {
        lock.withLock { raised = true }
    }
}
