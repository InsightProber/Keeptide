import Foundation

enum SearchScope: String, Sendable {
    case all, history, memo
}

enum CollectionFilter: Equatable, Sendable {
    case uncategorized
    case collection(CollectionID)
}

enum SearchMatchField: String, Hashable, Sendable {
    case title, body, url, note
}

enum SearchRelevance: Int, Comparable, Sendable {
    case exactMatch, titlePrefix, titleContainsAll, contiguousPhrase, allTermsAnywhere

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

enum SearchIndexState: String, Sendable {
    case ready, updating, rebuilding, unavailable
}

enum SearchError: Error, Equatable {
    case invalidRequest
}

struct SearchRequest: Sendable {
    /// Literal text; never interpreted as SQL or FTS syntax.
    var query: String
    var scope: SearchScope = .all
    var kinds: Set<ContentKind> = []
    /// Collections hold memos only, so any collection filter searches memos.
    var collection: CollectionFilter?
    var sourceApp: String?
    var generation: UInt64
    var offset = 0
    var limit = 200
}

struct SearchSnippet: Equatable, Sendable {
    let text: String
    /// UTF-16 offsets into `text`.
    let highlights: [Range<Int>]
}

struct SearchResult: Equatable, Sendable {
    /// The only identity an action may use; re-validate before acting.
    let ref: ContentRef
    let title: String
    let snippet: SearchSnippet?
    let matchedFields: Set<SearchMatchField>
    let relevance: SearchRelevance
    let kind: ContentKind
    let sourceApp: String?
    let lastCopiedAt: Date
    let savedAsMemo: Bool
    let isPartiallyIndexed: Bool
}

struct SearchPage: Sendable {
    let generation: UInt64
    /// The `[offset, offset + limit)` window of the full ranking.
    let results: [SearchResult]
    let totalMatches: Int
    /// True once every candidate in the index has been ranked.
    let isComplete: Bool
    let indexState: SearchIndexState
}

final class SearchIndexStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var current: SearchIndexState
    private var readFailureHandler: (@Sendable () -> Void)?

    init(_ state: SearchIndexState = .updating) {
        current = state
    }

    var state: SearchIndexState { lock.withLock { current } }

    func update(_ state: SearchIndexState) {
        lock.withLock { current = state }
    }

    func setReadFailureHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { readFailureHandler = handler }
    }

    func reportReadFailure() {
        lock.withLock { readFailureHandler }?()
    }
}

struct SearchService: Sendable {
    private let index: SQLiteSearchIndex?
    private let status: SearchIndexStatus
    private let scanChunkSize: Int

    /// `index` is nil when the index could not be created; searches then report `.unavailable`.
    init(index: SQLiteSearchIndex?, status: SearchIndexStatus, scanChunkSize: Int = 8_192) {
        self.index = index
        self.status = status
        self.scanChunkSize = scanChunkSize
    }

