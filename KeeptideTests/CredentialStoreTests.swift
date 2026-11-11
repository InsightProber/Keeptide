import Security
import XCTest
@testable import Keeptide

/// API keys kept in the keychain, each in an item of its own that never syncs, and what Keeptide keeps of a key without
/// the key itself. A stand-in takes the keychain's place, so no test reads or writes the real keychain; the keys are
/// synthetic.
final class CredentialStoreTests: XCTestCase {
    private let keychain = KeychainStandIn()
    private let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    private let added = Date(timeIntervalSince1970: 1_794_355_200)
    /// Keys as long as the providers' keys begin to be, so that their last four are shown.
    private let claudeKey = APIKey("sk-ant-api03-synthetic-key-for-tests-only-AbCd")
    private let openAIKey = APIKey("sk-proj-synthetic-key-for-tests-only-0123-WxYz")
    private let newClaudeKey = APIKey("sk-ant-api03-another-synthetic-key-for-tests-EfGh")

    private func store(newID: (@Sendable () -> UUID)? = nil,
                       now: (@Sendable () -> Date)? = nil) -> KeychainCredentialStore {
        let id = id
        let added = added
        return KeychainCredentialStore(keychain: keychain, newID: newID ?? { id }, now: now ?? { added })
    }

    func testAKeyIsSavedAsAnItemOfItsOwnThatIsNeverSynced() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)

        XCTAssertEqual(credential, Credential(id: id, provider: .anthropic, lastFour: "AbCd", added: added))
        let item = try XCTUnwrap(keychain.added.first)
        XCTAssertEqual(item[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(item[kSecAttrService as String] as? String, "io.github.insightprober.Keeptide.api-key")
        XCTAssertEqual(item[kSecAttrAccount as String] as? String, id.uuidString)
        XCTAssertEqual(item[kSecAttrLabel as String] as? String, "Keeptide – Anthropic API Key")
        XCTAssertEqual(item[kSecAttrSynchronizable as String] as? Bool, false, "Not in iCloud Keychain")
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String, "For the data protection keychain")
        XCTAssertEqual(item[kSecValueData as String] as? Data, Data(claudeKey.value.utf8))
        XCTAssertNil(item[kSecUseDataProtectionKeychain as String], "A build signed ad hoc can't use it")
        let openAI = try await store(newID: { UUID() }).save(openAIKey, for: .openAI)
        XCTAssertEqual(openAI.lastFour, "WxYz")
        XCTAssertEqual(keychain.added.last?[kSecAttrLabel as String] as? String, "Keeptide – OpenAI API Key")
    }

    func testAKeyIsReadBackByItsCredentialAlone() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)

        let key = try await store().key(for: credential)

        XCTAssertEqual(key.value, claudeKey.value)
        let query = try XCTUnwrap(keychain.queried.last)
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
        XCTAssertEqual(query[kSecMatchLimit as String] as? String, kSecMatchLimitOne as String)
    }

    func testEveryCallNamesItsItemByClassServiceAndIdentifier() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)
        _ = try await store().key(for: credential)
        _ = try await store().replace(credential, with: newClaudeKey)
        try await store().remove(credential)

        let calls = keychain.added + keychain.queried + keychain.deleted
        XCTAssertEqual(calls.count, 5, "Saving, reading, replacing (removing, then saving) and removing")
        for call in calls {
            XCTAssertEqual(call[kSecClass as String] as? String, kSecClassGenericPassword as String)
            XCTAssertEqual(call[kSecAttrService as String] as? String, KeychainCredentialStore.service)
            XCTAssertEqual(call[kSecAttrAccount as String] as? String, id.uuidString)
        }
    }

    func testAKeyNoLongerInTheKeychainIsSaidToBeMissing() async {
        let credential = Credential(id: id, provider: .anthropic, lastFour: "AbCd", added: added)

        await assertThrows(try await store().key(for: credential), .missing(.anthropic))
        XCTAssertEqual(CredentialError.missing(.anthropic).message,
                       "Keeptide can't find the Anthropic API key in your keychain.")
    }

    func testAKeyTheKeychainWontGiveIsSaidAsSuch() async {
        let credential = Credential(id: id, provider: .anthropic, lastFour: "AbCd", added: added)
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed, errSecNoSuchKeychain] {
            keychain.answer(status, to: .copy)

            await assertThrows(try await store().key(for: credential), .unreadable(.anthropic, status), "\(status)")
        }
        XCTAssertEqual(CredentialError.unreadable(.anthropic, errSecUserCanceled).message,
                       "Keeptide couldn't read the Anthropic API key from your keychain.")
        for data in [nil, Data(), Data([0xFF, 0xFE]), Data("sk-ant-api03-synthetic\n".utf8)] {
            keychain.answer(errSecSuccess, data: data, to: .copy)

            await assertThrows(try await store().key(for: credential), .unreadable(.anthropic, errSecDecode),
                               "What the keychain gives isn't a key: \(String(describing: data))")
        }
    }

    func testReplacingAKeyPutsItInANewItemUnderTheSameIdentifier() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)
        let later = Date(timeIntervalSince1970: 1_794_441_600)

        let replaced = try await store(newID: { UUID() }, now: { later }).replace(credential, with: newClaudeKey)

        XCTAssertEqual(replaced, Credential(id: id, provider: .anthropic, lastFour: "EfGh", added: later))
        let key = try await store().key(for: replaced)
        XCTAssertEqual(key.value, newClaudeKey.value)
        XCTAssertEqual(keychain.deleted.count, 1)
        XCTAssertEqual(keychain.added.map { $0[kSecAttrAccount as String] as? String }, [id.uuidString, id.uuidString],
                       "A key is never written into an item Keeptide didn't make")
        XCTAssertEqual(keychain.added.last?[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testReplacingAKeyWhoseItemIsGoneSavesItAgain() async throws {
        let credential = Credential(id: id, provider: .openAI, lastFour: "WxYz", added: added)

        let replaced = try await store().replace(credential, with: openAIKey)

        XCTAssertEqual(replaced.id, id)
        let key = try await store().key(for: replaced)
        XCTAssertEqual(key.value, openAIKey.value)
    }

    func testAKeyThatCantBeReplacedIsSaidAsSuch() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)
        keychain.answer(errSecAuthFailed, to: .delete)

        await assertThrows(try await store().replace(credential, with: newClaudeKey),
                           .notSaved(.anthropic, errSecAuthFailed))
        XCTAssertEqual(keychain.added.count, 1, "Nothing is saved while the old key is in place")
        let kept = try await store().key(for: credential)
        XCTAssertEqual(kept.value, claudeKey.value)

        keychain.answer(errSecDuplicateItem, to: .add)
        await assertThrows(try await store().replace(credential, with: newClaudeKey),
                           .notSaved(.anthropic, errSecDuplicateItem))
        await assertThrows(try await store().key(for: credential), .missing(.anthropic),
                           "A key that couldn't take the old one's place leaves neither")
    }

    func testRemovingAKeyRemovesItsItemAndAKeyAlreadyGoneIsRemoved() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)

        try await store().remove(credential)
        try await store().remove(credential)

        XCTAssertEqual(keychain.deleted.count, 2)
        await assertThrows(try await store().key(for: credential), .missing(.anthropic))
        keychain.answer(errSecInteractionNotAllowed, to: .delete)
        await assertThrows(try await store().remove(credential), .notRemoved(.anthropic, errSecInteractionNotAllowed))
        XCTAssertEqual(CredentialError.notRemoved(.anthropic, errSecInteractionNotAllowed).message,
                       "Keeptide couldn't remove the Anthropic API key from your keychain.")
    }

    func testAKeyThatCantBeSavedIsSaidAsSuch() async throws {
        keychain.answer(errSecAuthFailed, to: .add)

        await assertThrows(try await store().save(openAIKey, for: .openAI), .notSaved(.openAI, errSecAuthFailed))
        XCTAssertEqual(CredentialError.notSaved(.openAI, errSecAuthFailed).message,
                       "Keeptide couldn't save the OpenAI API key in your keychain.")
        let credential = try await store().save(claudeKey, for: .anthropic)
        await assertThrows(try await store().save(newClaudeKey, for: .anthropic),
                           .notSaved(.anthropic, errSecDuplicateItem), "Never over an item already there")
        let kept = try await store().key(for: credential)
        XCTAssertEqual(kept.value, claudeKey.value)
    }

    func testAPastedKeyLosesWhatSurroundsItButHasNothingWithinThatKeysDont() throws {
        XCTAssertEqual(try APIKey(pasted: "  sk-ant-api03-synthetic\n").value, "sk-ant-api03-synthetic")
        XCTAssertEqual(try APIKey(pasted: "\u{FEFF}sk-ant-api03-synthetic\u{200B}\u{0}").value,
                       "sk-ant-api03-synthetic", "Invisible characters around a key aren't part of it")
        for pasted in ["sk-ant api03", "sk-ant-api03\nsynthetic", "sk-ant-\tapi03", "sk-ant-\u{00A0}api03"] {
            XCTAssertThrowsError(try APIKey(pasted: pasted), pasted) { error in
                XCTAssertEqual(error as? CredentialError, .containsSpaces)
            }
        }
        XCTAssertEqual(CredentialError.containsSpaces.message, "The key contains spaces.")
        for pasted in ["sk-ant-api03\u{200B}synthetic", "sk-ant-api03\u{00AD}synthetic", "sk-ant-api03\u{0}synthetic",
                       "sk-ant-\u{0430}pi03-synthetic", "sk-ant-api03-synth\u{E9}tic"] {
            XCTAssertThrowsError(try APIKey(pasted: pasted), pasted.debugDescription) { error in
                XCTAssertEqual(error as? CredentialError, .unexpectedCharacters)
            }
        }
        XCTAssertEqual(CredentialError.unexpectedCharacters.message,
                       "The key contains characters that aren't part of an API key.")
        for pasted in ["", " \n ", "\u{FEFF}"] {
            XCTAssertThrowsError(try APIKey(pasted: pasted)) { error in
                XCTAssertEqual(error as? CredentialError, .empty)
            }
        }
    }

    func testAnAdminKeyIsNotTaken() {
        for pasted in ["sk-ant-admin01-synthetic-key-for-tests", "sk-admin-synthetic-key-for-tests"] {
            XCTAssertThrowsError(try APIKey(pasted: pasted), pasted) { error in
                XCTAssertEqual(error as? CredentialError, .adminKey)
            }
        }
        XCTAssertEqual(CredentialError.adminKey.message,
                       "Admin API keys can't be used with models. Paste an API key instead.")
        XCTAssertEqual(try APIKey(pasted: "sk-ant-api03-administrator").value, "sk-ant-api03-administrator")
    }

    func testAKeyGivenToTheStoreIsCheckedAsAPastedOneIs() async {
        await assertThrows(try await store().save(APIKey("sk-ant-api03 synthetic"), for: .anthropic), .containsSpaces)
        await assertThrows(try await store().save(APIKey("sk-ant-api03\u{200B}"), for: .anthropic),
                           .unexpectedCharacters)
        await assertThrows(try await store().save(APIKey(""), for: .anthropic), .empty)
        await assertThrows(try await store().save(APIKey("sk-ant-admin01-synthetic"), for: .anthropic), .adminKey)
        let credential = Credential(id: id, provider: .openAI, lastFour: "WxYz", added: added)
        await assertThrows(try await store().replace(credential, with: APIKey("sk-admin-synthetic")), .adminKey)
        XCTAssertEqual(keychain.added.count, 0)
        XCTAssertEqual(keychain.deleted.count, 0)
    }

    func testAnAnthropicKeyIsKeptForAnthropicAlone() async throws {
        await assertThrows(try await store().save(claudeKey, for: .openAI), .otherProvidersKey(.anthropic))
        let credential = try await store().save(openAIKey, for: .openAI)

        await assertThrows(try await store().replace(credential, with: claudeKey), .otherProvidersKey(.anthropic))

        XCTAssertEqual(keychain.deleted.count, 0, "The key in place stays")
        XCTAssertEqual(CredentialError.otherProvidersKey(.anthropic).message,
                       "This key is for Anthropic. Choose Anthropic to add it.")
    }

    func testAKeysBeginningSaysWhoseItLikelyIs() {
        XCTAssertEqual(APIKey("sk-ant-api03-synthetic").likelyProvider, .anthropic)
        XCTAssertEqual(APIKey("sk-proj-synthetic").likelyProvider, .openAI)
        XCTAssertEqual(APIKey("sk-synthetic").likelyProvider, .openAI)
        XCTAssertNil(APIKey("AIza-synthetic").likelyProvider)
        XCTAssertNil(APIKey("SK-ANT-synthetic").likelyProvider, "As the providers write their keys")
    }

    func testWhatIsKeptOfAKeyNeverHasTheKey() async throws {
        let credential = try await store().save(claudeKey, for: .anthropic)

        let encoded = try JSONEncoder().encode(credential)

        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(fields.keys.sorted(), ["added", "id", "lastFour", "provider"])
        XCTAssertEqual(try JSONDecoder().decode(Credential.self, from: encoded), credential)
    }

    func testOnlyAKeyAsLongAsTheProvidersKeysShowsItsLastFour() async throws {
        let shorter = APIKey("sk-ant-api03-" + String(repeating: "x", count: 22) + "AbCd")
        let long = APIKey("sk-ant-api03-" + String(repeating: "x", count: 23) + "AbCd")
        let store = store(newID: { UUID() })

        let shorterCredential = try await store.save(shorter, for: .anthropic)
        let longCredential = try await store.save(long, for: .anthropic)

        XCTAssertEqual([shorter.value.count, long.value.count], [39, 40])
        XCTAssertEqual(shorterCredential.lastFour, "", "Too short to show any of without showing much of it")
        XCTAssertEqual(longCredential.lastFour, "AbCd")
    }

    @MainActor
    func testKeychainCallsNeverRunOnTheMainThread() async throws {
        let store = store()

        let credential = try await store.save(claudeKey, for: .anthropic)
        _ = try await store.key(for: credential)
        _ = try await store.replace(credential, with: newClaudeKey)
        try await store.remove(credential)

        XCTAssertEqual(keychain.onMainThread, [false, false, false, false, false],
                       "A keychain prompt waits without stopping the app")
    }

    func testKeychainCallsRunOneAtATime() async throws {
        let slow = SlowKeychain()
        let store = KeychainCredentialStore(keychain: slow, newID: { UUID() }, now: { Date() })
        let key = claudeKey

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try await store.save(key, for: .anthropic) }
            }
            try await group.waitForAll()
        }

        XCTAssertEqual(slow.calls, 8)
        XCTAssertEqual(slow.mostAtOnce, 1)
    }

    /// Fails unless `operation` throws `expected`.
    private func assertThrows<Value>(_ operation: @autoclosure () async throws -> Value, _ expected: CredentialError,
                                     _ message: String = "", file: StaticString = #filePath,
                                     line: UInt = #line) async {
        do {
            _ = try await operation()
            XCTFail("No error; expected \(expected). \(message)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CredentialError, expected, message, file: file, line: line)
        }
    }
}

