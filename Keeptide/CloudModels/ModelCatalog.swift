import Foundation

/// What a model costs, in dollars per million tokens, as of the catalog's price date. An estimate: the providers'
/// bills are what count.
struct ModelPrice: Equatable, Sendable {
    /// A higher price for a prompt longer than `above` tokens, input and output alike.
    struct LongPrompt: Equatable, Sendable {
        var above: Int
        var input: Double
        var output: Double
    }

    var input: Double
    var output: Double
    var longPrompt: LongPrompt?

    /// What a request that sent `input` tokens and received `output` tokens costs, in dollars.
    func cost(input: Int, output: Int) -> Double {
        let (inputPrice, outputPrice) = if let longPrompt, input > longPrompt.above {
            (longPrompt.input, longPrompt.output)
        } else {
            (self.input, self.output)
        }
        return (Double(input) * inputPrice + Double(output) * outputPrice) / 1_000_000
    }
}

/// What Keeptide knows of a model before its provider says anything, as of the catalog's date: how people know it,
/// the tasks it is the one recommended for, what it reads and the efforts it takes where its provider's list doesn't
/// say, and what it costs.
struct CatalogEntry: Sendable {
    let provider: ProviderPreset.ID
    let id: String
    let displayName: String
    var recommended: Set<DerivedTextOperation> = []
    var readsImages: Bool?
    var efforts: Set<ModelRequest.Effort>?
    var maxOutputTokens: Int?
    var price: ModelPrice?

    /// Whether `model` is this entry's model: its identifier, or a snapshot of it that adds only a date.
    func names(_ model: String) -> Bool {
        guard model != id else { return true }
        guard model.hasPrefix(id + "-") else { return false }
        // "2026-05-18" or "20260518".
        let shape = String(model.dropFirst(id.count + 1).map { $0.isASCII && $0.isNumber ? "0" : $0 })
        return shape == "0000-00-00" || shape == "00000000"
    }
}

/// A model a person can choose: what its provider lists, with what the catalog knows of it, and how a request to it is
/// shaped.
struct CatalogModel: Equatable, Sendable {
    let provider: ProviderPreset.ID
    let id: String
    let displayName: String
    var readsImages: Bool?
    var lifecycle: RemoteModel.Lifecycle?
    var shutDown: Date?
    var created: Date?
    var price: ModelPrice?
    var recommendedFor: Set<DerivedTextOperation> = []
    /// The tasks it is recommended for in place of the catalog's own choice, which this key's list lacks, or has on
    /// its way out, or, for text in an image, has without reading images.
    var suggestedFor: Set<DerivedTextOperation> = []
    var addedByHand = false
    var thinking: ModelRequest.Thinking?
    var effort: ModelRequest.Effort?
    /// The most a request asks the model to write, which is no more than it can.
    let outputLimit: Int

    /// Whether its provider says it is on its way out: deprecated, or with a day set for it to shut down.
    var isLeaving: Bool { lifecycle == .deprecated || shutDown != nil }
}

/// Keeptide's catalog of the models it knows, and how a provider's list becomes the models a person can choose.
enum ModelCatalog {
    /// The day the catalog's prices were last checked against what the providers publish; the earlier day, where
    /// the two providers' were checked apart.
    static let priceDate = DateComponents(year: 2026, month: 11, day: 9)
    /// The most a request asks a model to write. Generations are billed for what they write, so a high limit costs
    /// nothing more and spares a cut-off answer.
    static let outputLimit = 16_384

    /// The efforts OpenAI's current models take. The catalog shapes a request by the least of them only.
    private static let openAIEfforts: Set<ModelRequest.Effort> = [.low, .medium, .high, .xhigh, .max]

