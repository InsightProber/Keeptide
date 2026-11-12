import Security
import XCTest
@testable import Keeptide

/// The connection to each provider: its API key, in a keychain held in memory; what is kept of the key in this Mac's
/// preferences; the models the provider lists for it; and how the last check went. Preferences are a suite of each
/// test's own, the providers' lists come from a stand-in, and the keys are synthetic.
@MainActor
final class ProviderConnectionsTests: XCTestCase {
    /// Keys long enough for their last four to be shown.
    private let claudeKey = APIKey("sk-ant-api03-synthetic-key-for-tests-only-AbCd")
    private let newClaudeKey = APIKey("sk-ant-api03-another-synthetic-key-for-tests-EfGh")
    private let openAIKey = APIKey("sk-proj-synthetic-key-for-tests-only-0123-WxYz")
    private let start = Date(timeIntervalSince1970: 1_794_355_200)
    private let rejected = GenerationError(kind: .keyRejected, message: "Anthropic didn't accept your API key.")

    private let haiku = RemoteModel(id: "claude-haiku-5-5", displayName: "Claude Haiku 5.5",
                                    created: Date(timeIntervalSince1970: 1_790_000_000), maxInputTokens: 200_000,
                                    maxOutputTokens: 64_000, readsImages: true, thinkingTypes: [.adaptive, .disabled],
                                    efforts: [.low, .medium, .high], lifecycle: .active)
    private let sonnet = RemoteModel(id: "claude-sonnet-5-5", displayName: "Claude Sonnet 5.5", readsImages: false,
                                     thinkingTypes: [.betweenTools], efforts: [.noReasoning, .max],
                                     lifecycle: .deprecated, shutDown: Date(timeIntervalSince1970: 1_800_000_000))
    private let luna = RemoteModel(id: "gpt-6-luna", created: Date(timeIntervalSince1970: 1_791_000_000))

    private func preferences() throws -> UserDefaults {
        let suiteName = "ProviderConnectionsTests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func connections(_ defaults: UserDefaults, keychain: KeychainStandIn = KeychainStandIn(),
                             providers: ProvidersStandIn = ProvidersStandIn(),
                             clock: TestClock? = nil) -> ProviderConnections {
        let clock = clock ?? TestClock(start)
        return ProviderConnections(defaults: defaults,
                                   keys: KeychainCredentialStore(keychain: keychain, now: { clock.now }),
                                   list: providers.list, now: { clock.now })
    }

    /// The models `provider` listed for `key`, as connecting gives them.
    private func listing(_ key: APIKey, _ provider: ProviderPreset.ID, _ models: [RemoteModel],
                         at date: Date? = nil) -> ProviderListing {
        ProviderListing(key: key, provider: provider, models: models, listed: date ?? start)
    }

    /// Everything the preferences hold, as text: each string as it is, and each data as UTF-8.
    private func stored(in defaults: UserDefaults) -> String {
        defaults.dictionaryRepresentation().values.map { value in
            (value as? Data).map { String(decoding: $0, as: UTF8.self) } ?? "\(value)"
        }.joined(separator: "\n")
    }

    func testAKeyIsKeptInTheKeychainAndWhatIsKeptOfItAndItsModelsIsReadBack() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let connections = connections(defaults, keychain: keychain)
        let listedAt = start.addingTimeInterval(-30)

        let credential = try await connections.keep(listing(claudeKey, .anthropic, [haiku, sonnet], at: listedAt))

