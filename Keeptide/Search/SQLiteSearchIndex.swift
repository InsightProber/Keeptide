import Foundation
import SQLite3

enum SearchIndexError: Error, Equatable {
    case corrupt
    case unavailable(code: Int32)
    case closed
}

enum IndexBuildState: String, Sendable {
    case building, ready
}

enum CheckpointUpdate: Sendable {
    case keep
    case set(Data?)
}

enum SQLiteValue: Equatable, Sendable {
    case integer(Int64), real(Double), text(String), blob(Data), null
}

struct SearchIndexMetadata: Equatable, Sendable {
    var schemaVersion: Int
    var normalizerVersion: Int
    var extractorVersion: Int
    var tokenizer: String
    var identity: StoreIdentity
    var checkpoint: Data?
    var state: IndexBuildState

    func isUsable(for identity: StoreIdentity) -> Bool {
        schemaVersion == SQLiteSearchIndex.schemaVersion
            && normalizerVersion == SearchNormalizer.version
            && extractorVersion == SearchDocumentBuilder.extractorVersion
            && tokenizer == SQLiteSearchIndex.tokenizer
            && self.identity == identity
            && state == .ready
    }
}

/// Replaces every document of one item. An empty list removes the item.
struct IndexedItemChange: Sendable {
    let itemID: ItemID
    let documents: [SearchDocument]
}

/// The derived full-text index. It lives in its own SQLite file, can be deleted
/// at any time, and is rebuilt from Core Data. One lock-guarded writer
/// connection; every search opens its own reader.
final class SQLiteSearchIndex: @unchecked Sendable {
    static let schemaVersion = 1
    static let tokenizer = "trigram case_sensitive 1"
    static let fileName = "Search.sqlite"