    func search(_ request: SearchRequest) -> AsyncThrowingStream<SearchPage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await execute(request) { continuation.yield($0) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func execute(_ request: SearchRequest, emit: (SearchPage) -> Void) async throws {
        guard (1...1_000).contains(request.limit), request.offset >= 0 else { throw SearchError.invalidRequest }
        let unavailable = SearchPage(generation: request.generation, results: [], totalMatches: 0,
                                     isComplete: true, indexState: .unavailable)
        guard let index, let reader = try? index.openReader() else {
            emit(unavailable)
            return
        }
        defer { reader.close() }
        let query = ParsedQuery(request.query)
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if query.isEmpty {
                    emit(try browse(request, reader))
                } else if query.longTerms.isEmpty {
                    try scan(query, request, reader, emit: emit)
                } else {
                    emit(try ranked(query, request, reader))
                }
            } onCancel: {
                reader.interrupt()
            }
        } catch let error as SearchIndexError {
            if error == .corrupt { status.reportReadFailure() }
            emit(unavailable)
        }
    }

    private func browse(_ request: SearchRequest, _ reader: SearchIndexReader) throws -> SearchPage {
        let query = ParsedQuery("")
        var counter = SQLBuilder()
        let countConditions = conditions(query, request, &counter)
        let total = try count(reader.rows("SELECT count(*) FROM doc d WHERE \(countConditions)", counter.bindings))
        var builder = SQLBuilder()
        let filter = conditions(query, request, &builder)
        let limit = builder.bind(.integer(Int64(request.limit)))
        let offset = builder.bind(.integer(Int64(request.offset)))
        let rows = try reader.rows("""
            SELECT d.id FROM doc d WHERE \(filter)
            ORDER BY d.last_copied_at DESC, d.item_id, d.facet LIMIT \(limit) OFFSET \(offset)
            """, builder.bindings)
        let keys = try rows.map { row -> (id: Int64, tier: Int64) in
            guard case .integer(let id) = row[0] else { throw SearchIndexError.corrupt }
            return (id, Int64(SearchRelevance.allTermsAnywhere.rawValue))
        }
        return page(request, try results(for: keys, query: query, reader), total: total, complete: true)
    }

    private func ranked(_ query: ParsedQuery, _ request: SearchRequest, _ reader: SearchIndexReader) throws -> SearchPage {
        var counter = SQLBuilder()
        let countConditions = conditions(query, request, &counter)
        let total = try count(reader.rows("SELECT count(*) FROM doc d WHERE \(countConditions)", counter.bindings))
        var builder = SQLBuilder()
        let tier = relevance(query, &builder)
        let filter = conditions(query, request, &builder)
        let limit = builder.bind(.integer(Int64(request.limit)))
        let offset = builder.bind(.integer(Int64(request.offset)))
        let rows = try reader.rows("""
            SELECT d.id, \(tier) AS tier, COALESCE(u.use_count, 0) AS uses, COALESCE(u.last_used_at, 0) AS used
            FROM doc d LEFT JOIN usage u ON u.item_id = d.item_id AND u.facet = d.facet
            WHERE \(filter)
            ORDER BY tier, uses DESC, used DESC, d.last_copied_at DESC, d.item_id, d.facet
            LIMIT \(limit) OFFSET \(offset)
            """, builder.bindings)
        let keys = try rows.map { row -> (id: Int64, tier: Int64) in
            guard case .integer(let id) = row[0], case .integer(let tier) = row[1] else {
                throw SearchIndexError.corrupt
            }
            return (id, tier)
        }
        return page(request, try results(for: keys, query: query, reader), total: total, complete: true)
    }

    /// Terms shorter than three scalars cannot use the trigram index, so every
    /// row is checked in id ranges. The first batch is published as soon as the
    /// first range is done; the final page is complete.
    private func scan(
        _ query: ParsedQuery, _ request: SearchRequest, _ reader: SearchIndexReader, emit: (SearchPage) -> Void
    ) throws {
        guard case .integer(let maximum)? = try reader.rows("SELECT max(id) FROM doc", []).first?.first else {
            emit(page(request, [], total: 0, complete: true))
            return
        }
        var keys: [RankKey] = []
        var lower: Int64 = 0
        var lastEmission: ContinuousClock.Instant?
        var lastWindow: [Int64] = []
        while lower < maximum {
            try Task.checkCancellation()
            let upper = min(maximum, lower + Int64(scanChunkSize))
            var builder = SQLBuilder()
            let tier = relevance(query, &builder)
            let filter = conditions(query, request, &builder)
            let low = builder.bind(.integer(lower))
            let high = builder.bind(.integer(upper))
            let rows = try reader.rows("""
                SELECT d.id, \(tier), COALESCE(u.use_count, 0), COALESCE(u.last_used_at, 0),
                       d.last_copied_at, d.item_id, d.facet
                FROM doc d LEFT JOIN usage u ON u.item_id = d.item_id AND u.facet = d.facet
                WHERE d.id > \(low) AND d.id <= \(high) AND \(filter)
                """, builder.bindings)
            keys += try rows.map(RankKey.init(row:))
            lower = upper
            let complete = lower >= maximum
            let now = ContinuousClock.now
            guard complete || lastEmission.map({ now - $0 >= .milliseconds(100) }) ?? true else { continue }
            keys.sort(by: RankKey.precedes)
            let window = Array(keys.dropFirst(request.offset).prefix(request.limit))
            guard complete || lastEmission == nil || window.map(\.id) != lastWindow else { continue }
            let results = try results(for: window.map { (id: $0.id, tier: $0.tier) }, query: query, reader)
            emit(page(request, results, total: keys.count, complete: complete))
            lastEmission = now
            lastWindow = window.map(\.id)
        }
    }

    private func page(_ request: SearchRequest, _ results: [SearchResult], total: Int, complete: Bool) -> SearchPage {
        SearchPage(generation: request.generation, results: results, totalMatches: total,
                   isComplete: complete, indexState: status.state)
    }

    private func count(_ rows: [[SQLiteValue]]) throws -> Int {
        guard case .integer(let total)? = rows.first?.first else { throw SearchIndexError.corrupt }
        return Int(total)
    }

    /// Filters shared by counting, ranking and scanning. Every value is bound.
    private func conditions(_ query: ParsedQuery, _ request: SearchRequest, _ builder: inout SQLBuilder) -> String {
        var conditions: [String] = []
        switch request.collection == nil ? request.scope : .memo {
        case .all: conditions.append("d.merged = 0")
        case .history: conditions.append("d.facet = 'history'")
        case .memo: conditions.append("d.facet = 'memo'")
        }
        switch request.collection {
        case .collection(let id)?: conditions.append("d.collection_id = \(builder.bind(.text(id.rawValue.uuidString)))")
        case .uncategorized?: conditions.append("d.collection_id IS NULL")
        case nil: break
        }
        if !request.kinds.isEmpty {
            let kinds = request.kinds.map(\.rawValue).sorted().map { builder.bind(.text($0)) }
            conditions.append("d.kind IN (\(kinds.joined(separator: ", ")))")
        }
        if let sourceApp = request.sourceApp {
            conditions.append("d.source_app = \(builder.bind(.text(sourceApp)))")
        }
        if let expression = query.ftsExpression {
            conditions.append("d.id IN (SELECT rowid FROM doc_fts WHERE doc_fts MATCH \(builder.bind(.text(expression))))")
        }
        for term in query.shortTerms {
            let value = builder.bind(.text(term))
            conditions.append(
                "(instr(d.n_title, \(value)) > 0 OR instr(d.n_body, \(value)) > 0 "
                    + "OR instr(d.n_url, \(value)) > 0 OR instr(d.n_note, \(value)) > 0)"
            )
        }
        return conditions.joined(separator: " AND ")
    }

    /// The tier of `SearchRelevance` for a matching row.
    private func relevance(_ query: ParsedQuery, _ builder: inout SQLBuilder) -> String {
        let phrase = builder.bind(.text(query.phrase))
        let titleHasAll = query.terms
            .map { "instr(d.n_title, \(builder.bind(.text($0)))) > 0" }
            .joined(separator: " AND ")
        return """
            CASE
                WHEN d.n_title = \(phrase) OR trim(d.n_body, ' ' || char(9, 10, 13)) = \(phrase) THEN 0
                WHEN substr(d.n_title, 1, length(\(phrase))) = \(phrase) THEN 1
                WHEN \(titleHasAll) THEN 2
                WHEN instr(d.n_title, \(phrase)) > 0 OR instr(d.n_body, \(phrase)) > 0
                     OR instr(d.n_url, \(phrase)) > 0 OR instr(d.n_note, \(phrase)) > 0 THEN 3
                ELSE 4
            END
            """
    }

    private func results(
        for keys: [(id: Int64, tier: Int64)], query: ParsedQuery, _ reader: SearchIndexReader
    ) throws -> [SearchResult] {
        guard !keys.isEmpty else { return [] }
        var builder = SQLBuilder()
        let terms = query.terms.map { builder.bind(.text($0)) }
        let hits = ["n_title", "n_body", "n_url", "n_note"].map { column in
            terms.isEmpty ? "0" : "(" + terms.map { "instr(d.\(column), \($0)) > 0" }.joined(separator: " OR ") + ")"
        }
        let longest = builder.bind(.text(query.terms.max { $0.unicodeScalars.count < $1.unicodeScalars.count } ?? ""))
        let ids = keys.map { builder.bind(.integer($0.id)) }.joined(separator: ", ")
        // The window starts near the first normalized match of the longest term;
        // length differences from folding are covered by the 200-character margin.
        let start = "max(1, instr(d.n_body, \(longest)) - 200)"
        let rows = try reader.rows("""
            SELECT d.id, d.item_id, d.facet, d.version, d.digest, d.saved_as_memo, d.kind, d.source_app,
                   d.last_copied_at, d.title, d.body_partial, \(hits.joined(separator: ", ")),
                   \(start), substr(d.body, \(start), 600), length(d.body)
            FROM doc d WHERE d.id IN (\(ids))
            """, builder.bindings)
        var byID: [Int64: SearchResult] = [:]
        let tiers = Dictionary(keys.map { ($0.id, $0.tier) }, uniquingKeysWith: { first, _ in first })
        for row in rows {
            guard row.count == 18, case .integer(let id) = row[0], let itemID = row[1].uuid,
                  case .text(let facetText) = row[2], let facet = ContentFacet(rawValue: facetText),
                  let version = row[3].uuid, case .blob(let digest) = row[4],
                  case .integer(let savedAsMemo) = row[5], case .text(let kindText) = row[6],
                  let kind = ContentKind(rawValue: kindText), case .real(let copiedAt) = row[8],
                  case .text(let title) = row[9], case .integer(let partial) = row[10],
                  case .integer(let windowStart) = row[15], case .text(let window) = row[16],
                  case .integer(let bodyLength) = row[17] else {
                throw SearchIndexError.corrupt
            }
            let fields: [SearchMatchField] = [.title, .body, .url, .note]
            let matched = Set(zip(fields, row[11...14]).compactMap { field, value in
                value == .integer(1) ? field : nil
            })
            byID[id] = SearchResult(
                ref: ContentRef(itemID: ItemID(rawValue: itemID), facet: facet,
                                version: ContentVersion(rawValue: version), digest: digest),
                title: title,
                snippet: Self.snippet(window: window, windowStart: Int(windowStart), bodyLength: Int(bodyLength),
                                      terms: query.terms),
                matchedFields: matched,
                relevance: SearchRelevance(rawValue: Int(tiers[id] ?? 4)) ?? .allTermsAnywhere,
                kind: kind, sourceApp: row[7].text,
                lastCopiedAt: Date(timeIntervalSinceReferenceDate: copiedAt),
                savedAsMemo: savedAsMemo != 0, isPartiallyIndexed: partial != 0
            )
        }
        return keys.compactMap { byID[$0.id] }
    }

    private static let snippetOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// Builds the display snippet from original text. `windowStart` and
    /// `bodyLength` are SQLite character positions in the stored body.
    static func snippet(window: String, windowStart: Int, bodyLength: Int, terms: [String]) -> SearchSnippet? {
        let match = terms.sorted { $0.unicodeScalars.count > $1.unicodeScalars.count }
            .lazy.compactMap { window.range(of: $0, options: snippetOptions) }.first
        guard let match else {
            let line = window.split(whereSeparator: \.isNewline)
                .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty }
            return line.map { SearchSnippet(text: String($0.prefix(160)), highlights: []) }
        }
        let start = window.index(match.lowerBound, offsetBy: -40, limitedBy: window.startIndex) ?? window.startIndex
        let end = window.index(start, offsetBy: 160, limitedBy: window.endIndex) ?? window.endIndex
        let leading = windowStart > 1 || start > window.startIndex
        let trailing = end < window.endIndex || windowStart - 1 + window.unicodeScalars.count < bodyLength
        let text = (leading ? "…" : "") + window[start..<end] + (trailing ? "…" : "")
        return SearchSnippet(text: text, highlights: highlights(in: text, terms: terms))
    }

    private static func highlights(in text: String, terms: [String]) -> [Range<Int>] {
        let string = text as NSString
        var ranges: [Range<Int>] = []
        for term in terms where !term.isEmpty {
            var searchRange = NSRange(location: 0, length: string.length)
            while true {
                let found = string.range(of: term, options: snippetOptions, range: searchRange)
                guard found.location != NSNotFound, found.length > 0 else { break }
                ranges.append(found.location..<(found.location + found.length))
                let next = found.location + found.length
                searchRange = NSRange(location: next, length: string.length - next)
            }
        }
        var merged: [Range<Int>] = []
        for range in ranges.sorted(by: { ($0.lowerBound, -$0.count) < ($1.lowerBound, -$1.count) })
        where merged.last.map({ range.lowerBound >= $0.upperBound }) ?? true {
            merged.append(range)
        }
        return merged
    }
}

