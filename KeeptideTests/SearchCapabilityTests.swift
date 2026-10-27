import Foundation
import SQLite3
import XCTest

/// Runs on every CI image, so it is the record of what the minimum supported
/// macOS ships: FTS5 with the trigram tokenizer over an external content table.
final class SearchCapabilityTests: XCTestCase {
    @MainActor
    func testSystemSQLiteProvidesTrigramExternalContentFTS5() throws {
        let version = String(cString: sqlite3_libversion())
        XCTContext.runActivity(named: "System SQLite \(version)") { activity in
            activity.add(XCTAttachment(string: "sqlite3_libversion=\(version)"))
        }
        XCTAssertGreaterThanOrEqual(sqlite3_libversion_number(), 3_034_000)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(":memory:", &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        for statement in [
            "CREATE TABLE doc(id INTEGER PRIMARY KEY, t TEXT NOT NULL)",
            "CREATE VIRTUAL TABLE fts USING fts5(t, content='doc', content_rowid='id', tokenize='trigram case_sensitive 1')",
            "INSERT INTO doc(id, t) VALUES (1, '中文剪贴板历史')",
            "INSERT INTO fts(rowid, t) VALUES (1, '中文剪贴板历史')",
        ] {
            XCTAssertEqual(sqlite3_exec(database, statement, nil, nil, nil), SQLITE_OK, statement)
        }

        var query: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT rowid FROM fts WHERE fts MATCH '\"剪贴板\"'", -1, &query, nil), SQLITE_OK)
        defer { sqlite3_finalize(query) }
        XCTAssertEqual(sqlite3_step(query), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(query, 0), 1)
        XCTAssertEqual(sqlite3_step(query), SQLITE_DONE)
    }
}
