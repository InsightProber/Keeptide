#if DEBUG
import Foundation

/// A manual paste QA run (`--manual-paste-qa`): a throwaway library and preferences of its own, seeded with harmless
/// clips, so that direct paste can be checked by hand without the user's library. Nothing is recorded. Debug only.
struct ManualPasteQASession: Sendable {
    let id: UUID

    var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("KeeptideManualPasteQA", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    var preferencesSuite: String { "KeeptideManualPasteQA.\(id.uuidString)" }

    /// Oldest first, so the single-line command is the newest clip, which the panel opens on. Every command only
    /// echoes, and nothing else a shell could run does more than fail.
    static func clips() -> [[(String, Data)]] {
        let link = Data("https://example.com/keeptide-qa".utf8)
        let chinese = String(repeating: "Keeptide 人工验收：这是一段用于检查直接粘贴的中文长文本。", count: 8)
        return [
            [("public.url", link), ("public.utf8-plain-text", link)],
            [("public.rtf", Data(#"{\rtf1\ansi {\b Keeptide QA} rich text}"#.utf8)),
             ("public.utf8-plain-text", Data("Keeptide QA rich text".utf8))],
            [("public.utf8-plain-text", Data(chinese.utf8))],
            [("public.utf8-plain-text", Data("echo keeptide-qa-line-1\n\techo keeptide-qa-line-2\n".utf8))],
            [("public.utf8-plain-text", Data("echo keeptide-qa-trailing-newline\n".utf8))],
            [("public.utf8-plain-text", Data("echo keeptide-qa-single".utf8))],
        ]
    }

    /// Deletes the library and the preferences. Call it once the library's store and search index are closed.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults(suiteName: preferencesSuite)?.removePersistentDomain(forName: preferencesSuite)
    }
}
#endif