        XCTAssertEqual(credential.provider, .anthropic)
        XCTAssertEqual(credential.lastFour, "AbCd")
        XCTAssertEqual(credential.added, start)
        XCTAssertEqual(keychain.added.count, 1)
        XCTAssertEqual(connections.credentials, [.anthropic: credential])
        let listed = ListedModels(credential: credential.id, models: [haiku, sonnet], checked: listedAt)
        XCTAssertEqual(connections.listed, [.anthropic: listed], "Checked when the models were listed")
        XCTAssertEqual(connections.failures, [:])
        let reopened = self.connections(defaults, keychain: keychain)
        XCTAssertEqual(reopened.credentials, connections.credentials)
        XCTAssertEqual(reopened.listed, connections.listed)
        XCTAssertTrue(keychain.queried.isEmpty, "Reading what is kept of a key doesn't read the key")
        XCTAssertFalse(stored(in: defaults).contains(claudeKey.value), "The key itself is only in the keychain")
    }

    func testKeepingAnotherKeyForAProviderReplacesItsKeyAndItsModels() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, keychain: keychain, providers: providers, clock: clock)
        let first = try await connections.keep(listing(claudeKey, .anthropic, [haiku, sonnet]))
        providers.answer(.anthropic, with: .failure(rejected))
        await connections.refresh(.anthropic)
        clock.now = start.addingTimeInterval(60)

        let second = try await connections.keep(listing(newClaudeKey, .anthropic, [haiku], at: clock.now))

        XCTAssertEqual(second.id, first.id, "The same item, as Replace keeps it")
        XCTAssertEqual(second.lastFour, "EfGh")
        XCTAssertEqual(second.added, clock.now)
        XCTAssertEqual(keychain.deleted.count, 1)
        XCTAssertEqual(keychain.added.count, 2)
        let key = try await KeychainCredentialStore(keychain: keychain).key(for: second)
        XCTAssertEqual(key.value, newClaudeKey.value)
        XCTAssertEqual(connections.credentials, [.anthropic: second])
        XCTAssertEqual(connections.listed,
                       [.anthropic: ListedModels(credential: first.id, models: [haiku], checked: clock.now)])
        XCTAssertEqual(connections.failures, [:], "What went wrong with the key before isn't said of this one")
        let reopened = self.connections(defaults, keychain: keychain)
        XCTAssertEqual(reopened.credentials, connections.credentials)
        XCTAssertEqual(reopened.listed, connections.listed)
    }

    func testAKeyKeptWithoutAListHasNoModels() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let connections = connections(defaults, keychain: keychain)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))

        _ = try await connections.keep(newClaudeKey, for: .anthropic)

        XCTAssertEqual(connections.listed, [:])
        XCTAssertEqual(self.connections(defaults, keychain: keychain).listed, [:])
    }

    func testEachProvidersKeyIsReadOnItsOwnAndOneThisVersionDoesntKnowIsLeftAlone() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let kept = try await connections(defaults, keychain: keychain).keep(listing(openAIKey, .openAI, [luna]))
        defaults.set(Data("not what Keeptide keeps".utf8), forKey: "cloudModels.anthropic.credential")
        let unknown = Data(
            #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","provider":"mistral","lastFour":"","added":0}"#.utf8)
        defaults.set(unknown, forKey: "cloudModels.mistral.credential")

        let connections = connections(defaults, keychain: keychain)

        XCTAssertEqual(connections.credentials, [.openAI: kept])
        XCTAssertEqual(connections.listed[.openAI]?.models, [luna])
        _ = try await connections.keep(claudeKey, for: .anthropic)
        try await connections.remove(.openAI)
        XCTAssertEqual(defaults.data(forKey: "cloudModels.mistral.credential"), unknown)
        let elsewhere = try JSONEncoder().encode(Credential(id: UUID(), provider: .openAI, lastFour: "", added: start))
        defaults.set(elsewhere, forKey: "cloudModels.anthropic.credential")
        XCTAssertEqual(self.connections(defaults, keychain: keychain).credentials, [:],
                       "What a provider's key says of another provider isn't read")
    }

    func testAKeyWhoseDetailsCantBeReadIsReplacedRatherThanLeftInTheKeychain() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let old = try await connections(defaults, keychain: keychain).keep(claudeKey, for: .anthropic)
        defaults.set(Data(#"{"id":"\#(old.id.uuidString)","provider":"anthropic","added":"a while ago"}"#.utf8),
                     forKey: "cloudModels.anthropic.credential")
        let connections = connections(defaults, keychain: keychain)
        XCTAssertEqual(connections.credentials, [:])

        let kept = try await connections.keep(newClaudeKey, for: .anthropic)

        XCTAssertEqual(kept.id, old.id, "The item the details name")
        XCTAssertEqual(keychain.deleted.last?[kSecAttrAccount as String] as? String, old.id.uuidString)
        let key = try await KeychainCredentialStore(keychain: keychain).key(for: kept)
        XCTAssertEqual(key.value, newClaudeKey.value)
        let openAI = try await connections.keep(openAIKey, for: .openAI)
        defaults.set(Data(#"{"id":"\#(openAI.id.uuidString)"}"#.utf8), forKey: "cloudModels.anthropic.credential")
        let anthropic = try await self.connections(defaults, keychain: keychain).keep(claudeKey, for: .anthropic)
        XCTAssertNotEqual(anthropic.id, openAI.id, "Not an item another provider's key is in")
        let openAIKept = try await KeychainCredentialStore(keychain: keychain).key(for: openAI)
        XCTAssertEqual(openAIKept.value, openAIKey.value)
    }

    func testAKeyTheKeychainWontKeepChangesNothing() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let connections = connections(defaults, keychain: keychain)
        keychain.answer(errSecAuthFailed, to: .add)

        await assertThrows(try await connections.keep(listing(claudeKey, .anthropic, [haiku])),
                           CredentialError.notSaved(.anthropic, errSecAuthFailed))

        XCTAssertEqual(connections.credentials, [:])
        XCTAssertEqual(connections.listed, [:])
        XCTAssertEqual(connections.failures, [:])
        XCTAssertNil(defaults.object(forKey: "cloudModels.anthropic.credential"))
        XCTAssertNil(defaults.object(forKey: "cloudModels.anthropic.models"))
        let kept = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        keychain.answer(errSecAuthFailed, to: .delete)
        await assertThrows(try await connections.keep(listing(newClaudeKey, .anthropic, [sonnet])),
                           CredentialError.notRemoved(.anthropic, errSecAuthFailed))
        XCTAssertEqual(connections.credentials, [.anthropic: kept])
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku])
        XCTAssertEqual(connections.failures, [:])
        let key = try await KeychainCredentialStore(keychain: keychain).key(for: kept)
        XCTAssertEqual(key.value, claudeKey.value, "The key it has stays")
        XCTAssertEqual(self.connections(defaults, keychain: keychain).credentials, [.anthropic: kept])
    }

    func testAKeyRemovedWithoutTheNewOneKeptIsSaidToBeGone() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        let kept = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        keychain.answer(errSecAuthFailed, to: .add)

        await assertThrows(try await connections.keep(listing(newClaudeKey, .anthropic, [sonnet])),
                           CredentialError.notSaved(.anthropic, errSecAuthFailed))

        XCTAssertEqual(connections.credentials, [.anthropic: kept], "So that it can still be replaced or removed")
        XCTAssertEqual(connections.failures, [.anthropic: .key(.missing(.anthropic))])
        XCTAssertEqual(connections.listed, [:])
        let reopened = self.connections(defaults, keychain: keychain, providers: providers)
        XCTAssertEqual(reopened.listed, [:], "So that it is checked again as Settings opens")
        await reopened.refreshStale()
        XCTAssertEqual(reopened.failures, [.anthropic: .key(.missing(.anthropic))])
        XCTAssertTrue(providers.asked.isEmpty)
    }

    func testRemovingAKeyRemovesItAndAllThatIsKeptOfIt() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        let credential = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        let openAI = try await connections.keep(listing(openAIKey, .openAI, [luna]))
        providers.answer(.anthropic, with: .failure(rejected))
        await connections.refresh(.anthropic)

        try await connections.remove(.anthropic)

        XCTAssertEqual(keychain.deleted.last?[kSecAttrAccount as String] as? String, credential.id.uuidString)
        XCTAssertEqual(connections.credentials, [.openAI: openAI])
        XCTAssertEqual(connections.listed.keys.sorted { $0.rawValue < $1.rawValue }, [.openAI])
        XCTAssertEqual(connections.failures, [:])
        XCTAssertNil(defaults.object(forKey: "cloudModels.anthropic.credential"))
        XCTAssertNil(defaults.object(forKey: "cloudModels.anthropic.models"))
        XCTAssertEqual(self.connections(defaults, keychain: keychain).credentials, [.openAI: openAI])
        let again = try await connections.keep(newClaudeKey, for: .anthropic)
        XCTAssertNotEqual(again.id, credential.id, "A key added again once one is removed is new")
        keychain.answer(errSecItemNotFound, to: .delete)
        try await connections.remove(.openAI)
        XCTAssertEqual(connections.credentials, [.anthropic: again],
                       "A key already gone from the keychain is removed all the same")
        XCTAssertNil(connections.listed[.openAI])
    }

    func testAKeyTheKeychainWontRemoveStaysWithAllThatIsKeptOfItToBeRemovedAgain() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        let credential = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        providers.answer(.anthropic, with: .failure(rejected))
        await connections.refresh(.anthropic)
        keychain.answer(errSecAuthFailed, to: .delete)

        await assertThrows(try await connections.remove(.anthropic),
                           CredentialError.notRemoved(.anthropic, errSecAuthFailed))

        XCTAssertEqual(connections.credentials, [.anthropic: credential])
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku])
        XCTAssertEqual(connections.failures, [.anthropic: .listing(rejected)])
        XCTAssertEqual(self.connections(defaults, keychain: keychain).credentials, [.anthropic: credential])
        try await connections.remove(.anthropic)
        XCTAssertEqual(connections.credentials, [:])
    }

    func testAKeyIsSentOnlyToTheProviderItIsFor() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)

        await assertThrows(try await connections.connect(claudeKey, to: .openAI),
                           CredentialError.otherProvidersKey(.anthropic))
        await assertThrows(try await connections.connect(openAIKey, to: .anthropic),
                           CredentialError.notProvidersKey(.anthropic))
        await assertThrows(try await connections.connect(APIKey("AIza-synthetic-key-for-tests"), to: .openAI),
                           CredentialError.notProvidersKey(.openAI))
        await assertThrows(try await connections.connect(APIKey("sk-ant-admin01-synthetic"), to: .anthropic),
                           CredentialError.adminKey)
        await assertThrows(try await connections.connect(APIKey("sk-ant-api03 synthetic"), to: .anthropic),
                           CredentialError.containsSpaces)
        await assertThrows(try await connections.keep(openAIKey, for: .anthropic),
                           CredentialError.notProvidersKey(.anthropic))

        XCTAssertTrue(providers.asked.isEmpty, "None was sent")
        XCTAssertTrue(keychain.added.isEmpty, "Nor kept")
        XCTAssertEqual(CredentialError.notProvidersKey(.anthropic).message,
                       "This key isn't for Anthropic. Anthropic's API keys begin with “sk-ant-”.")
        XCTAssertEqual(CredentialError.notProvidersKey(.openAI).message,
                       "This key isn't for OpenAI. OpenAI's API keys begin with “sk-”.")
    }

    func testConnectingListsModelsWithAKeyNotYetKept() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, keychain: keychain, providers: providers, clock: clock)
        providers.answer(.openAI, with: .success([luna]))
        clock.now = start.addingTimeInterval(5)

        let listing = try await connections.connect(openAIKey, to: .openAI)

        XCTAssertEqual(listing.models, [luna])
        XCTAssertEqual(listing.provider, .openAI)
        XCTAssertEqual(listing.key.value, openAIKey.value)
        XCTAssertEqual(listing.listed, clock.now)
        XCTAssertEqual(providers.asked.map(\.provider), [.openAI])
        XCTAssertEqual(providers.asked.map(\.key), [openAIKey.value])
        XCTAssertEqual(connections.credentials, [:])
        XCTAssertEqual(connections.listed, [:])
        XCTAssertTrue(keychain.added.isEmpty)
        providers.answer(.anthropic, with: .failure(rejected))
        await assertThrows(try await connections.connect(claudeKey, to: .anthropic), rejected)
        XCTAssertEqual(connections.failures, [:], "Nothing is kept of a key not kept")
        XCTAssertFalse(stored(in: defaults).contains(openAIKey.value))
        XCTAssertFalse(stored(in: defaults).contains(claudeKey.value))
    }

    func testRefreshingListsWithTheKeptKeyAndKeepsOnlyAWholeList() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, keychain: keychain, providers: providers, clock: clock)
        let credential = try await connections.keep(listing(claudeKey, .anthropic, [sonnet]))
        clock.now = start.addingTimeInterval(3_600)
        providers.answer(.anthropic, with: .success([haiku, sonnet]))

        await connections.refresh(.anthropic)

        XCTAssertEqual(providers.asked.map(\.key), [claudeKey.value])
        let refreshed = ListedModels(credential: credential.id, models: [haiku, sonnet], checked: clock.now)
        XCTAssertEqual(connections.listed, [.anthropic: refreshed])
        XCTAssertEqual(self.connections(defaults, keychain: keychain).listed, [.anthropic: refreshed])
        clock.now = start.addingTimeInterval(7_200)
        providers.answer(.anthropic, with: .failure(rejected))
        await connections.refresh(.anthropic)
        XCTAssertEqual(connections.listed, [.anthropic: refreshed], "What was listed before, and when, stays")
        XCTAssertEqual(connections.failures, [.anthropic: .listing(rejected)])
        let reopened = self.connections(defaults, keychain: keychain)
        XCTAssertEqual(reopened.listed, [.anthropic: refreshed])
        XCTAssertEqual(reopened.failures, [:], "A failure is said only until Keeptide quits")
        providers.answer(.anthropic, with: .failure(URLError(.badServerResponse)))
        await connections.refresh(.anthropic)
        XCTAssertEqual(connections.failures, [.anthropic: .listing(.interrupted)], "Anything else ends unexpectedly")
        providers.answer(.anthropic, with: .success([haiku]))
        await connections.refresh(.anthropic)
        XCTAssertEqual(connections.failures, [:])
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku])
        XCTAssertEqual(connections.checking, [])
    }

    func testAKeyThatCantBeReadIsSaidAsSuchAndReadAgainOnlyWhenChecked() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, keychain: keychain, providers: providers, clock: clock)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        keychain.answer(errSecAuthFailed, to: .copy)

        await connections.refresh(.anthropic)

        XCTAssertEqual(connections.failures, [.anthropic: .key(.unreadable(.anthropic, errSecAuthFailed))])
        XCTAssertTrue(providers.asked.isEmpty)
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku])
        clock.now = start.addingTimeInterval(2 * 24 * 60 * 60)
        let reads = keychain.queried.count
        await connections.refreshStale()
        XCTAssertEqual(keychain.queried.count, reads, "Settings opening again doesn't ask the keychain again")
        keychain.answer(errSecItemNotFound, to: .copy)
        await connections.refresh(.anthropic)
        XCTAssertEqual(keychain.queried.count, reads + 1, "Checking again does")
        XCTAssertEqual(connections.failures, [.anthropic: .key(.missing(.anthropic))])
        XCTAssertTrue(providers.asked.isEmpty)
        await connections.refresh(.openAI)
        XCTAssertTrue(providers.asked.isEmpty, "A provider without a key isn't asked")
        XCTAssertNil(connections.failures[.openAI])
    }

    func testOpeningSettingsListsAgainOnlyWhatIsADayOldOrNotListed() async throws {
        let defaults = try preferences()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, providers: providers, clock: clock)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        _ = try await connections.keep(openAIKey, for: .openAI)
        let day: TimeInterval = 24 * 60 * 60
        clock.now = start.addingTimeInterval(day - 1)

        await connections.refreshStale()

        XCTAssertEqual(providers.asked.map(\.provider), [.openAI])
        clock.now = start.addingTimeInterval(day)
        await connections.refreshStale()
        XCTAssertEqual(providers.asked.map(\.provider), [.openAI, .anthropic])
        clock.now = start
        await connections.refreshStale()
        XCTAssertEqual(providers.asked.count, 4, "A list checked later than now, as by a clock set back, is old")
        XCTAssertEqual(Set(providers.asked.suffix(2).map(\.provider)), [.anthropic, .openAI])
    }

    func testARefreshForAKeyChangedOrRemovedMeanwhileIsLetGo() async throws {
        let defaults = try preferences()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, providers: providers, clock: clock)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [sonnet]))
        providers.answer(.anthropic, with: .success([sonnet]))
        let replacement = listing(newClaudeKey, .anthropic, [haiku])
        providers.whileListing {
            clock.now = clock.now.addingTimeInterval(60)
            _ = try? await connections.keep(replacement)
        }

        await connections.refresh(.anthropic)

        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku], "The new key's list stays")
        XCTAssertEqual(connections.failures, [:])
        providers.answer(.anthropic, with: .failure(rejected))
        providers.whileListing { _ = try? await connections.remove(.anthropic) }
        await connections.refresh(.anthropic)
        XCTAssertEqual(connections.credentials, [:])
        XCTAssertEqual(connections.listed, [:])
        XCTAssertEqual(connections.failures, [:])
        XCTAssertNil(defaults.object(forKey: "cloudModels.anthropic.models"))
        XCTAssertEqual(connections.checking, [])
    }

    func testACheckOfAReplacedKeyDoesntHoldUpTheNewKeys() async throws {
        let defaults = try preferences()
        let providers = ProvidersStandIn()
        let clock = TestClock(start)
        let connections = connections(defaults, providers: providers, clock: clock)
        _ = try await connections.keep(claudeKey, for: .anthropic)
        providers.answer(.anthropic, with: .success([sonnet]))
        let newKey = newClaudeKey
        let haiku = self.haiku
        providers.whileListing {
            clock.now = clock.now.addingTimeInterval(60)
            _ = try? await connections.keep(newKey, for: .anthropic)
            providers.answer(.anthropic, with: .success([haiku]))
            let checking = await connections.checking
            XCTAssertEqual(checking, [], "The new key isn't being checked until it is")
            await connections.refresh(.anthropic)
        }

        await connections.refresh(.anthropic)

        XCTAssertEqual(providers.asked.map(\.key), [claudeKey.value, newClaudeKey.value])
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku], "The old key's list is let go")
        XCTAssertEqual(connections.failures, [:])
        XCTAssertEqual(connections.checking, [])
    }

    func testAKeyIsCheckedOnceAtATime() async throws {
        let defaults = try preferences()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, providers: providers)
        _ = try await connections.keep(claudeKey, for: .anthropic)
        providers.whileListing {
            let checking = await connections.checking
            XCTAssertEqual(checking, [.anthropic])
            await connections.refresh(.anthropic)
        }

        await connections.refresh(.anthropic)

        XCTAssertEqual(providers.asked.count, 1)
        XCTAssertEqual(connections.checking, [])
    }

    func testAKeyBeingRemovedAsItIsReadIsntSent() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        _ = try await connections.keep(claudeKey, for: .anthropic)
        let reading = Signal()
        let releaseRead = DispatchSemaphore(value: 0)
        let removing = Signal()
        let releaseRemoval = DispatchSemaphore(value: 0)
        defer {
            releaseRead.signal()
            releaseRemoval.signal()
        }
        keychain.whileCopying {
            reading.give()
            releaseRead.wait()
        }
        keychain.whileDeleting {
            removing.give()
            releaseRemoval.wait()
        }

        let check = Task { await connections.refresh(.anthropic) }
        let read = await reading.wait()
        XCTAssertTrue(read, "The key is being read")
        let removal = Task { try await connections.remove(.anthropic) }
        let removalBegun = await waitUntil { connections.changing.contains(.anthropic) }
        XCTAssertTrue(removalBegun)
        releaseRead.signal()
        await check.value
        let removalHeld = await removing.wait()
        XCTAssertTrue(removalHeld, "The check ended while the removal waited on the keychain")
        releaseRemoval.signal()
        try await removal.value

        XCTAssertTrue(providers.asked.isEmpty, "The key wasn't sent")
        XCTAssertEqual(connections.credentials, [:])
        XCTAssertEqual(connections.failures, [:])
        XCTAssertEqual(connections.checking, [])
    }

    func testACancelledRefreshKeepsWhatItHadAndSaysNothingWentWrong() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        providers.answer(.anthropic, with: .failure(CancellationError()))

        await connections.refresh(.anthropic)

        XCTAssertEqual(connections.failures, [:])
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku])
        XCTAssertEqual(connections.checking, [])
        let queried = keychain.queried.count
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await connections.refresh(.anthropic)
        }
        await cancelled.value
        XCTAssertEqual(providers.asked.count, 1, "Nothing is sent for a refresh already cancelled")
        XCTAssertEqual(keychain.queried.count, queried, "Nor is the key read")
        let reading = TaskHolder()
        keychain.whileCopying { reading.task?.cancel() }
        reading.task = Task { await connections.refresh(.anthropic) }
        await reading.task?.value
        XCTAssertEqual(providers.asked.count, 1, "Nothing is sent for a refresh cancelled as the key is read")
        providers.answer(.anthropic, with: .success([sonnet]))
        providers.whileListing { withUnsafeCurrentTask { $0?.cancel() } }
        await Task { await connections.refresh(.anthropic) }.value
        XCTAssertEqual(providers.asked.count, 2)
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku], "Nor is a list kept from a cancelled refresh")
        XCTAssertEqual(connections.failures, [:])
        XCTAssertEqual(connections.checking, [])
    }

    func testAProvidersKeyChangesOnceAtATime() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let connections = connections(defaults, keychain: keychain)
        let (claudeKey, newKey, openAIKey) = (self.claudeKey, newClaudeKey, self.openAIKey)
        let adding = Signal()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        keychain.whileAdding {
            adding.give()
            release.wait()
        }

        let first = Task { try await connections.keep(claudeKey, for: .anthropic) }
        let held = await adding.wait()

        XCTAssertTrue(held, "The first change waits on the keychain")
        XCTAssertEqual(connections.changing, [.anthropic])
        await assertThrows(try await connections.keep(newKey, for: .anthropic), KeyChangeError.busy)
        await assertThrows(try await connections.remove(.anthropic), KeyChangeError.busy)
        let other = Task { try await connections.keep(openAIKey, for: .openAI) }
        release.signal()
        let kept = try await first.value
        let openAI = try await other.value
        XCTAssertEqual(kept.lastFour, "AbCd")
        XCTAssertEqual(connections.credentials, [.anthropic: kept, .openAI: openAI],
                       "Another provider's key changes meanwhile")
        XCTAssertEqual(keychain.added.count, 2)
        XCTAssertEqual(connections.changing, [])
    }

    func testAReplaceThatLosesTheKeyDuringACheckStaysSaid() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        providers.answer(.anthropic, with: .success([sonnet]))
        let newKey = newClaudeKey
        providers.whileListing {
            keychain.answer(errSecAuthFailed, to: .add)
            _ = try? await connections.keep(newKey, for: .anthropic)
        }

        await connections.refresh(.anthropic)

        XCTAssertEqual(connections.failures, [.anthropic: .key(.missing(.anthropic))])
        XCTAssertEqual(connections.listed, [:], "Nor is the list read with the key since lost kept")
    }

    func testAKeyTheKeychainGivesThatIsntTheProvidersIsntSent() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        _ = try await connections.keep(listing(claudeKey, .anthropic, [haiku]))
        keychain.answer(errSecSuccess, data: Data(openAIKey.value.utf8), to: .copy)

        await connections.refresh(.anthropic)

        XCTAssertTrue(providers.asked.isEmpty)
        XCTAssertEqual(connections.failures, [.anthropic: .key(.notProvidersKey(.anthropic))])
        XCTAssertEqual(connections.listed[.anthropic]?.models, [haiku])
    }

    func testACheckAskedForWhileTheKeyIsBeingChangedIsntMade() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let providers = ProvidersStandIn()
        let connections = connections(defaults, keychain: keychain, providers: providers)
        _ = try await connections.keep(claudeKey, for: .anthropic)
        let newKey = newClaudeKey
        let adding = Signal()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        keychain.whileAdding {
            adding.give()
            release.wait()
        }
        let change = Task { try await connections.keep(newKey, for: .anthropic) }
        let held = await adding.wait()
        XCTAssertTrue(held, "The key is being replaced")
        let reads = keychain.queried.count

        // The check starts on the main actor before the replacement can end there.
        let check = Task { await connections.refresh(.anthropic) }
        release.signal()
        await check.value
        _ = try await change.value

        XCTAssertEqual(keychain.queried.count, reads, "The key isn't read")
        XCTAssertTrue(providers.asked.isEmpty)
    }

    func testWhatIsKeptOfAListIsReadOneModelAtATimeAndOnlyForItsKey() async throws {
        let defaults = try preferences()
        let keychain = KeychainStandIn()
        let credential = try await connections(defaults, keychain: keychain).keep(listing(claudeKey, .anthropic,
                                                                                          [haiku]))
        let checked = start.timeIntervalSinceReferenceDate
        defaults.set(Data("""
            {"credential":"\(credential.id.uuidString)","checked":\(checked),"models":[
            {"id":"claude-haiku-5-5","created":"yesterday","readsImages":"yes"},
            {"displayName":"A model without an identifier"},
            {"id":""},
            {"id":"claude-next","lifecycle":"legacy","efforts":["low","turbo"],"thinkingTypes":["disabled","dreaming"]}
            ]}
            """.utf8), forKey: "cloudModels.anthropic.models")

        XCTAssertEqual(connections(defaults, keychain: keychain).listed[.anthropic]?.models,
                       [RemoteModel(id: "claude-haiku-5-5"),
                        RemoteModel(id: "claude-next", thinkingTypes: [.disabled], efforts: [.low])])
        defaults.set(Data("""
            {"credential":"\(credential.id.uuidString)","checked":\(checked),"models":[{"id":""},{"name":"x"}]}
            """.utf8), forKey: "cloudModels.anthropic.models")
        XCTAssertNil(connections(defaults, keychain: keychain).listed[.anthropic],
                     "A list none of whose models can be read, so that it is listed again")
        defaults.set(Data("""
            {"credential":"\(UUID().uuidString)","checked":\(checked),"models":[{"id":"claude-haiku-5-5"}]}
            """.utf8), forKey: "cloudModels.anthropic.models")
        XCTAssertNil(connections(defaults, keychain: keychain).listed[.anthropic], "A list for another key")
    }

    func testEachProviderIsAskedForItsListAtItsOwnAddressWithTheKey() async throws {
        StubService.reset()
        let list = ProviderConnections.lister(client: ModelClient(protocolClasses: [StubService.self]))
        StubService.answer(.respond(status: 200, headers: [:], chunks: [
            Data(#"{"data":[{"id":"claude-haiku-5-5","type":"model"}],"has_more":false}"#.utf8),
        ]))

        let claude = try await list(.anthropic, claudeKey)

        XCTAssertEqual(claude.map(\.id), ["claude-haiku-5-5"])
        let claudeRequest = try XCTUnwrap(StubService.requests.last?.request)
        XCTAssertEqual(claudeRequest.url?.absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(claudeRequest.value(forHTTPHeaderField: "x-api-key"), claudeKey.value)
        StubService.answer(.respond(status: 200, headers: [:], chunks: [
            Data(#"{"object":"list","data":[{"id":"gpt-6-luna","object":"model","created":1791000000}]}"#.utf8),
        ]))
        let openAI = try await list(.openAI, openAIKey)
        XCTAssertEqual(openAI, [luna])
        let openAIRequest = try XCTUnwrap(StubService.requests.last?.request)
        XCTAssertEqual(openAIRequest.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(openAIRequest.value(forHTTPHeaderField: "Authorization"), "Bearer \(openAIKey.value)")
        XCTAssertEqual(StubService.requests.count, 2)
    }

    /// Waits, letting other work on the main actor run, until `condition` holds or ten seconds pass; whether it held.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            guard Date() < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    private func assertThrows<Value, Failure: Error & Equatable>(
        _ expression: @autoclosure () async throws -> Value, _ expected: Failure,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? Failure, expected, file: file, line: line)
        }
    }
}