    let directory: URL
    private let lock = NSLock()
    private var connection: SQLiteConnection?
    /// Why there is no connection: `.corrupt` waits for `reset`; any other
    /// failure is retried by reopening on the next call. Nil after `close()`.
    private var openFailure: SearchIndexError?

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        do {
            connection = try Self.openWriter(at: directory.appendingPathComponent(Self.fileName))
        } catch SearchIndexError.corrupt {
            openFailure = .corrupt
        }
    }

    /// Nil when the file has no complete metadata, which callers treat as "rebuild".
    func metadata() throws -> SearchIndexMetadata? {
        try withConnection { database in
            let hasMeta = try database.rows(
                "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'", []
            )
            guard !hasMeta.isEmpty else { return nil }
            var values: [String: SQLiteValue] = [:]
            for row in try database.rows("SELECT key, value FROM meta", []) {
                if case .text(let key) = row[0] { values[key] = row[1] }
            }
            guard case .integer(let schema)? = values["schemaVersion"],
                  case .integer(let normalizer)? = values["normalizerVersion"],
                  case .integer(let extractor)? = values["extractorVersion"],
                  case .text(let tokenizer)? = values["tokenizer"],
                  case .text(let storeText)? = values["storeID"], let storeID = UUID(uuidString: storeText),
                  case .text(let generationText)? = values["generation"],
                  let generation = UUID(uuidString: generationText),
                  case .text(let stateText)? = values["state"], let state = IndexBuildState(rawValue: stateText),
                  let checkpointValue = values["checkpoint"] else { return nil }
            let checkpoint: Data?
            switch checkpointValue {
            case .blob(let data): checkpoint = data
            case .null: checkpoint = nil
            default: return nil
            }
            return SearchIndexMetadata(
                schemaVersion: Int(schema), normalizerVersion: Int(normalizer), extractorVersion: Int(extractor),
                tokenizer: tokenizer, identity: StoreIdentity(storeID: storeID, generation: generation),
                checkpoint: checkpoint, state: state
            )
        }
    }

    /// Deletes only this index's own files and starts an empty build.
    func reset(identity: StoreIdentity) throws {
        try lock.withLock {
            connection?.close()
            connection = nil
            let database: SQLiteConnection
            do {
                for suffix in ["", "-wal", "-shm"] {
                    let url = directory.appendingPathComponent(Self.fileName + suffix)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                }
                database = try Self.openWriter(at: fileURL)
            } catch {
                openFailure = .unavailable(code: SQLITE_CANTOPEN)
                throw error
            }
            connection = database
            openFailure = nil
            try database.transaction {
                for statement in Self.schema { try database.execute(statement) }
                let meta: [(String, SQLiteValue)] = [
                    ("schemaVersion", .integer(Int64(Self.schemaVersion))),
                    ("normalizerVersion", .integer(Int64(SearchNormalizer.version))),
                    ("extractorVersion", .integer(Int64(SearchDocumentBuilder.extractorVersion))),
                    ("tokenizer", .text(Self.tokenizer)),
                    ("storeID", .text(identity.storeID.uuidString)),
                    ("generation", .text(identity.generation.uuidString)),
                    ("state", .text(IndexBuildState.building.rawValue)),
                    ("checkpoint", .null),
                ]
                for (key, value) in meta {
                    try database.run("INSERT INTO meta(key, value) VALUES (?, ?)", [.text(key), value])
                }
            }
        }
    }

    /// Applies item replacements and the optional checkpoint in one transaction.
    /// An item whose stored projection came from a later history sequence is left alone.
    func apply(_ changes: [IndexedItemChange], sequence: Int64, checkpoint: CheckpointUpdate) throws {
        try withConnection { database in
            try database.transaction {
                for change in changes {
                    let item = SQLiteValue.text(change.itemID.rawValue.uuidString)
                    let newest = try database.rows("SELECT max(projected_seq) FROM doc WHERE item_id = ?", [item])
                    if case .integer(let stored)? = newest.first?.first, stored > sequence { continue }
                    try database.run("DELETE FROM doc WHERE item_id = ?", [item])
                    for document in change.documents where document.ref.itemID == change.itemID {
                        try database.run(Self.insertDocument, Self.values(for: document, sequence: sequence))
                    }
                }
                if case .set(let token) = checkpoint {
                    try database.run(
                        "INSERT OR REPLACE INTO meta(key, value) VALUES ('checkpoint', ?)",
                        [token.map(SQLiteValue.blob) ?? .null]
                    )
                }
            }
        }
    }

    func finishBuild(checkpoint: Data?) throws {
        try withConnection { database in
            try database.transaction {
                try database.run(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES ('checkpoint', ?)",
                    [checkpoint.map(SQLiteValue.blob) ?? .null]
                )
                try database.run(
                    "INSERT OR REPLACE INTO meta(key, value) VALUES ('state', ?)",
                    [.text(IndexBuildState.ready.rawValue)]
                )
            }
        }
    }

    /// Items whose indexed documents reference any of these capture or memo IDs.
    func itemIDs(referencing ids: Set<UUID>) throws -> Set<ItemID> {
        guard !ids.isEmpty else { return [] }
        let values = ids.map { SQLiteValue.text($0.uuidString) }
        return try withConnection { database in
            var result = Set<ItemID>()
            for start in stride(from: 0, to: values.count, by: 400) {
                let chunk = Array(values[start..<min(start + 400, values.count)])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
                let rows = try database.rows(
                    "SELECT DISTINCT item_id FROM doc WHERE capture_id IN (\(placeholders)) OR memo_id IN (\(placeholders))",
                    chunk + chunk
                )
                for row in rows {
                    guard case .text(let text) = row[0], let id = UUID(uuidString: text) else {
                        throw SearchIndexError.corrupt
                    }
                    result.insert(ItemID(rawValue: id))
                }
            }
            return result
        }
    }

    func replaceUsage(_ summaries: [UsageSummary]) throws {
        try withConnection { database in
            try database.transaction {
                try database.run("DELETE FROM usage", [])
                for summary in summaries {
                    try database.run(
                        "INSERT OR REPLACE INTO usage(item_id, facet, last_used_at, use_count) VALUES (?, ?, ?, ?)",
                        [.text(summary.itemID.rawValue.uuidString), .text(summary.facet.rawValue),
                         .real(summary.lastUsedAt.timeIntervalSinceReferenceDate), .integer(summary.useCount)]
                    )
                }
            }
        }
    }

    func allDocuments() throws -> [SearchDocument] {
        try withConnection { database in
            try database.rows("SELECT \(Self.documentColumns) FROM doc ORDER BY item_id, facet", [])
                .map(Self.document(from:))
        }
    }

    func integrityCheck() throws {
        try withConnection { database in
            try database.run("INSERT INTO doc_fts(doc_fts, rank) VALUES ('integrity-check', 1)", [])
        }
    }

    func openReader() throws -> SearchIndexReader {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw SearchIndexError.unavailable(code: SQLITE_CANTOPEN)
        }
        let database = try SQLiteConnection(
            path: fileURL.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        )
        do {
            try database.execute("PRAGMA query_only = 1")
            return SearchIndexReader(connection: database)
        } catch {
            database.close()
            throw error
        }
    }

    func close() {
        lock.withLock {
            connection?.close()
            connection = nil
            openFailure = nil
        }
    }

    private func withConnection<T>(_ body: (SQLiteConnection) throws -> T) throws -> T {
        try lock.withLock {
            if connection == nil, let failure = openFailure, failure != .corrupt {
                do {
                    connection = try Self.openWriter(at: fileURL)
                    openFailure = nil
                } catch SearchIndexError.corrupt {
                    openFailure = .corrupt
                    throw SearchIndexError.corrupt
                }
            }
            guard let connection else { throw openFailure ?? SearchIndexError.closed }
            return try body(connection)
        }
    }

    private static func openWriter(at url: URL) throws -> SQLiteConnection {
        let database = try SQLiteConnection(
            path: url.path, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        )
        do {
            _ = try database.rows("PRAGMA journal_mode = WAL", [])
            try database.execute("PRAGMA synchronous = NORMAL")
            return database
        } catch {
            database.close()
            throw error
        }
    }

    static let documentColumns = """
        item_id, facet, version, digest, capture_id, memo_id, merged, saved_as_memo, kind, source_app, \
        collection_id, last_copied_at, title, body, url, note, n_title, n_body, n_url, n_note, \
        body_partial, text_unavailable
        """

    private static let insertDocument = """
        INSERT INTO doc(\(documentColumns), projected_seq) \
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """

    private static let schema = [
        "CREATE TABLE meta(key TEXT PRIMARY KEY, value) WITHOUT ROWID",
        """
        CREATE TABLE doc(
            id INTEGER PRIMARY KEY,
            item_id TEXT NOT NULL, facet TEXT NOT NULL, version TEXT NOT NULL, digest BLOB NOT NULL,
            capture_id TEXT, memo_id TEXT, merged INTEGER NOT NULL, saved_as_memo INTEGER NOT NULL,
            kind TEXT NOT NULL, source_app TEXT, collection_id TEXT, last_copied_at REAL NOT NULL,
            title TEXT NOT NULL, body TEXT NOT NULL, url TEXT NOT NULL, note TEXT NOT NULL,
            n_title TEXT NOT NULL, n_body TEXT NOT NULL, n_url TEXT NOT NULL, n_note TEXT NOT NULL,
            body_partial INTEGER NOT NULL, text_unavailable INTEGER NOT NULL, projected_seq INTEGER NOT NULL,
            UNIQUE(item_id, facet)
        )
        """,
        "CREATE INDEX doc_capture ON doc(capture_id) WHERE capture_id IS NOT NULL",
        "CREATE INDEX doc_memo ON doc(memo_id) WHERE memo_id IS NOT NULL",
        "CREATE INDEX doc_recent ON doc(last_copied_at)",
        """
        CREATE VIRTUAL TABLE doc_fts USING fts5(
            n_title, n_body, n_url, n_note, content='doc', content_rowid='id', tokenize='\(tokenizer)'
        )
        """,
        """
        CREATE TRIGGER doc_ai AFTER INSERT ON doc BEGIN
            INSERT INTO doc_fts(rowid, n_title, n_body, n_url, n_note)
            VALUES (new.id, new.n_title, new.n_body, new.n_url, new.n_note);
        END
        """,
        """
        CREATE TRIGGER doc_ad AFTER DELETE ON doc BEGIN
            INSERT INTO doc_fts(doc_fts, rowid, n_title, n_body, n_url, n_note)
            VALUES ('delete', old.id, old.n_title, old.n_body, old.n_url, old.n_note);
        END
        """,
        """
        CREATE TRIGGER doc_au AFTER UPDATE ON doc BEGIN
            INSERT INTO doc_fts(doc_fts, rowid, n_title, n_body, n_url, n_note)
            VALUES ('delete', old.id, old.n_title, old.n_body, old.n_url, old.n_note);
            INSERT INTO doc_fts(rowid, n_title, n_body, n_url, n_note)
            VALUES (new.id, new.n_title, new.n_body, new.n_url, new.n_note);
        END
        """,
        """
        CREATE TABLE usage(
            item_id TEXT NOT NULL, facet TEXT NOT NULL, last_used_at REAL NOT NULL, use_count INTEGER NOT NULL,
            PRIMARY KEY(item_id, facet)
        ) WITHOUT ROWID
        """,
    ]

    private static func values(for document: SearchDocument, sequence: Int64) -> [SQLiteValue] {
        [
            .text(document.ref.itemID.rawValue.uuidString), .text(document.ref.facet.rawValue),
            .text(document.ref.version.rawValue.uuidString), .blob(document.ref.digest),
            document.captureID.map { .text($0.uuidString) } ?? .null,
            document.memoID.map { .text($0.uuidString) } ?? .null,
            .integer(document.merged ? 1 : 0), .integer(document.savedAsMemo ? 1 : 0),
            .text(document.kind.rawValue), document.sourceApp.map(SQLiteValue.text) ?? .null,
            document.collectionID.map { .text($0.rawValue.uuidString) } ?? .null,
            .real(document.lastCopiedAt.timeIntervalSinceReferenceDate),
            .text(document.title), .text(document.body), .text(document.url), .text(document.note),
            .text(document.normalizedTitle), .text(document.normalizedBody),
            .text(document.normalizedURL), .text(document.normalizedNote),
            .integer(document.bodyPartial ? 1 : 0), .integer(document.textUnavailable ? 1 : 0),
            .integer(sequence),
        ]
    }

    /// Decodes a row selected with `documentColumns`.
    static func document(from row: [SQLiteValue]) throws -> SearchDocument {
        guard row.count == 22,
              let itemID = row[0].uuid, case .text(let facetText) = row[1],
              let facet = ContentFacet(rawValue: facetText), let version = row[2].uuid,
              case .blob(let digest) = row[3], case .integer(let merged) = row[6],
              case .integer(let savedAsMemo) = row[7], case .text(let kindText) = row[8],
              let kind = ContentKind(rawValue: kindText), case .real(let copiedAt) = row[11],
              case .text(let title) = row[12], case .text(let body) = row[13],
              case .text(let url) = row[14], case .text(let note) = row[15],
              case .text(let normalizedTitle) = row[16], case .text(let normalizedBody) = row[17],
              case .text(let normalizedURL) = row[18], case .text(let normalizedNote) = row[19],
              case .integer(let partial) = row[20], case .integer(let unavailable) = row[21] else {
            throw SearchIndexError.corrupt
        }
        return SearchDocument(
            ref: ContentRef(itemID: ItemID(rawValue: itemID), facet: facet,
                            version: ContentVersion(rawValue: version), digest: digest),
            captureID: row[4].uuid, memoID: row[5].uuid, merged: merged != 0, savedAsMemo: savedAsMemo != 0,
            kind: kind, sourceApp: row[9].text, collectionID: row[10].uuid.map(CollectionID.init(rawValue:)),
            lastCopiedAt: Date(timeIntervalSinceReferenceDate: copiedAt), title: title, body: body, url: url,
            note: note, bodyPartial: partial != 0, textUnavailable: unavailable != 0,
            normalizedTitle: normalizedTitle, normalizedBody: normalizedBody,
            normalizedURL: normalizedURL, normalizedNote: normalizedNote
        )
    }
}

