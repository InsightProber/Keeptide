import Foundation
@testable import Keeptide

/// Deterministic synthetic library for search correctness and measurement runs.
/// Mixes Chinese and English text, commands, prompts, URLs, images, inherited
/// and owned memos, deleted memos and removed history.
enum SearchFixtureLibrary {
    static let chinese = ["剪贴板", "历史", "命令", "提示词", "部署", "端口", "进程", "并发", "问题", "配置",
                          "日志", "备忘", "搜索", "中文", "短词", "索引", "恢复", "同步", "设计", "测试"]
    static let english = ["kubectl", "docker", "git", "status", "deploy", "port", "lsof", "swift", "review", "prompt",
                          "select", "from", "where", "build", "release", "cache", "error", "warning", "config", "server"]

    /// Expected visible references, keyed as in `key(_:)`.
    struct Manifest {
        var visible: Set<String> = []
    }

    static func key(_ ref: ContentRef) -> String {
        "\(ref.itemID.rawValue.uuidString)|\(ref.facet.rawValue)|\(ref.version.rawValue.uuidString)|"
            + ref.digest.map { String(format: "%02x", $0) }.joined()
    }

    static func count(environment key: String, default value: Int) -> Int {
        ProcessInfo.processInfo.environment[key].flatMap(Int.init) ?? value
    }

    static func populate(_ harness: SearchHarness, count: Int, seed: UInt64) async throws -> Manifest {
        var generator = SeededGenerator(seed: seed)
        var manifest = Manifest()
        var mutations: [StoreMutation] = []
        for index in 0..<count {
            let (capture, item, memo) = try makeItem(index, using: &generator)
            mutations += [.insert(.capture(capture))]
            if let memo { mutations.append(.insert(.memo(memo))) }
            mutations.append(.insert(.item(item)))
            if item.historyDeletedAt == nil {
                manifest.visible.insert(key(ContentRef(itemID: item.id, facet: .history,
                                                       version: ContentVersion(rawValue: capture.id), digest: capture.digest)))
            }
            if let memo, memo.deletedAt == nil {
                let ref = memo.bodyMode == .inheritedCapture
                    ? ContentRef(itemID: item.id, facet: .memo, version: ContentVersion(rawValue: capture.id), digest: capture.digest)
                    : ContentRef(itemID: item.id, facet: .memo, version: memo.version!, digest: memo.digest!)
                manifest.visible.insert(key(ref))
            }
            if mutations.count >= 600 || index == count - 1 {
                try await harness.commit(mutations)
                mutations.removeAll(keepingCapacity: true)
            }
        }
        return manifest
    }

    private static func makeItem(
        _ index: Int, using generator: inout SeededGenerator
    ) throws -> (CaptureValue, ItemValue, MemoValue?) {
        let roll = Int.random(in: 0..<100, using: &generator)
        let text: String
        var representations: [(String, Data)]
        switch roll % 5 {
        case 0:
            text = "lsof -i :\(Int.random(in: 1_000..<9_999, using: &generator)) \(word(english, &generator))"
            representations = [("public.utf8-plain-text", Data(text.utf8))]
        case 1:
            text = "https://example.com/\(word(english, &generator))/\(index)"
            representations = [("public.url", Data(text.utf8)), ("public.utf8-plain-text", Data(text.utf8))]
        case 2:
            text = (0..<Int.random(in: 3..<12, using: &generator)).map { _ in word(chinese, &generator) }.joined()
            representations = [("public.utf8-plain-text", Data(text.utf8))]
        case 3:
            text = (0..<Int.random(in: 4..<30, using: &generator)).map { offset in
                offset.isMultiple(of: 3) ? word(chinese, &generator) : word(english, &generator)
            }.joined(separator: " ")
            representations = [("public.utf8-plain-text", Data(text.utf8))]
        default:
            text = "Screenshot \(index)"
            let image = Data((0..<64).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
            representations = [("public.png", image), ("public.utf8-plain-text", Data(text.utf8))]
        }
        let capture = try ContentStoreFixtures.capture([representations])
        let itemID = ItemID()
        let copiedAt = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index))
        var memo: MemoValue?
        if roll < 10 {
            memo = MemoValue(itemID: itemID, title: "\(word(chinese, &generator)) \(word(english, &generator))",
                             bodyMode: .inheritedCapture, note: word(english, &generator))
        } else if roll < 22 {
            let body = Data("\(word(english, &generator)) \(word(chinese, &generator)) edited \(index)".utf8)
            memo = MemoValue(itemID: itemID, title: word(english, &generator), bodyMode: .ownedPlainText, body: body,
                             version: ContentVersion(), digest: ContentDigest.sha256(body),
                             note: word(chinese, &generator),
                             deletedAt: roll < 12 ? Date(timeIntervalSinceReferenceDate: 800_000_000) : nil)
        }
        let item = ItemValue(
            id: itemID, sourceApp: roll.isMultiple(of: 2) ? "com.apple.Terminal" : "com.apple.Safari",
            title: String(text.prefix(160)), captureID: capture.id, memoID: memo?.id, historyEligible: true,
            historyDeletedAt: (22..<24).contains(roll) ? copiedAt : nil, lastCopiedAt: copiedAt, copyCount: 1
        )
        return (capture, item, memo)
    }

    private static func word(_ words: [String], _ generator: inout SeededGenerator) -> String {
        words[Int.random(in: 0..<words.count, using: &generator)]
    }
}

/// SplitMix64: small, fast and reproducible across runs.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
