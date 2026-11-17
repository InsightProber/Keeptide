import Foundation
import Observation

/// A provider's list of models as it was when last read whole, for one of its keys.
struct ListedModels: Equatable, Sendable {
    /// The identifier of the key it was listed for.
    let credential: UUID
    let models: [RemoteModel]
    /// When it was read.
    let checked: Date
}

/// The models a provider listed for a key not yet kept, as `ProviderConnections.connect` gives them: the key, the
/// provider and the list together, so that the list is kept with the key it was read for.
struct ProviderListing: Sendable {
    let key: APIKey
    let provider: ProviderPreset.ID
    let models: [RemoteModel]
    /// When the list was read.
    let listed: Date
}

/// Why the last check of a provider's key didn't list its models.
enum ConnectionFailure: Error, Equatable, Sendable {
    /// The key couldn't be read from the keychain, or is no longer there.
    case key(CredentialError)
    /// The provider didn't give its list.
    case listing(GenerationError)
}

/// Why a provider's key wasn't changed.
enum KeyChangeError: Error, Equatable, Sendable {
    /// Another change to the same provider's key is under way.
    case busy
}

/// Lists a provider's models with a key: the whole list, or why not.
typealias ModelLister = @Sendable (ProviderPreset.ID, APIKey) async throws -> [RemoteModel]

/// The connection Keeptide keeps to each provider: its API key, one at most, in the keychain; what is kept of the key
/// in this Mac's preferences; the models the provider listed for it when last asked; and how the last check went. A key
/// is sent only to the provider it is for, and read only to check it, never as Keeptide opens. What is kept of each
/// provider is read on its own, so that one that can't be read leaves the others as they are, and what is kept of a
/// provider this version doesn't know is never touched.
@MainActor @Observable
final class ProviderConnections {
    /// How old a list may be before it is listed again as Settings opens.
    static let staleAfter: TimeInterval = 24 * 60 * 60

    /// What is kept of each provider's key.
    private(set) var credentials: [ProviderPreset.ID: Credential] = [:]
    /// The models each provider listed for its key when last asked.
    private(set) var listed: [ProviderPreset.ID: ListedModels] = [:]
    /// Why the last check of a provider's key didn't list its models, until a check does or Keeptide quits; or that
    /// its key is gone, when replacing it removed the old key without keeping the new one.
    private(set) var failures: [ProviderPreset.ID: ConnectionFailure] = [:]
    /// The providers whose key is being kept or removed.
    private(set) var changing: Set<ProviderPreset.ID> = []
    /// The keys whose checks are under way, among them keys since replaced or removed.
    private var checks: Set<Credential> = []
    /// How many changes to each provider's key have begun, so that a check can tell whether one began since it did.
    @ObservationIgnored private var changes: [ProviderPreset.ID: Int] = [:]

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: KeychainCredentialStore
    @ObservationIgnored private let list: ModelLister
    @ObservationIgnored private let now: () -> Date

    /// Keeps what it keeps in `defaults`, the app's own preferences or a test's suite, and keys in `keys`; lists
    /// models with `list`.
    init(defaults: UserDefaults, keys: KeychainCredentialStore, list: @escaping ModelLister,
         now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.keys = keys
        self.list = list
        self.now = now
        for provider in ProviderPreset.all.map(\.id) {
            guard let credential = Self.credential(of: provider, in: defaults) else { continue }
            credentials[provider] = credential
            listed[provider] = Self.listed(for: credential, in: defaults)
        }
    }

    /// The providers whose key, as it is now, is being checked.
    var checking: Set<ProviderPreset.ID> {
        Set(credentials.filter { checks.contains($0.value) }.keys)
    }

    /// Lists `provider`'s models with `key`, which isn't kept: whether the provider takes a key, before it is kept.
    /// A key that can't be `provider`'s isn't sent.
    func connect(_ key: APIKey, to provider: ProviderPreset.ID) async throws -> ProviderListing {
        try key.check(for: provider)
        let models = try await list(provider, key)
        return ProviderListing(key: key, provider: provider, models: models, listed: now())
    }

    /// Keeps the key of `listing` as its provider's, in place of the key it has, with the models listed for it.
    func keep(_ listing: ProviderListing) async throws -> Credential {
        try await keep(listing.key, for: listing.provider, listed: (listing.models, listing.listed))
    }

    /// Keeps `key` as `provider`'s, in place of the key it has, without any models.
    func keep(_ key: APIKey, for provider: ProviderPreset.ID) async throws -> Credential {
        try await keep(key, for: provider, listed: nil)
    }

