import Foundation
import Observation

/// An engine a task can use: this Mac's own, or a cloud model from a provider set up with a key.
enum EngineChoice: Hashable, Sendable {
    case onThisMac
    case cloud(ProviderPreset.ID)
}

/// What a cloud model can be sent, which a person is asked about apart.
enum SentContent: String, CaseIterable, Sendable {
    case text
    case image
}

/// When a person is asked before a clip is sent to a cloud model.
enum AskBeforeSending: String, CaseIterable, Sendable {
    /// The first time each kind of content goes to each provider, until they say not to ask again.
    case firstTimeForEachProvider = "firstTime"
    case everyTime
}

/// The requests made to cloud models in a month, and about what they cost.
struct CloudUsage: Equatable, Sendable {
    var requests = 0
    /// What they cost, in dollars, as estimated from the catalog's prices.
    var dollars = 0.0
    /// The requests to a model whose price isn't known, which the estimate leaves out.
    var unpriced = 0
}

/// What a person chose for cloud models: the engine each task uses, the model each provider uses for each task, when
/// they're asked before a clip is sent and what they answered, and what this month's requests came to. A change is
/// kept at once in this Mac's preferences, never in an export or in iCloud. The app has one, which every part of it
/// shares, so that what one part changes, another sees.
@MainActor @Observable
final class CloudModelPreferences {
    static let askBeforeSendingKey = "cloudModels.askBeforeSending"
    static let sendingAnswersKey = "cloudModels.sendingAnswers"
    static let usageKey = "cloudModels.usage"