/// A keychain held in memory, which records what it was asked and whether on the main thread. It finds only items named
/// as Keeptide's are, by their class and service as well as their identifier, as the keychain would find nothing else;
/// `answer(_:data:to:)` makes the next call of one kind give what the test chooses.
private final class KeychainStandIn: Keychain, @unchecked Sendable {
    enum Call { case add, copy, delete }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var forced: [Call: (status: OSStatus, data: Data?)] = [:]
    private var recordedAdds: [[String: Any]] = []
    private var recordedQueries: [[String: Any]] = []
    private var recordedDeletes: [[String: Any]] = []
    private var recordedThreads: [Bool] = []

    var added: [[String: Any]] { lock.withLock { recordedAdds } }
    var queried: [[String: Any]] { lock.withLock { recordedQueries } }
    var deleted: [[String: Any]] { lock.withLock { recordedDeletes } }
    var onMainThread: [Bool] { lock.withLock { recordedThreads } }

    func answer(_ status: OSStatus, data: Data? = nil, to call: Call) {
        lock.withLock { forced[call] = (status, data) }
    }

    func add(_ item: [String: Any]) -> OSStatus {
        lock.withLock {
            recordedAdds.append(item)
            recordedThreads.append(Thread.isMainThread)
            if let answer = forced.removeValue(forKey: .add) { return answer.status }
            guard let account = Self.account(item) else { return errSecParam }
            guard items[account] == nil else { return errSecDuplicateItem }
            items[account] = item[kSecValueData as String] as? Data
            return errSecSuccess
        }
    }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) {
        lock.withLock {
            recordedQueries.append(query)
            recordedThreads.append(Thread.isMainThread)
            if let answer = forced.removeValue(forKey: .copy) { return answer }
            guard let account = Self.account(query) else { return (errSecParam, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func delete(matching query: [String: Any]) -> OSStatus {
        lock.withLock {
            recordedDeletes.append(query)
            recordedThreads.append(Thread.isMainThread)
            if let answer = forced.removeValue(forKey: .delete) { return answer.status }
            guard let account = Self.account(query) else { return errSecParam }
            return items.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    /// The identifier of the item `query` names, if it names one as Keeptide's are named.
    private static func account(_ query: [String: Any]) -> String? {
        guard query[kSecClass as String] as? String == kSecClassGenericPassword as String,
              query[kSecAttrService as String] as? String == KeychainCredentialStore.service else { return nil }
        return query[kSecAttrAccount as String] as? String
    }
}

/// A keychain whose every call takes a moment, which records how many calls were under way at once.
private final class SlowKeychain: Keychain, @unchecked Sendable {
    private let lock = NSLock()
    private var underWay = 0
    private var most = 0
    private var count = 0

    var mostAtOnce: Int { lock.withLock { most } }
    var calls: Int { lock.withLock { count } }

    func add(_ item: [String: Any]) -> OSStatus { take { errSecSuccess } }

    func copyData(matching query: [String: Any]) -> (status: OSStatus, data: Data?) { take { (errSecItemNotFound, nil) } }

    func delete(matching query: [String: Any]) -> OSStatus { take { errSecSuccess } }

    private func take<Value>(_ answer: () -> Value) -> Value {
        lock.withLock {
            underWay += 1
            count += 1
            most = max(most, underWay)
        }
        Thread.sleep(forTimeInterval: 0.005)
        lock.withLock { underWay -= 1 }
        return answer()
    }
}
