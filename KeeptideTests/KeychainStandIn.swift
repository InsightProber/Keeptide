import Foundation
import Security
@testable import Keeptide

/// A keychain held in memory, which records what it was asked and whether on the main thread. It finds only items named
/// as Keeptide's are, by their class and service as well as their identifier, as the keychain would find nothing else;
/// `answer(_:data:to:)` makes the next call of one kind give what the test chooses.
final class KeychainStandIn: Keychain, @unchecked Sendable {
    enum Call { case add, copy, delete }

    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var forced: [Call: (status: OSStatus, data: Data?)] = [:]
    private var recordedAdds: [[String: Any]] = []
    private var recordedQueries: [[String: Any]] = []
    private var recordedDeletes: [[String: Any]] = []
    private var recordedThreads: [Bool] = []
    private var meanwhileCopying: (@Sendable () -> Void)?
    private var meanwhileAdding: (@Sendable () -> Void)?
    private var meanwhileDeleting: (@Sendable () -> Void)?

    var added: [[String: Any]] { lock.withLock { recordedAdds } }
    var queried: [[String: Any]] { lock.withLock { recordedQueries } }
    var deleted: [[String: Any]] { lock.withLock { recordedDeletes } }
    var onMainThread: [Bool] { lock.withLock { recordedThreads } }

    func answer(_ status: OSStatus, data: Data? = nil, to call: Call) {
        lock.withLock { forced[call] = (status, data) }
    }

    /// Runs `action` as the next item is read, before it is given; once.
    func whileCopying(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { meanwhileCopying = action }
    }

    /// Runs `action` as the next item is added, before it is; once.
    func whileAdding(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { meanwhileAdding = action }
    }

    /// Runs `action` as the next item is deleted, before it is; once.
    func whileDeleting(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { meanwhileDeleting = action }
    }

    func add(_ item: [String: Any]) -> OSStatus {
        lock.withLock { () -> (@Sendable () -> Void)? in
            defer { meanwhileAdding = nil }
            return meanwhileAdding
        }?()
        return lock.withLock {
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
        lock.withLock { () -> (@Sendable () -> Void)? in
            defer { meanwhileCopying = nil }
            return meanwhileCopying
        }?()
        return lock.withLock {
            recordedQueries.append(query)
            recordedThreads.append(Thread.isMainThread)
            if let answer = forced.removeValue(forKey: .copy) { return answer }
            guard let account = Self.account(query) else { return (errSecParam, nil) }
            guard let data = items[account] else { return (errSecItemNotFound, nil) }
            return (errSecSuccess, data)
        }
    }

    func delete(matching query: [String: Any]) -> OSStatus {
        lock.withLock { () -> (@Sendable () -> Void)? in
            defer { meanwhileDeleting = nil }
            return meanwhileDeleting
        }?()
        return lock.withLock {
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