    /// When a person is asked before a clip is sent. Absent is the first time; a way of asking this version doesn't
    /// know, such as a later version's stricter one, is every time, and is left as it is.
    var askBeforeSending: AskBeforeSending {
        didSet { defaults.set(askBeforeSending.rawValue, forKey: Self.askBeforeSendingKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let timeZone: TimeZone
    private var engines: [DerivedTextOperation: EngineChoice] = [:]
    /// Each provider's model for each task, by the key it is kept under.
    private var models: [String: String] = [:]
    /// The kinds of content a person said not to be asked about again, for each provider, as "anthropic.text"; those
    /// this version doesn't know are kept as they are.
    private var answers: [String]
    /// The month whose requests are counted.
    private var counted: StoredUsage?

    /// Keeps choices in `defaults`, the app's own preferences or a test's suite, and counts months on the Gregorian
    /// calendar in `timeZone`, this Mac's as it changes unless a test gives another.
    init(defaults: UserDefaults, timeZone: TimeZone = .autoupdatingCurrent) {
        self.defaults = defaults
        self.timeZone = timeZone
        let asking = defaults.object(forKey: Self.askBeforeSendingKey)
        askBeforeSending = asking == nil ? .firstTimeForEachProvider
            : (asking as? String).flatMap(AskBeforeSending.init(rawValue:)) ?? .everyTime
        answers = defaults.object(forKey: Self.sendingAnswersKey) as? [String] ?? []
        counted = (defaults.object(forKey: Self.usageKey) as? Data)
            .flatMap { try? JSONDecoder().decode(StoredUsage.self, from: $0) }.flatMap { $0.isACount ? $0 : nil }
        for task in DerivedTextOperation.allCases {
            engines[task] = Self.engine(named: defaults.object(forKey: Self.engineKey(task)) as? String)
            for provider in ProviderPreset.all.map(\.id) {
                let key = Self.modelKey(task, provider)
                models[key] = Self.modelIdentifier(defaults.object(forKey: key) as? String)
            }
        }
    }

    /// The engine a person's own requests for `task` use: this Mac's own until another is chosen, or when the one
    /// chosen isn't one this version knows. What Keeptide does by itself, such as recognizing and translating new clips
    /// automatically, runs on this Mac whatever this says.
    func engine(for task: DerivedTextOperation) -> EngineChoice {
        engines[task] ?? .onThisMac
    }

    func setEngine(_ engine: EngineChoice, for task: DerivedTextOperation) {
        engines[task] = engine
        let name = switch engine {
        case .onThisMac: "onThisMac"
        case .cloud(let provider): provider.rawValue
        }
        defaults.set(name, forKey: Self.engineKey(task))
    }

    /// The model `provider` is asked to use for `task`, by its identifier, once one is chosen.
    func model(for task: DerivedTextOperation, from provider: ProviderPreset.ID) -> String? {
        models[Self.modelKey(task, provider)]
    }

    /// Chooses the model `provider` uses for `task`, without the spaces around it; nothing, or only spaces, is no
    /// model. Something that can't be a model's identifier, such as an API key pasted by mistake, isn't kept, and the
    /// model chosen before stays: whether it was kept.
    @discardableResult
    func setModel(_ id: String?, for task: DerivedTextOperation, from provider: ProviderPreset.ID) -> Bool {
        let trimmed = id?.trimmingCharacters(in: Self.surrounding) ?? ""
        let identifier = Self.modelIdentifier(trimmed)
        guard identifier != nil || trimmed.isEmpty else { return false }
        let key = Self.modelKey(task, provider)
        models[key] = identifier
        defaults.set(identifier, forKey: key)
        return true
    }

    /// Whether a person is asked before `content` goes to `provider`: every time, or until they said not to ask again.
    func needsAsking(before content: SentContent, to provider: ProviderPreset.ID) -> Bool {
        askBeforeSending == .everyTime || !answers.contains(Self.answer(content, provider))
    }

    /// Asks no more before `content` goes to `provider`, as a person said, until the answers are reset or the
    /// provider is forgotten. While a person is asked every time, there is nothing to keep.
    func remember(_ content: SentContent, to provider: ProviderPreset.ID) {
        guard askBeforeSending == .firstTimeForEachProvider else { return }
        let answer = Self.answer(content, provider)
        var kept = storedAnswers()
        if !kept.contains(answer) { kept.append(answer) }
        keepAnswers(kept)
    }

    /// Forgets every answer, so that a person is asked again.
    func resetAnswers() {
        keepAnswers([])
    }

    /// The requests made in the month of `now`.
    func usage(asOf now: Date) -> CloudUsage {
        guard let counted, counted.isIn(yearAndMonth(of: now)) else { return CloudUsage() }
        return CloudUsage(requests: counted.requests, dollars: counted.dollars, unpriced: counted.unpriced)
    }

    /// Counts a request made at `date` that cost `cost` dollars, by estimate; nil, or a cost that isn't one, is a price
    /// not known. A request in another month than the one counted, even an earlier one, starts that month at nothing.
    /// A count as high as it goes stays there, and a cost that would make the sum infinite counts as not known.
    func record(cost: Double?, at date: Date) {
        let current = yearAndMonth(of: date)
        var month = counted.flatMap { $0.isIn(current) ? $0 : nil }
            ?? StoredUsage(year: current.year, month: current.month, requests: 0, dollars: 0, unpriced: 0)
        month.requests = Self.oneMore(month.requests)
        if let cost, cost.isFinite, cost >= 0, (month.dollars + cost).isFinite {
            month.dollars += cost
        } else {
            month.unpriced = Self.oneMore(month.unpriced)
        }
        counted = month
        if let data = try? JSONEncoder().encode(month) { defaults.set(data, forKey: Self.usageKey) }
    }

    /// Counts this month from nothing.
    func resetUsage() {
        counted = nil
        defaults.removeObject(forKey: Self.usageKey)
    }

    /// Forgets what was chosen for `provider`: the tasks that used it use this Mac's engine again, as when nothing was
    /// chosen, its models are no longer chosen, and a person is asked again before anything goes to it, even of a kind
    /// a later version knows. What was used stays counted. It is for when the provider's key is removed, and, before
    /// the new key's choices are applied, when a key is added for a provider that had none, so that nothing chosen for
    /// an earlier key carries over.
    func forget(_ provider: ProviderPreset.ID) {
        for task in DerivedTextOperation.allCases {
            if engine(for: task) == .cloud(provider) {
                engines[task] = nil
                defaults.removeObject(forKey: Self.engineKey(task))
            }
            setModel(nil, for: task, from: provider)
        }
        let kept = storedAnswers()
        let others = kept.filter { !$0.hasPrefix(provider.rawValue + ".") }
        if others != kept || others != answers { keepAnswers(others) }
    }

    /// The answers the preferences hold, which another part of the app may have changed since they were read.
    private func storedAnswers() -> [String] {
        defaults.object(forKey: Self.sendingAnswersKey) as? [String] ?? []
    }

    private func keepAnswers(_ kept: [String]) {
        answers = kept
        if kept.isEmpty {
            defaults.removeObject(forKey: Self.sendingAnswersKey)
        } else {
            defaults.set(kept, forKey: Self.sendingAnswersKey)
        }
    }

    private func yearAndMonth(of date: Date) -> (year: Int, month: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month], from: date)
        return (components.year ?? 0, components.month ?? 0)
    }

    /// `count` and one more, or `count` when it is as high as it goes.
    private static func oneMore(_ count: Int) -> Int {
        count == .max ? count : count + 1
    }

    private static func taskName(_ task: DerivedTextOperation) -> String {
        switch task {
        case .extractText: "textRecognition"
        case .translate: "translation"
        }
    }

    private static func engineKey(_ task: DerivedTextOperation) -> String {
        "\(taskName(task)).engine"
    }

    private static func modelKey(_ task: DerivedTextOperation, _ provider: ProviderPreset.ID) -> String {
        "cloudModels.\(provider.rawValue).\(taskName(task))Model"
    }

    private static func answer(_ content: SentContent, _ provider: ProviderPreset.ID) -> String {
        "\(provider.rawValue).\(content.rawValue)"
    }

    /// The provider whose cloud model `name` names, if this version knows it; nil, this Mac's engine, otherwise.
    private static func engine(named name: String?) -> EngineChoice? {
        name.flatMap(ProviderPreset.ID.init(rawValue:)).map(EngineChoice.cloud)
    }

    /// What is taken from around a model's identifier as a key is pasted: spaces, line breaks and invisible characters.
    nonisolated private static let surrounding = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

    /// `text` without what is around it, if it can be a model's identifier: visible ASCII alone, with no API key in it,
    /// which no model's identifier has.
    nonisolated static func modelIdentifier(_ text: String?) -> String? {
        guard let id = text?.trimmingCharacters(in: surrounding), !id.isEmpty,
              id.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }),
              !ProviderPreset.all.contains(where: { hasKey(beginning: $0.id.keyPrefix, in: id) }) else { return nil }
        return id
    }

    /// Whether `id` has a key that begins with `prefix` where a key would begin: at its start, or after something other
    /// than a letter or a digit, as after its name in a line of a settings file or within quotes; not within a word,
    /// as in "task-".
    nonisolated private static func hasKey(beginning prefix: String, in id: String) -> Bool {
        var searched = id.startIndex
        while let found = id.range(of: prefix, range: searched..<id.endIndex) {
            let before = found.lowerBound == id.startIndex ? nil : id[id.index(before: found.lowerBound)]
            if before.map({ !$0.isLetter && !$0.isNumber }) ?? true { return true }
            searched = found.upperBound
        }
        return false
    }
}

/// A month's requests as the preferences keep them.
private struct StoredUsage: Codable, Equatable {
    var year: Int
    var month: Int
    var requests: Int
    var dollars: Double
    var unpriced: Int

    /// Whether it could be a month's count: a month of the year, counts no lower than none and no more requests
    /// unpriced than made, and a cost that is one.
    var isACount: Bool {
        (1...12).contains(month) && requests >= 0 && (0...requests).contains(unpriced) && dollars.isFinite
            && dollars >= 0
    }

    func isIn(_ month: (year: Int, month: Int)) -> Bool {
        year == month.year && self.month == month.month
    }
}
