import XCTest
@testable import Keeptide

/// The models a person can choose: each provider's list merged with what Keeptide's catalog knows of names, prices,
/// what each reads and how its requests are shaped, and which one is recommended for each task. The lists are
/// synthetic.
final class ModelCatalogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_355_200)  // 2026-11-11

    func testAPriceIsPerMillionTokensAndALongPromptCostsWhatItsTierSays() {
        let haiku = ModelPrice(input: 0.10, output: 0.50,
                               longPrompt: .init(above: 100_000, input: 0.50, output: 2.50))

        XCTAssertEqual(haiku.cost(input: 100_000, output: 0), 0.01, accuracy: 1e-12)
        XCTAssertEqual(haiku.cost(input: 100_000, output: 10_000), 0.015, accuracy: 1e-12)
        XCTAssertEqual(haiku.cost(input: 100_001, output: 1_000_000), 2.5500005, accuracy: 1e-12,
                       "A prompt over the tier's line costs the tier's price, its output too")
        XCTAssertEqual(ModelPrice(input: 2, output: 10).cost(input: 500, output: 250), 0.0035, accuracy: 1e-12)
    }

    func testClaudesModelsAreWhatTheListSaysWithTheCatalogsPricesAndShapedToThinkLittle() {
        let listed = [
            RemoteModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5", readsImages: true,
                        thinkingTypes: [.adaptive, .disabled], efforts: [.low, .medium, .high, .xhigh, .max],
                        lifecycle: .active),
            RemoteModel(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", maxOutputTokens: 128_000,
                        readsImages: true, thinkingTypes: [.adaptive, .betweenTools], efforts: [.medium, .low]),
            RemoteModel(id: "claude-opus-5-5", displayName: "Claude Opus 5.5", maxOutputTokens: 8_000,
                        thinkingTypes: [.adaptive], efforts: [.low, .max]),
            RemoteModel(id: "claude-new-model", efforts: [.medium]),
            RemoteModel(id: "claude-quiet"),
            RemoteModel(id: "claude-both", thinkingTypes: [.betweenTools, .disabled], efforts: [.low]),
            RemoteModel(id: "claude-deep", thinkingTypes: [.disabled], efforts: [.xhigh, .max]),
            RemoteModel(id: "claude-edge", thinkingTypes: [.disabled], efforts: [.high, .max]),
            RemoteModel(id: "claude-no-levels", thinkingTypes: [.disabled], efforts: []),
            RemoteModel(id: "claude-haiku-5-5-20260801"),
        ]

        let models = ModelCatalog.models(listed: listed, from: .anthropic, now: now)

        XCTAssertEqual(models, [
            CatalogModel(provider: .anthropic, id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
                         readsImages: true, lifecycle: .active, price: Self.haikuPrice,
                         recommendedFor: [.extractText, .translate], thinking: .disabled, effort: .low,
                         outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5",
                         readsImages: true, price: ModelPrice(input: 2, output: 10), thinking: .betweenTools,
                         effort: .low, outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-opus-5-5", displayName: "Claude Opus 5.5",
                         price: ModelPrice(input: 4, output: 20), effort: .low, outputLimit: 8_000),
            CatalogModel(provider: .anthropic, id: "claude-new-model", displayName: "claude-new-model",
                         effort: .medium, outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-quiet", displayName: "claude-quiet", outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-both", displayName: "claude-both", thinking: .disabled,
                         effort: .low, outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-deep", displayName: "claude-deep", effort: .xhigh,
                         outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-edge", displayName: "claude-edge", thinking: .disabled,
                         effort: .high, outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-no-levels", displayName: "claude-no-levels",
                         thinking: .disabled, outputLimit: 16_384),
            CatalogModel(provider: .anthropic, id: "claude-haiku-5-5-20260801",
                         displayName: "claude-haiku-5-5-20260801", price: Self.haikuPrice, outputLimit: 16_384),
        ], "Thinking off where the model takes it at the least effort, and nothing the model hasn't said it takes")
    }

    func testOpenAIsModelsAreWhatTheCatalogKnows() {
        let listed = [
            RemoteModel(id: "gpt-6-luna", created: Date(timeIntervalSince1970: 1_779_062_400)),
            RemoteModel(id: "gpt-6.1-sol"),
            RemoteModel(id: "gpt-6-luna-2026-05-18"),
            RemoteModel(id: "gpt-6-luna-mini"),
            RemoteModel(id: "gpt-unknown"),
        ]

        let models = ModelCatalog.models(listed: listed, from: .openAI, now: now)

        let luna = ModelPrice(input: 0.10, output: 0.50)
        XCTAssertEqual(models, [
            CatalogModel(provider: .openAI, id: "gpt-6-luna", displayName: "GPT-6 Luna", readsImages: true,
                         created: Date(timeIntervalSince1970: 1_779_062_400), price: luna,
                         recommendedFor: [.extractText, .translate], effort: .noReasoning, outputLimit: 16_384),
            CatalogModel(provider: .openAI, id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", readsImages: true,
                         price: ModelPrice(input: 2, output: 10), effort: .low, outputLimit: 16_384),
            CatalogModel(provider: .openAI, id: "gpt-6-luna-2026-05-18", displayName: "gpt-6-luna-2026-05-18",
                         readsImages: true, effort: .noReasoning, outputLimit: 16_384),
            CatalogModel(provider: .openAI, id: "gpt-6-luna-mini", displayName: "gpt-6-luna-mini", outputLimit: 16_384),
            CatalogModel(provider: .openAI, id: "gpt-unknown", displayName: "gpt-unknown", outputLimit: 16_384),
        ], "A dated snapshot is the model it dates, but OpenAI has priced snapshots apart; any other name is a "
            + "model of its own, unknown")
    }

    func testTheListsNameIsShownUnlessItIsEmpty() {
        let models = ModelCatalog.models(listed: [
            RemoteModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5 (Beta)"),
            RemoteModel(id: "claude-sonnet-5-5", displayName: ""),
            RemoteModel(id: "claude-new-model", displayName: " \n"),
        ], from: .anthropic, now: now)

        XCTAssertEqual(models.map(\.displayName), ["Claude Haiku 5.5 (Beta)", "Claude Sonnet 5.5", "claude-new-model"])
    }

    func testAModelGoneOrPastItsShutDownIsntListedAndOneOnItsWayOutIsntRecommended() {
        let listed = [
            RemoteModel(id: "claude-haiku-5-5", lifecycle: .deprecated, shutDown: now.addingTimeInterval(86_400)),
            RemoteModel(id: "claude-sonnet-4-5", lifecycle: .retired),
            RemoteModel(id: "claude-opus-4-1", shutDown: now),
        ]

        let models = ModelCatalog.models(listed: listed, from: .anthropic,
                                         addedByHand: ["claude-sonnet-4-5", "claude-opus-4-1"], now: now)

        XCTAssertEqual(models.map(\.id), ["claude-haiku-5-5"], "A model its provider says is gone isn't added back")
        XCTAssertEqual(models.first?.recommendedFor, [], "Deprecated models are closed to anyone new")
        XCTAssertEqual(models.first?.isLeaving, true)
        let openAI = ModelCatalog.models(listed: [
            RemoteModel(id: "gpt-6-luna", shutDown: now.addingTimeInterval(30 * 86_400)),
            RemoteModel(id: "gpt-6.2-luna"),
        ], from: .openAI, now: now)
        XCTAssertEqual(openAI.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["gpt-6.2-luna"],
                       "A model with its shut-down set is on its way out, as OpenAI says it")
        XCTAssertEqual(openAI.first?.isLeaving, true)
    }

    func testWhenTheRecommendedModelIsntListedTheNewestVersionOfItsSeriesIsSuggested() {
        let listed = [
            RemoteModel(id: "claude-haiku-4-5", lifecycle: .active),
            RemoteModel(id: "claude-haiku-5-6", created: Date(timeIntervalSince1970: 1_800_000_000)),
            RemoteModel(id: "claude-haiku-6-0-20261001", created: Date(timeIntervalSince1970: 1_799_000_000)),
            RemoteModel(id: "claude-haiku-6-0", created: Date(timeIntervalSince1970: 1_790_000_000)),
            RemoteModel(id: "claude-haiku-7-0", lifecycle: .deprecated),
            RemoteModel(id: "claude-sonnet-6-0"),
        ]

        let models = ModelCatalog.models(listed: listed, from: .anthropic, now: now)

        XCTAssertEqual(models.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["claude-haiku-6-0"],
                       "The newest version, the model itself before its snapshot, and none on its way out")
        XCTAssertEqual(models.first { $0.id == "claude-haiku-6-0" }?.suggestedFor, [.extractText, .translate])
        let older = ModelCatalog.models(listed: [RemoteModel(id: "claude-haiku-4-5"),
                                                 RemoteModel(id: "claude-sonnet-5-5")], from: .anthropic, now: now)
        XCTAssertEqual(older.filter { !$0.recommendedFor.isEmpty }, [],
                       "Never an older version, which can cost more, nor another series")
    }

    func testOnlyASeriesOwnModelStandsInForItAndNotAVariantOrAFineTune() {
        let listed = [
            RemoteModel(id: "gpt-6.2-luna", created: Date(timeIntervalSince1970: 1_790_000_000)),
            RemoteModel(id: "gpt-6.2-luna-pro", created: Date(timeIntervalSince1970: 1_790_000_001)),
            RemoteModel(id: "gpt-6.2-luna-realtime", created: Date(timeIntervalSince1970: 1_790_000_002)),
            RemoteModel(id: "gpt-6-luna-tts", created: Date(timeIntervalSince1970: 1_790_000_003)),
            RemoteModel(id: "chatgpt-6-luna-latest", created: Date(timeIntervalSince1970: 1_790_000_004)),
            RemoteModel(id: "ft:gpt-6-luna-2026-05-18:acme::a1b2", created: Date(timeIntervalSince1970: 1_790_000_005)),
            RemoteModel(id: "gpt-6.3-luna-realtime", created: Date(timeIntervalSince1970: 1_790_000_006)),
            RemoteModel(id: "gpt-20270101-luna", created: Date(timeIntervalSince1970: 1_790_000_007)),
            RemoteModel(id: "gpt-6.1-terra"),
        ]

        let models = ModelCatalog.models(listed: listed, from: .openAI, now: now)

        XCTAssertEqual(models.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["gpt-6.2-luna"])
        let claude = ModelCatalog.models(listed: [RemoteModel(id: "claude-haiku-5-6"),
                                                  RemoteModel(id: "claude-haiku-6-0-fast"),
                                                  RemoteModel(id: "claude-haiku-20270101")], from: .anthropic, now: now)
        XCTAssertEqual(claude.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["claude-haiku-5-6"],
                       "Neither a variant nor a date in place of a version")
    }

    func testADateWithoutAMinorVersionIsADateAndAnOldNameIsNoSeries() {
        let old = ModelCatalog.models(listed: [RemoteModel(id: "claude-haiku-5-20270101"),
                                               RemoteModel(id: "claude-3-5-haiku-20241022"),
                                               RemoteModel(id: "claude-mythos-preview")], from: .anthropic, now: now)
        XCTAssertEqual(old.filter { !$0.recommendedFor.isEmpty }, [], "Haiku 5, dated, is older than Haiku 5.5")
        let six = ModelCatalog.models(listed: [RemoteModel(id: "claude-haiku-6")], from: .anthropic, now: now)
        XCTAssertEqual(six.first?.suggestedFor, [.extractText, .translate], "A missing minor version is .0")
    }

    func testOfTheSameVersionTheOneMadeLastIsChosen() {
        let luna = ModelCatalog.models(listed: [
            RemoteModel(id: "gpt-6-luna-2026-05-18", created: Date(timeIntervalSince1970: 1_779_062_400)),
            RemoteModel(id: "gpt-6-luna-2026-09-01", created: Date(timeIntervalSince1970: 1_788_220_800)),
            RemoteModel(id: "gpt-6-luna-2026-07-01", created: Date(timeIntervalSince1970: 1_782_864_000)),
        ], from: .openAI, now: now)
        XCTAssertEqual(luna.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["gpt-6-luna-2026-09-01"])
        let haiku = ModelCatalog.models(listed: [
            RemoteModel(id: "claude-haiku-6-0-20270101", created: Date(timeIntervalSince1970: 1_798_761_600)),
            RemoteModel(id: "claude-haiku-6-0-20270301", created: Date(timeIntervalSince1970: 1_803_859_200)),
            RemoteModel(id: "claude-haiku-6-0-20270201", created: Date(timeIntervalSince1970: 1_801_440_000)),
        ], from: .anthropic, now: now)
        XCTAssertEqual(haiku.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["claude-haiku-6-0-20270301"])
    }

    func testASnapshotOfTheRecommendedModelIsTheRecommendedModel() {
        let models = ModelCatalog.models(listed: [RemoteModel(id: "gpt-6-luna-2026-05-18"),
                                                  RemoteModel(id: "gpt-6.2-luna")], from: .openAI, now: now)

        XCTAssertEqual(models.filter { !$0.recommendedFor.isEmpty }.map(\.id), ["gpt-6-luna-2026-05-18"])
        XCTAssertEqual(models.first?.suggestedFor, [])
    }

    func testTextInAnImageIsRecommendedOnlyToAModelThatReadsImages() {
        let models = ModelCatalog.models(listed: [
            RemoteModel(id: "claude-haiku-5-5", readsImages: false),
            RemoteModel(id: "claude-haiku-5-6", readsImages: true),
        ], from: .anthropic, now: now)

        XCTAssertEqual(models.map(\.recommendedFor), [[.translate], [.extractText]])
        XCTAssertEqual(models.map(\.suggestedFor), [[], [.extractText]])
    }

    func testAModelAddedByHandIsKeptAsSuchWithWhatTheCatalogKnowsAndNeverRecommended() {
        let models = ModelCatalog.models(listed: [RemoteModel(id: "gpt-6-luna")], from: .openAI,
                                         addedByHand: [" gpt-6-luna\n", "gpt-6.1-terra", "gpt-lab-1", "gpt-lab-1",
                                                       "  ", ""], now: now)

        XCTAssertEqual(models.map(\.id), ["gpt-6-luna", "gpt-6.1-terra", "gpt-lab-1"])
        guard models.count == 3 else { return }
        XCTAssertEqual(models.map(\.addedByHand), [false, true, true], "A listed model isn't one added by hand")
        XCTAssertEqual(models[1].price, ModelPrice(input: 1, output: 5))
        XCTAssertEqual(models[1].effort, .noReasoning)
        XCTAssertNil(models[2].readsImages)
        let byHand = ModelCatalog.models(listed: [RemoteModel(id: "gpt-6.1-terra")], from: .openAI,
                                         addedByHand: ["gpt-6.2-luna"], now: now)
        XCTAssertEqual(byHand.filter { !$0.recommendedFor.isEmpty }, [])
    }

    func testTheRulesHoldForAnyCatalog() {
        let catalog = [CatalogEntry(provider: .openAI, id: "gpt-7-nova", displayName: "GPT-7 Nova",
                                    recommended: [.translate], readsImages: false, efforts: [.low, .high],
                                    maxOutputTokens: 4_096, price: ModelPrice(input: 1, output: 2))]

        let models = ModelCatalog.models(listed: [RemoteModel(id: "gpt-7.1-nova"), RemoteModel(id: "gpt-6-luna"),
                                                  RemoteModel(id: "gpt-7-nova", readsImages: true, efforts: [.high])],
                                         from: .openAI, now: now, catalog: catalog)

        XCTAssertEqual(models.map(\.recommendedFor), [[], [], [.translate]])
        XCTAssertNil(models[1].price, "Only the catalog given knows a price")
        XCTAssertEqual(models[2].readsImages, true, "What the list says is what counts")
        XCTAssertEqual(models[2].effort, .high)
        XCTAssertEqual(models[2].outputLimit, 4_096)
        let lacking = ModelCatalog.models(listed: [RemoteModel(id: "gpt-7.1-nova")], from: .openAI, now: now,
                                          catalog: catalog)
        XCTAssertEqual(lacking.first?.suggestedFor, [.translate])
    }

    func testEveryEntryIsOneItsProviderTakesAndEachTaskHasOneRecommendation() throws {
        let claudeEfforts: Set<ModelRequest.Effort> = [.low, .medium, .high, .xhigh, .max]
        let openAIEfforts: Set<ModelRequest.Effort> = [.noReasoning, .low, .medium, .high, .xhigh, .max]
        for entry in ModelCatalog.entries {
            XCTAssertFalse(entry.displayName.isEmpty, entry.id)
            XCTAssertTrue(entry.price.map { $0.input > 0 && $0.output > 0 } ?? true, entry.id)
            switch entry.provider {
            case .anthropic:
                XCTAssertTrue((entry.efforts ?? []).isSubset(of: claudeEfforts), "Claude refuses \(entry.id)'s efforts")
            case .openAI:
                XCTAssertTrue(entry.efforts?.isSubset(of: openAIEfforts) ?? false,
                              "OpenAI's list doesn't say, so the catalog must, as OpenAI takes them: \(entry.id)")
                XCTAssertNotNil(entry.readsImages, entry.id)
            }
        }
        XCTAssertEqual(Set(ModelCatalog.entries.map { "\($0.provider)/\($0.id)" }).count, ModelCatalog.entries.count)
        for provider in [ProviderPreset.ID.anthropic, .openAI] {
            for task in [DerivedTextOperation.extractText, .translate] {
                let recommended = ModelCatalog.entries.filter {
                    $0.provider == provider && $0.recommended.contains(task)
                }
                XCTAssertEqual(recommended.count, 1, "\(provider) \(task)")
                XCTAssertTrue(recommended.allSatisfy { task != .extractText || $0.provider == .anthropic
                    || $0.readsImages == true }, "\(provider) \(task)")
            }
        }
        for entry in ModelCatalog.entries where !entry.recommended.isEmpty {
            XCTAssertEqual(ModelCatalog.lineage(of: entry.id, provider: entry.provider)?.dated, false,
                           "A newer version can stand in for \(entry.id) only if its own name is a series'")
        }
        let calendar = Calendar(identifier: .gregorian)
        XCTAssertTrue(ModelCatalog.priceDate.isValidDate(in: calendar))
        XCTAssertLessThanOrEqual(try XCTUnwrap(calendar.date(from: ModelCatalog.priceDate)), now)
    }

    private static let haikuPrice = ModelPrice(input: 0.10, output: 0.50,
                                               longPrompt: .init(above: 100_000, input: 0.50, output: 2.50))
}