/// The providers' lists as a test says them, which records who was asked with which key. What `whileListing` gives
/// runs as the next list is being read, before it is given, so that a test can change things at that moment.
private final class ProvidersStandIn: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ProviderPreset.ID: Result<[RemoteModel], any Error>] = [:]
    private var recorded: [(provider: ProviderPreset.ID, key: String)] = []
    private var meanwhile: (@Sendable () async -> Void)?

    var asked: [(provider: ProviderPreset.ID, key: String)] { lock.withLock { recorded } }

    /// Gives `result` for each list `provider` is asked for from now on; until then, a list of no models.
    func answer(_ provider: ProviderPreset.ID, with result: Result<[RemoteModel], any Error>) {
        lock.withLock { answers[provider] = result }
    }

    /// Runs `action` as the next list is read, once.
    func whileListing(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock { meanwhile = action }
    }

    var list: ModelLister {
        { provider, key in
            let (answer, meanwhile) = self.lock.withLock {
                self.recorded.append((provider, key.value))
                defer { self.meanwhile = nil }
                return (self.answers[provider], self.meanwhile)
            }
            await meanwhile?()
            return try (answer ?? .success([])).get()
        }
    }
}

/// A moment one side says has come, from any thread, and the other waits for.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func give() {
        continuation.yield()
    }

    /// Waits until the moment comes, or ten seconds pass; whether it came.
    func wait() async -> Bool {
        let stream = stream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            let came = await group.next() ?? false
            group.cancelAll()
            return came
        }
    }
}

/// A task, for something that runs while it does to cancel it.
private final class TaskHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var held: Task<Void, Never>?

    var task: Task<Void, Never>? {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}

/// A clock a test sets.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) {
        value = start
    }

    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