    /// Lists `provider`'s models again with its key. A whole list takes the place of the one kept; otherwise the one
    /// kept stays, and why is said until a check succeeds. A provider without a key, or whose key is being changed,
    /// isn't checked, nor a key already being checked. The key is sent only if it is the provider's and no change to
    /// it began since the check did; a check that is cancelled, or during which such a change began, changes nothing.
    func refresh(_ provider: ProviderPreset.ID) async {
        guard let credential = credentials[provider], !Task.isCancelled, !changing.contains(provider),
              checks.insert(credential).inserted else { return }
        defer { checks.remove(credential) }
        let began = changes[provider, default: 0]
        let outcome: Result<[RemoteModel], ConnectionFailure>
        do {
            let key = try await keys.key(for: credential)
            try Task.checkCancellation()
            try key.check(for: provider)
            guard changes[provider, default: 0] == began else { return }
            outcome = .success(try await list(provider, key))
        } catch let error as CredentialError {
            outcome = .failure(.key(error))
        } catch let error as GenerationError {
            outcome = .failure(.listing(error))
        } catch is CancellationError {
            return
        } catch {
            outcome = .failure(.listing(.interrupted))
        }
        guard !Task.isCancelled, changes[provider, default: 0] == began else { return }
        switch outcome {
        case .success(let models):
            failures[provider] = nil
            setListed(ListedModels(credential: credential.id, models: models, checked: now()), for: provider)
        case .failure(let failure):
            failures[provider] = failure
        }
    }

    /// Lists again, as Settings opens, the models of each provider with a key whose list is a day old or more, or
    /// wasn't listed; Keeptide doesn't list them on a schedule. A list checked later than now, as by a clock set back,
    /// is old. A key that couldn't be read isn't read again until a person checks it, so that the keychain doesn't ask
    /// again each time.
    func refreshStale() async {
        let stale = ProviderPreset.all.map(\.id).filter { provider in
            guard credentials[provider] != nil else { return false }
            if case .key? = failures[provider] { return false }
            guard let checked = listed[provider]?.checked else { return true }
            let age = now().timeIntervalSince(checked)
            return age >= Self.staleAfter || age < 0
        }
        await withTaskGroup(of: Void.self) { group in
            for provider in stale {
                group.addTask { await self.refresh(provider) }
            }
        }
    }

    /// Removes `provider`'s key from the keychain, and then all that is kept of it. A key already gone from the
    /// keychain is removed all the same; one the keychain won't remove keeps all of it, to be removed again.
    func remove(_ provider: ProviderPreset.ID) async throws {
        try beginChange(of: provider)
        defer { changing.remove(provider) }
        guard let credential = credentials[provider] else { return }
        try await keys.remove(credential)
        credentials[provider] = nil
        defaults.removeObject(forKey: Self.credentialKey(provider))
        failures[provider] = nil
        setListed(nil, for: provider)
    }

    /// Lists a provider's models through `client`: each provider's at its own address, with the key as it takes one.
    nonisolated static func lister(client: ModelClient) -> ModelLister {
        { provider, key in
            switch provider {
            case .anthropic: try await AnthropicModels.list(by: client, key: key)
            case .openAI: try await OpenAIModels.list(by: client, key: key)
            }
        }
    }

    /// Keeps `key` as `provider`'s, with the models listed for it and when, or none. A key for a provider that has one
    /// replaces it; so does one for a provider whose key can't be read but names its keychain item, so that the item
    /// isn't left behind. When the keychain doesn't keep the key, nothing else changes, unless the old key was removed
    /// before: then it is said to be gone, and the models listed for it are no longer kept.
    private func keep(_ key: APIKey, for provider: ProviderPreset.ID,
                      listed models: (models: [RemoteModel], listed: Date)?) async throws -> Credential {
        try beginChange(of: provider)
        defer { changing.remove(provider) }
        let replaced = credentials[provider] ?? orphan(of: provider)
        let credential: Credential
        do {
            credential = if let replaced {
                try await keys.replace(replaced, with: key)
            } else {
                try await keys.save(key, for: provider)
            }
        } catch CredentialError.notSaved(_, let status) where credentials[provider] != nil {
            failures[provider] = .key(.missing(provider))
            setListed(nil, for: provider)
            throw CredentialError.notSaved(provider, status)
        }
        credentials[provider] = credential
        if let data = try? JSONEncoder().encode(credential) {
            defaults.set(data, forKey: Self.credentialKey(provider))
        }
        failures[provider] = nil
        setListed(models.map { ListedModels(credential: credential.id, models: $0.models, checked: $0.listed) },
                  for: provider)
        return credential
    }

    /// What can be told of a key for `provider` that is kept but can't be read: the identifier of its keychain item,
    /// when that can be read and isn't another provider's.
    private func orphan(of provider: ProviderPreset.ID) -> Credential? {
        guard let data = defaults.data(forKey: Self.credentialKey(provider)),
              let id = (try? JSONDecoder().decode(StoredIdentifier.self, from: data))?.id,
              !credentials.values.contains(where: { $0.id == id }) else { return nil }
        return Credential(id: id, provider: provider, lastFour: "", added: now())
    }

    /// Begins a change to `provider`'s key, unless one is under way.
    private func beginChange(of provider: ProviderPreset.ID) throws {
        guard changing.insert(provider).inserted else { throw KeyChangeError.busy }
        changes[provider, default: 0] += 1
    }