    static let entries: [CatalogEntry] = [
        // Claude's capabilities come with its list; the catalog adds names, recommendations and prices.
        CatalogEntry(provider: .anthropic, id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
                     recommended: [.extractText, .translate],
                     price: ModelPrice(input: 0.10, output: 0.50,
                                       longPrompt: .init(above: 100_000, input: 0.50, output: 2.50))),
        claude("claude-sonnet-5-5", "Claude Sonnet 5.5", input: 2, output: 10),
        claude("claude-opus-5-5", "Claude Opus 5.5", input: 4, output: 20),
        claude("claude-fable-5-2", "Claude Fable 5.2", input: 8, output: 40),
        claude("claude-mythos-5-2", "Claude Mythos 5.2", input: 8, output: 40),
        claude("claude-fable-5-1", "Claude Fable 5.1", input: 10, output: 50),
        claude("claude-mythos-5-1", "Claude Mythos 5.1", input: 10, output: 50),
        claude("claude-fable-5", "Claude Fable 5", input: 10, output: 50),
        claude("claude-mythos-5", "Claude Mythos 5", input: 10, output: 50),
        claude("claude-opus-5", "Claude Opus 5", input: 5, output: 25),
        claude("claude-opus-4-8", "Claude Opus 4.8", input: 5, output: 25),
        claude("claude-sonnet-5", "Claude Sonnet 5", input: 2, output: 10),
        // OpenAI's list doesn't say what its models read or the efforts they take, so the catalog does.
        CatalogEntry(provider: .openAI, id: "gpt-6-luna", displayName: "GPT-6 Luna",
                     recommended: [.extractText, .translate], readsImages: true,
                     efforts: openAIEfforts.union([.noReasoning]), maxOutputTokens: 128_000,
                     price: ModelPrice(input: 0.10, output: 0.50)),
        CatalogEntry(provider: .openAI, id: "gpt-6.1-terra", displayName: "GPT-6.1 Terra", readsImages: true,
                     efforts: openAIEfforts.union([.noReasoning]), maxOutputTokens: 128_000,
                     price: ModelPrice(input: 1, output: 5)),
        CatalogEntry(provider: .openAI, id: "gpt-6.1-sol", displayName: "GPT-6.1 Sol", readsImages: true,
                     efforts: openAIEfforts, maxOutputTokens: 128_000, price: ModelPrice(input: 2, output: 10)),
        CatalogEntry(provider: .openAI, id: "gpt-6-astra", displayName: "GPT-6 Astra", readsImages: true,
                     efforts: openAIEfforts, maxOutputTokens: 128_000, price: ModelPrice(input: 10, output: 50)),
    ]

    /// The models a person can choose from `provider`: those its list has, as they are `now`, then those added by
    /// hand that it doesn't list at all. A model retired, or past its shut-down, isn't one.
    static func models(listed: [RemoteModel], from provider: ProviderPreset.ID, addedByHand manual: [String] = [],
                       now: Date, catalog: [CatalogEntry] = entries) -> [CatalogModel] {
        let serving = listed.filter { $0.lifecycle != .retired && ($0.shutDown.map { $0 > now } ?? true) }
        // A model its provider lists, even one it says is gone, isn't one added by hand.
        let ids = Set(listed.map(\.id))
        let known = catalog.filter { $0.provider == provider }
        var models = serving.map { model(from: $0, provider: provider, catalog: known, addedByHand: false) }
        var added: Set<String> = []
        for id in manual.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            where !id.isEmpty && !ids.contains(id) && added.insert(id).inserted {
            models.append(model(from: RemoteModel(id: id), provider: provider, catalog: known, addedByHand: true))
        }
        for entry in known {
            for task in entry.recommended { recommend(entry, for: task, in: &models) }
        }
        return models
    }

    private static func model(from listed: RemoteModel, provider: ProviderPreset.ID, catalog: [CatalogEntry],
                              addedByHand: Bool) -> CatalogModel {
        let entry = catalog.first { $0.names(listed.id) }
        let exact = entry?.id == listed.id
        let name = listed.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let efforts = listed.efforts ?? entry?.efforts
        let (thinking, effort) = shape(provider: provider, thinkingTypes: listed.thinkingTypes, efforts: efforts)
        return CatalogModel(
            provider: provider, id: listed.id,
            displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? (exact ? entry?.displayName : nil) ?? listed.id,
            readsImages: listed.readsImages ?? entry?.readsImages, lifecycle: listed.lifecycle,
            shutDown: listed.shutDown, created: listed.created,
            // Anthropic's snapshots are its models; OpenAI has priced a snapshot apart from the model it dates.
            price: exact || provider == .anthropic ? entry?.price : nil, addedByHand: addedByHand,
            thinking: thinking, effort: effort,
            outputLimit: min(listed.maxOutputTokens ?? entry?.maxOutputTokens ?? outputLimit, outputLimit))
    }