/// A short-lived connection for one search. `interrupt()` may be called from any thread.
final class SearchIndexReader: @unchecked Sendable {
    private let connection: SQLiteConnection

    fileprivate init(connection: SQLiteConnection) {
        self.connection = connection
    }

    func rows(_ sql: String, _ bindings: [SQLiteValue]) throws -> [[SQLiteValue]] {
        try connection.rows(sql, bindings)
    }

    func interrupt() {
        connection.interrupt()
    }

    func close() {
        connection.close()
    }
}

extension SQLiteValue {
    var text: String? {
        if case .text(let value) = self { return value }
        return nil
    }

    var uuid: UUID? {
        text.flatMap(UUID.init(uuidString:))
    }
}

/// Thin SQLite wrapper. Not thread-safe except for `interrupt()`; owners serialize use.
final class SQLiteConnection: @unchecked Sendable {
    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private let handleLock = NSLock()
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(path: String, flags: Int32) throws {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(path, &database, flags, nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw Self.error(status)
        }
        sqlite3_extended_result_codes(database, 1)
        sqlite3_busy_timeout(database, 5_000)
        handle = database
    }

    func execute(_ sql: String) throws {
        let database = try open()
        let status = sqlite3_exec(database, sql, nil, nil, nil)
        guard status == SQLITE_OK else { throw Self.error(status) }
    }