/// Builds numbered SQL parameters (`?1`, `?2`, …) so one value can be reused.
private struct SQLBuilder {
    private(set) var bindings: [SQLiteValue] = []

    mutating func bind(_ value: SQLiteValue) -> String {
        bindings.append(value)
        return "?\(bindings.count)"
    }
}

/// The ranking key; must order exactly like the SQL `ORDER BY` in `ranked`.
private struct RankKey {
    let id: Int64
    let tier: Int64
    let uses: Int64
    let lastUsed: Double
    let lastCopied: Double
    let itemID: String
    let facet: String

    init(row: [SQLiteValue]) throws {
        guard row.count == 7, case .integer(let id) = row[0], case .integer(let tier) = row[1],
              case .integer(let uses) = row[2], let lastUsed = row[3].number, let lastCopied = row[4].number,
              case .text(let itemID) = row[5], case .text(let facet) = row[6] else {
            throw SearchIndexError.corrupt
        }
        self.id = id
        self.tier = tier
        self.uses = uses
        self.lastUsed = lastUsed
        self.lastCopied = lastCopied
        self.itemID = itemID
        self.facet = facet
    }

    static func precedes(_ lhs: RankKey, _ rhs: RankKey) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.uses != rhs.uses { return lhs.uses > rhs.uses }
        if lhs.lastUsed != rhs.lastUsed { return lhs.lastUsed > rhs.lastUsed }
        if lhs.lastCopied != rhs.lastCopied { return lhs.lastCopied > rhs.lastCopied }
        if lhs.itemID != rhs.itemID { return lhs.itemID < rhs.itemID }
        return lhs.facet < rhs.facet
    }
}

private extension SQLiteValue {
    var number: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        default: nil
        }
    }
}