    /// How a request asks a model to think as little as it lets it, for text a person waits for. Claude turns thinking
    /// off where the model takes that, which it does at an effort no higher than high, and otherwise thinks between
    /// tools, which a request without tools never uses; both providers take the least effort the model offers. What a
    /// model hasn't said it takes isn't sent.
    private static func shape(provider: ProviderPreset.ID, thinkingTypes: Set<ModelRequest.Thinking>?,
                              efforts: Set<ModelRequest.Effort>?) -> (ModelRequest.Thinking?, ModelRequest.Effort?) {
        let least = efforts.flatMap { efforts in effortOrder.first { efforts.contains($0) } }
        switch provider {
        case .anthropic:
            let offAllowed = least.map { rank($0) <= rank(.high) } ?? true
            let thinking: ModelRequest.Thinking? = if !offAllowed {
                nil
            } else if thinkingTypes?.contains(.disabled) == true {
                .disabled
            } else if thinkingTypes?.contains(.betweenTools) == true {
                .betweenTools
            } else {
                nil
            }
            return (thinking, least)
        case .openAI:
            return (nil, least)
        }
    }

    /// The efforts from the least to the most.
    private static let effortOrder: [ModelRequest.Effort] = [
        .noReasoning, .minimal, .low, .medium, .high, .xhigh, .max,
    ]

    private static func rank(_ effort: ModelRequest.Effort) -> Int {
        effortOrder.firstIndex(of: effort) ?? effortOrder.count
    }

    /// Marks the model recommended for `task`: the catalog's choice, or a snapshot of it, when this key's list has one
    /// that isn't on its way out. Otherwise, as a suggestion, the newest version of the same series that is newer
    /// than the catalog's choice, which the catalog doesn't know yet, nor its price: never an older version, which
    /// has cost far more, nor another series, a variant, a fine-tune or a model added by hand. Text in an image goes
    /// only to a model that may read images.
    private static func recommend(_ entry: CatalogEntry, for task: DerivedTextOperation,
                                  in models: inout [CatalogModel]) {
        let open = models.indices.filter { index in
            let model = models[index]
            return !model.isLeaving && !model.addedByHand && (task != .extractText || model.readsImages != false)
        }
        // The catalog's choice itself, or else the snapshot of it made last.
        if let chosen = open.first(where: { models[$0].id == entry.id })
            ?? open.filter({ entry.names(models[$0].id) }).max(by: { madeBefore(models[$0], models[$1]) }) {
            models[chosen].recommendedFor.insert(task)
            return
        }
        guard let wanted = lineage(of: entry.id, provider: entry.provider) else { return }
        let newer = open.compactMap { index -> (index: Int, version: (Int, Int), undated: Int, made: Date)? in
            guard let found = lineage(of: models[index].id, provider: entry.provider), found.series == wanted.series,
                  found.version > wanted.version else { return nil }
            return (index, found.version, found.dated ? 0 : 1, models[index].created ?? .distantPast)
        }
        // The highest version; then the model itself before a snapshot of it; then the one made last.
        guard let best = newer.max(by: {
            ($0.version.0, $0.version.1, $0.undated, $0.made) < ($1.version.0, $1.version.1, $1.undated, $1.made)
        }) else { return }
        models[best.index].recommendedFor.insert(task)
        models[best.index].suggestedFor.insert(task)
    }

    /// Whether `first` was made before `second`; a model whose date isn't known counts as the oldest.
    private static func madeBefore(_ first: CatalogModel, _ second: CatalogModel) -> Bool {
        (first.created ?? .distantPast) < (second.created ?? .distantPast)
    }

    /// A model's series and version when `id` names a series' own model or a dated snapshot of it, such as "haiku"
    /// and 5.5 for "claude-haiku-5-5", or "luna" and 6.2 for "gpt-6.2-luna"; nil for anything else, such as a variant,
    /// a fine-tune or another product's name. A version has a digit or two each side of its point, so a date isn't
    /// taken for one.
    static func lineage(of id: String,
                        provider: ProviderPreset.ID) -> (series: String, version: (Int, Int), dated: Bool)? {
        switch provider {
        case .anthropic:
            guard let match = id.wholeMatch(of: /claude-([a-z]+)-([0-9]{1,2})(?:-([0-9]{1,2}))?(-[0-9]{8})?/) else {
                return nil
            }
            return (String(match.1), (Int(match.2) ?? 0, match.3.flatMap { Int($0) } ?? 0), match.4 != nil)
        case .openAI:
            guard let match = id.wholeMatch(
                of: /gpt-([0-9]{1,2})(?:\.([0-9]{1,2}))?-([a-z]+)(-[0-9]{4}-[0-9]{2}-[0-9]{2})?/
            ) else { return nil }
            return (String(match.3), (Int(match.1) ?? 0, match.2.flatMap { Int($0) } ?? 0), match.4 != nil)
        }
    }

    private static func claude(_ id: String, _ name: String, input: Double, output: Double) -> CatalogEntry {
        CatalogEntry(provider: .anthropic, id: id, displayName: name, price: ModelPrice(input: input, output: output))
    }
}
