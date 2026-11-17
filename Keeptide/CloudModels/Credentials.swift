import Foundation
import Security

/// What Keeptide keeps of a provider's API key, without the key: the identifier its keychain item goes by, whose key
/// it is, the last four characters of a key long enough to show them, and when it was added.
struct Credential: Codable, Hashable, Sendable {
    let id: UUID
    let provider: ProviderPreset.ID
    /// Empty for a key too short to show any of without showing much of it.
    let lastFour: String
    let added: Date
}

/// Why a key couldn't be kept, read or removed, or wasn't taken as given.
enum CredentialError: Error, Equatable, Sendable {
    /// The keychain has no item for the key, as when it was deleted in Keychain Access.
    case missing(ProviderPreset.ID)
    /// The person didn't let Keeptide read the key, the keychain is locked, or what its item holds isn't a key.
    case unreadable(ProviderPreset.ID, OSStatus)
    case notSaved(ProviderPreset.ID, OSStatus)
    case notRemoved(ProviderPreset.ID, OSStatus)
    /// The key has spaces or line breaks within it.
    case containsSpaces
    /// The key has a character that no provider writes in a key, such as an invisible one or a letter outside ASCII.
    case unexpectedCharacters
    /// An Admin API key, which manages an organization and which models don't accept.
    case adminKey
    /// The key is certainly this provider's, not the one it was given for.
    case otherProvidersKey(ProviderPreset.ID)
    /// The key doesn't begin as this provider's keys do, so it isn't one of its.
    case notProvidersKey(ProviderPreset.ID)
    case empty

    /// The error as a person reads it.
    var message: String {
        switch self {
        case .missing(let provider):
            "Keeptide can't find the \(provider.displayName) API key in your keychain."
        case .unreadable(let provider, _):
            "Keeptide couldn't read the \(provider.displayName) API key from your keychain."
        case .notSaved(let provider, _):
            "Keeptide couldn't save the \(provider.displayName) API key in your keychain."
        case .notRemoved(let provider, _):
            "Keeptide couldn't remove the \(provider.displayName) API key from your keychain."
        case .containsSpaces:
            "The key contains spaces."
        case .unexpectedCharacters:
            "The key contains characters that aren't part of an API key."
        case .adminKey:
            "Admin API keys can't be used with models. Paste an API key instead."
        case .otherProvidersKey(let provider):
            "This key is for \(provider.displayName). Choose \(provider.displayName) to add it."
        case .notProvidersKey(let provider):
            "This key isn't for \(provider.displayName). "
                + "\(provider.displayName)'s API keys begin with “\(provider.keyPrefix)”."
        case .empty:
            "Paste an API key to add it."
        }
    }
}

/// The keychain calls a credential store makes, so that tests can take the keychain's place.
protocol Keychain: Sendable {
    func add(_ item: [String: Any]) -> OSStatus
    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?)
    func delete(matching query: [String: Any]) -> OSStatus
}