    func rows(_ sql: String, _ bindings: [SQLiteValue]) throws -> [[SQLiteValue]] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        return try collect(statement, bindings)
    }

    /// Runs a statement through a per-connection cache of prepared statements.
    func run(_ sql: String, _ bindings: [SQLiteValue]) throws {
        let statement: OpaquePointer
        if let cached = statements[sql] {
            statement = cached
        } else {
            statement = try prepare(sql)
            statements[sql] = statement
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        _ = try collect(statement, bindings)
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func interrupt() {
        handleLock.withLock {
            if let handle { sqlite3_interrupt(handle) }
        }
    }

    func close() {
        handleLock.withLock {
            for statement in statements.values { sqlite3_finalize(statement) }
            statements.removeAll()
            if let handle { sqlite3_close_v2(handle) }
            handle = nil
        }
    }

    private func open() throws -> OpaquePointer {
        guard let handle = handleLock.withLock({ handle }) else { throw SearchIndexError.closed }
        return handle
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = try open()
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw Self.error(status)
        }
        return statement
    }

    private func collect(_ statement: OpaquePointer, _ bindings: [SQLiteValue]) throws -> [[SQLiteValue]] {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .integer(let integer): status = sqlite3_bind_int64(statement, index, integer)
            case .real(let real): status = sqlite3_bind_double(statement, index, real)
            case .text(let text):
                status = text.utf8CString.withUnsafeBufferPointer {
                    sqlite3_bind_text(statement, index, $0.baseAddress, Int32($0.count - 1), Self.transient)
                }
            case .blob(let data) where data.isEmpty: status = sqlite3_bind_zeroblob(statement, index, 0)
            case .blob(let data):
                status = data.withUnsafeBytes {
                    sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
                }
            case .null: status = sqlite3_bind_null(statement, index)
            }
            guard status == SQLITE_OK else { throw Self.error(status) }
        }
        var rows: [[SQLiteValue]] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return rows }
            guard status == SQLITE_ROW else { throw Self.error(status) }
            rows.append((0..<sqlite3_column_count(statement)).map { Self.value(statement, $0) })
        }
    }

    private static func value(_ statement: OpaquePointer, _ column: Int32) -> SQLiteValue {
        switch sqlite3_column_type(statement, column) {
        case SQLITE_INTEGER:
            return .integer(sqlite3_column_int64(statement, column))
        case SQLITE_FLOAT:
            return .real(sqlite3_column_double(statement, column))
        case SQLITE_TEXT:
            guard let pointer = sqlite3_column_text(statement, column) else { return .text("") }
            let count = Int(sqlite3_column_bytes(statement, column))
            return .text(String(decoding: UnsafeBufferPointer(start: pointer, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            guard let pointer = sqlite3_column_blob(statement, column) else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, column))))
        default:
            return .null
        }
    }

    static func error(_ status: Int32) -> Error {
        switch status & 0xFF {
        case SQLITE_CORRUPT, SQLITE_NOTADB: SearchIndexError.corrupt
        case SQLITE_INTERRUPT: CancellationError()
        default: SearchIndexError.unavailable(code: status & 0xFF)
        }
    }
}