    private func setListed(_ models: ListedModels?, for provider: ProviderPreset.ID) {
        listed[provider] = models
        if let models, let data = try? JSONEncoder().encode(StoredList(models)) {
            defaults.set(data, forKey: Self.listKey(provider))
        } else {
            defaults.removeObject(forKey: Self.listKey(provider))
        }
    }

    private static func credentialKey(_ provider: ProviderPreset.ID) -> String {
        "cloudModels.\(provider.rawValue).credential"
    }

    private static func listKey(_ provider: ProviderPreset.ID) -> String {
        "cloudModels.\(provider.rawValue).models"
    }

    /// What is kept of `provider`'s key, if it can be read and is that provider's.
    private static func credential(of provider: ProviderPreset.ID, in defaults: UserDefaults) -> Credential? {
        guard let data = defaults.data(forKey: credentialKey(provider)),
              let credential = try? JSONDecoder().decode(Credential.self, from: data),
              credential.provider == provider else { return nil }
        return credential
    }

    /// The models kept for `credential`, if they were listed for it.
    private static func listed(for credential: Credential, in defaults: UserDefaults) -> ListedModels? {
        guard let data = defaults.data(forKey: listKey(credential.provider)),
              let stored = try? JSONDecoder().decode(StoredList.self, from: data),
              stored.credential == credential.id else { return nil }
        return ListedModels(credential: stored.credential, models: stored.models.map(\.model),
                            checked: stored.checked)
    }
}

/// The identifier of a key's keychain item, read from what is kept of a key when nothing else of it can be.
private struct StoredIdentifier: Decodable {
    let id: UUID
}

/// A list of models as the preferences keep it. Each model is read on its own, and one that can't be read is left
/// out; a list none of whose models can be read isn't read, so that the models are listed again.
private struct StoredList: Codable {
    let credential: UUID
    let checked: Date
    let models: [StoredModel]

    init(_ listed: ListedModels) {
        credential = listed.credential
        checked = listed.checked
        models = listed.models.map(StoredModel.init)
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        credential = try fields.decode(UUID.self, forKey: .credential)
        checked = try fields.decode(Date.self, forKey: .checked)
        let stored = try fields.decode([Lenient<StoredModel>].self, forKey: .models)
        models = stored.compactMap(\.value)
        guard !models.isEmpty || stored.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .models, in: fields, debugDescription: "No model read")
        }
    }
}

/// A model as the preferences keep it: what its provider said of it. Only its identifier must be read; anything else
/// that can't be is unknown. A way of thinking or an effort this version doesn't know is left out, and a lifecycle it
/// doesn't know is unknown.
private struct StoredModel: Codable {
    var id: String
    var displayName: String?
    var created: Date?
    var maxInputTokens: Int?
    var maxOutputTokens: Int?
    var readsImages: Bool?
    var thinkingTypes: [String]?
    var efforts: [String]?
    var lifecycle: String?
    var shutDown: Date?

    init(_ model: RemoteModel) {
        id = model.id
        displayName = model.displayName
        created = model.created
        maxInputTokens = model.maxInputTokens
        maxOutputTokens = model.maxOutputTokens
        readsImages = model.readsImages
        thinkingTypes = model.thinkingTypes?.map(\.rawValue).sorted()
        efforts = model.efforts?.map(\.rawValue).sorted()
        lifecycle = model.lifecycle?.rawValue
        shutDown = model.shutDown
    }

    init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        guard !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: fields, debugDescription: "No identifier")
        }
        displayName = try? fields.decodeIfPresent(String.self, forKey: .displayName)
        created = try? fields.decodeIfPresent(Date.self, forKey: .created)
        maxInputTokens = try? fields.decodeIfPresent(Int.self, forKey: .maxInputTokens)
        maxOutputTokens = try? fields.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        readsImages = try? fields.decodeIfPresent(Bool.self, forKey: .readsImages)
        thinkingTypes = try? fields.decodeIfPresent([String].self, forKey: .thinkingTypes)
        efforts = try? fields.decodeIfPresent([String].self, forKey: .efforts)
        lifecycle = try? fields.decodeIfPresent(String.self, forKey: .lifecycle)
        shutDown = try? fields.decodeIfPresent(Date.self, forKey: .shutDown)
    }

    var model: RemoteModel {
        RemoteModel(id: id, displayName: displayName, created: created, maxInputTokens: maxInputTokens,
                    maxOutputTokens: maxOutputTokens, readsImages: readsImages,
                    thinkingTypes: thinkingTypes.map { Set($0.compactMap(ModelRequest.Thinking.init(rawValue:))) },
                    efforts: efforts.map { Set($0.compactMap(ModelRequest.Effort.init(rawValue:))) },
                    lifecycle: lifecycle.flatMap(RemoteModel.Lifecycle.init(rawValue:)), shutDown: shutDown)
    }
}