/// The keychain itself.
struct SystemKeychain: Keychain {
    func add(_ item: [String: Any]) -> OSStatus {
        SecItemAdd(item as CFDictionary, nil)
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    func delete(matching query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

/// API keys in the keychain, each a generic password of its own under its credential's identifier, never in iCloud
/// Keychain. A build signed ad hoc can use only the file-based keychain, which ignores `kSecAttrAccessible`: there a key
/// is guarded by its item's access list, which trusts the build that saved it, and can be read whenever the login
/// keychain is unlocked. `WhenUnlockedThisDeviceOnly` takes effect once a signed build uses the data protection
/// keychain.
///
/// A key is read only when a person asks for something that needs it, such as a cloud request, checking a key or
/// refreshing its models, and never at launch or in the background, so that the keychain doesn't ask for nothing. A
/// keychain call waits for as long as the keychain's prompt is open, so the calls run on a queue of their own, one at a
/// time and never on the main thread.
struct KeychainCredentialStore: Sendable {
    static let service = "io.github.insightprober.Keeptide.api-key"
    /// The shortest key whose last four characters are shown; the providers' keys are all longer.
    private static let shownFrom = 40
    private static let queue = DispatchQueue(label: "io.github.insightprober.Keeptide.credentials",
                                             qos: .userInitiated)

    let keychain: any Keychain
    let newID: @Sendable () -> UUID
    let now: @Sendable () -> Date

    /// Keeps keys in `keychain`: the app gives the keychain itself, and tests a stand-in.
    init(keychain: any Keychain, newID: @escaping @Sendable () -> UUID = UUID.init,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.keychain = keychain
        self.newID = newID
        self.now = now
    }

    /// Keeps `key` for `provider` in a new item, and gives what Keeptide keeps of it. A key that can't be one, or that
    /// is certainly another provider's, isn't kept.
    func save(_ key: APIKey, for provider: ProviderPreset.ID) async throws -> Credential {
        try await oneAtATime {
            try Self.check(key, for: provider)
            let credential = self.credential(for: key, of: provider, id: newID())
            try add(key, as: credential)
            return credential
        }
    }

    /// The key `credential` stands for.
    func key(for credential: Credential) async throws -> APIKey {
        try await oneAtATime {
            var query = Self.item(credential.id)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            let (status, data) = keychain.copyData(matching: query)
            guard status == errSecSuccess else {
                throw status == errSecItemNotFound
                    ? CredentialError.missing(credential.provider) : .unreadable(credential.provider, status)
            }
            guard let data, let text = String(data: data, encoding: .utf8), APIKey.isWellFormed(text) else {
                throw CredentialError.unreadable(credential.provider, errSecDecode)
            }
            return APIKey(text)
        }
    }

    /// Puts `key` in place of `credential`'s, in a new item under the same identifier, so that a key is never written
    /// into an item Keeptide didn't make. When the old item can't be removed, nothing changes and the error says so;
    /// when the new key can't be saved once the old one is removed, neither is kept, and reading the key then says
    /// it's missing.
    func replace(_ credential: Credential, with key: APIKey) async throws -> Credential {
        try await oneAtATime {
            try Self.check(key, for: credential.provider)
            let status = keychain.delete(matching: Self.item(credential.id))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.notRemoved(credential.provider, status)
            }
            let replaced = self.credential(for: key, of: credential.provider, id: credential.id)
            try add(key, as: replaced)
            return replaced
        }
    }

    /// Removes `credential`'s key. A key already gone is removed.
    func remove(_ credential: Credential) async throws {
        try await oneAtATime {
            let status = keychain.delete(matching: Self.item(credential.id))
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialError.notRemoved(credential.provider, status)
            }
        }
    }

    /// Runs `work` on the store's queue, once every call before it is done.
    private func oneAtATime<Value: Sendable>(_ work: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    /// Why `key` can't be kept for `provider`, if it can't.
    private static func check(_ key: APIKey, for provider: ProviderPreset.ID) throws {
        try key.check(for: provider)
    }

    private func credential(for key: APIKey, of provider: ProviderPreset.ID, id: UUID) -> Credential {
        Credential(id: id, provider: provider,
                   lastFour: key.value.count >= Self.shownFrom ? String(key.value.suffix(4)) : "", added: now())
    }

    private func add(_ key: APIKey, as credential: Credential) throws {
        var item = Self.item(credential.id)
        item[kSecAttrLabel as String] = "Keeptide – \(credential.provider.displayName) API Key"
        item[kSecAttrSynchronizable as String] = false
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        item[kSecValueData as String] = Data(key.value.utf8)
        let status = keychain.add(item)
        guard status == errSecSuccess else { throw CredentialError.notSaved(credential.provider, status) }
    }

    /// The item of the key with identifier `id`.
    private static func item(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }
}

extension APIKey {
    /// A key as pasted, without the spaces, line breaks and invisible characters around it.
    init(pasted text: String) throws {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        try Self.check(key)
        self.init(key)
    }

    /// The provider whose keys begin as this one does, as the providers write them: "sk-ant-" for Anthropic, and any
    /// other "sk-" for OpenAI. A provider that speaks OpenAI's wire may write its keys alike, so only Anthropic's is
    /// certain.
    var likelyProvider: ProviderPreset.ID? {
        if value.hasPrefix("sk-ant-") { return .anthropic }
        if value.hasPrefix("sk-") { return .openAI }
        return nil
    }

    /// Why this key can't be used with `provider`, if it can't: as a pasted key isn't taken, or as one that is
    /// certainly another provider's, or doesn't begin as `provider`'s keys do. A key is checked so before it is sent
    /// or kept, so that it goes only to the provider it is for.
    func check(for provider: ProviderPreset.ID) throws {
        try Self.check(value)
        if likelyProvider == .anthropic, provider != .anthropic { throw CredentialError.otherProvidersKey(.anthropic) }
        guard value.hasPrefix(provider.keyPrefix) else { throw CredentialError.notProvidersKey(provider) }
    }

    /// Why `text` can't be kept as a key, if it can't: it's empty, has spaces within it or a character that no provider
    /// writes in a key, or it's an Admin API key.
    fileprivate static func check(_ text: String) throws {
        guard !text.isEmpty else { throw CredentialError.empty }
        guard !text.contains(where: \.isWhitespace) else { throw CredentialError.containsSpaces }
        guard isWellFormed(text) else { throw CredentialError.unexpectedCharacters }
        guard !text.hasPrefix("sk-ant-admin"), !text.hasPrefix("sk-admin-") else { throw CredentialError.adminKey }
    }

    /// Whether `text` is written as the providers write their keys, in visible ASCII alone.
    fileprivate static func isWellFormed(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }
}
