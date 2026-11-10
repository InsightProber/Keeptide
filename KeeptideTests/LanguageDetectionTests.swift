import XCTest
@testable import Keeptide

/// What language a text is judged to be in before it is translated, from synthetic sentences. The tests check the kind
/// of judgement and the language, not exact confidences, which depend on the system's model.
final class LanguageDetectionTests: XCTestCase {
    func testClearProseIsDetected() {
        let samples: [(String, String)] = [
            ("The quarterly report is due on Friday, and finance needs it by noon.", "en"),
            ("季度报告周五截止，财务需要在中午前拿到。", "zh-Hans"),
            ("季度報告週五截止，財務需要在中午前拿到。", "zh-Hant"),
            ("四半期報告は金曜日が締め切りで、経理は正午までに必要です。", "ja"),
            ("분기 보고서는 금요일까지 제출해야 합니다.", "ko"),
        ]
        for (text, expected) in samples {
            guard case .detected(let language, let confidence) = LanguageDetection.judge(text) else {
                XCTFail("\(text) should be detected, not \(LanguageDetection.judge(text))")
                continue
            }
            XCTAssertTrue(language.isSameLanguage(as: Locale.Language(identifier: expected)),
                          "\(text) is \(expected), not \(language.maximalIdentifier)")
            XCTAssertGreaterThanOrEqual(confidence, LanguageDetection.threshold)
        }
    }

    func testShortTextIsJudgedOnlyWhenItsScriptSaysEnough() {
        // Eleven letters of English say too little, twelve are judged; two characters of Chinese or Japanese say plenty.
        XCTAssertEqual(LanguageDetection.judge("Thanks, Tom"), .tooShort)
        XCTAssertEqual(LanguageDetection.judge("Good evening"), .tooShort)
        XCTAssertNotEqual(LanguageDetection.judge("Good evenings"), .tooShort)
        XCTAssertEqual(LanguageDetection.judge("  \n "), .tooShort)
        XCTAssertEqual(LanguageDetection.judge("好"), .tooShort)
        for (text, expected) in [("谢谢", "zh-Hans"), ("谢谢你", "zh-Hans"), ("謝謝你", "zh-Hant"), ("ありがとう", "ja")] {
            guard case .detected(let language, _) = LanguageDetection.judge(text) else {
                XCTFail("\(text) should be detected, not \(LanguageDetection.judge(text))")
                continue
            }
            XCTAssertTrue(language.isSameLanguage(as: Locale.Language(identifier: expected)), text)
        }
    }

    func testCodeLinksAndNumbersAreNotProse() {
        let notProse = [
            "https://example.com/reports/2026?id=42",
            "Read it at https://example.com/reports/quarterly-2026",
            "let total = items.reduce(0) { $0 + $1.price }",
            "const total = price * count;",
            "def total(items):\n    return sum(item.price for item in items)",
            "SELECT name, price FROM items WHERE price > 10 ORDER BY name",
            "UPDATE items SET price = 10 WHERE id = 3",
            "cp ~/Documents/report.pdf /Volumes/Backup/",
            "rm -rf ~/Library/Caches/Keeptide",
            "$ swift build --configuration release",
            "import Foundation",
            "import java.util.List;",
            "#include <stdio.h>",
            "printf(\"%d\\n\", total);",
            "{\"name\": \"Keeptide\", \"version\": 2, \"beta\": true}",
            "git commit -m \"Fix the build\" && git push",
            "12,345.67 + 89 = 12,434.67",
            "2026-11-10 06:00:00",
        ]
        for text in notProse {
            XCTAssertEqual(LanguageDetection.judge(text), .notProse, text)
        }
        // Brackets, colons, quotes, apostrophes and hyphens in sentences leave them prose, as do a heading's underline
        // and names of files.
        let prose = [
            "The draft (version two) is ready: please review it by Thursday.",
            "She wrote back: \"Done; ship it on Monday after the review.\"",
            "She said: \"Don't touch the file(s) until the well-known review is over!\"",
            "Les étudiant(e)s qu'on a inscrit(e)s n'ont pas reçu l'e-mail : c'est l'erreur d'aujourd'hui !",
            "Meeting notes\n=============\nWe agreed to ship the update after the review on Friday.",
            "Edit README.md and setup.py",
            "Notes on example.com and swift.org",
            "Let me know what you think: the plan (and its budget) is due on Friday.",
            "We'll move it -> Friday; that's fine, isn't it? We're done.",
            "Pick option(s) \"A\" or \"B\" (or both)!",
            // Lists whose items end in semicolons, a path in a sentence, a signature, words that are also code's.
            "The tenant shall:\n(a) pay the rent on time;\n(b) keep the premises clean;\n(c) tell the landlord about repairs.",
            "Les participants doivent :\n- s'inscrire avant vendredi ;\n- payer les frais ;\n- apporter une pièce d'identité.",
            "Open ~/Library/Application Support/Keeptide and delete the cache",
            "See you tomorrow,\n-Tom",
            "UPDATE from the facilities team\nThe office is closed on Friday.",
            "SELECT ALL THAT APPLY",
            "Buy milk on the way home\nimport photos\ncall the bank",
            "$ 100 for the tickets, please.",
            "Please copy the logs from\nthe folder ~/Library/Logs/Keeptide/ and attach them to your reply.",
            "check ~/Desktop/notes/ for the draft",
            "The supplier shall deliver:\nthe product(s) listed in Annex 1;\nthe user manual(s).",
        ]
        for text in prose {
            XCTAssertNotEqual(LanguageDetection.judge(text), .notProse, text)
        }
    }

    func testAnIdeographWeighsAsMuchAsAShortWord() {
        XCTAssertEqual(LanguageDetection.weight(of: "Report, 2026!"), 6)
        XCTAssertEqual(LanguageDetection.weight(of: "季度报告"), 12)
        XCTAssertEqual(LanguageDetection.weight(of: "ありがとう"), 15)
    }

    func testMixedTextIsUncertainAndNamesItsLikeliestLanguages() {
        guard case .uncertain(let candidates) = LanguageDetection.judge("Hello 你好 Bonjour 안녕") else {
            return XCTFail("Mixed text should be uncertain")
        }
        XCTAssertFalse(candidates.isEmpty)
        XCTAssertLessThanOrEqual(candidates.count, 3)
    }

    func testALanguageOutsideTheConstraintsIsNotPickedFromThem() {
        let swedish = "Rapporten ska vara klar på fredag och ekonomi behöver den före lunch."
        // Unconstrained, Swedish is Swedish, so a translation can say this Mac can't translate from it.
        guard case .detected(let language, _) = LanguageDetection.judge(swedish) else {
            return XCTFail("Swedish should be detected")
        }
        XCTAssertEqual(language.languageCode?.identifier, "sv")
        // Limited to other languages, only those come back.
        let constraints = ["en", "de", "nl", "fr", "zh-Hans", "ja"].map { Locale.Language(identifier: $0) }
        switch LanguageDetection.judge(swedish, constraints: constraints) {
        case .detected(let picked, _):
            XCTAssertNotEqual(picked.languageCode?.identifier, "sv")
        case .uncertain(let candidates):
            XCTAssertFalse(candidates.contains { $0.languageCode?.identifier == "sv" })
        case let other:
            XCTFail("Swedish prose is judged, not \(other)")
        }
    }

    func testTheSameLanguageIgnoresRegionsButNotScripts() {
        let english = Locale.Language(identifier: "en")
        XCTAssertTrue(english.isSameLanguage(as: Locale.Language(identifier: "en-GB")))
        XCTAssertTrue(english.isSameLanguage(as: Locale.Language(identifier: "en-Latn-US")))
        XCTAssertTrue(Locale.Language(identifier: "zh").isSameLanguage(as: Locale.Language(identifier: "zh-Hans-CN")))
        XCTAssertFalse(Locale.Language(identifier: "zh-Hans").isSameLanguage(as: Locale.Language(identifier: "zh-Hant")))
        XCTAssertFalse(english.isSameLanguage(as: Locale.Language(identifier: "ja")))
    }

    func testNamesReadAsTheSystemsTranslateWritesThem() {
        XCTAssertEqual(Locale.Language(identifier: "zh-Hans").displayName, "Chinese (Simplified)")
        XCTAssertEqual(Locale.Language(identifier: "zh-Hant-TW").displayName, "Chinese (Traditional)")
        XCTAssertEqual(Locale.Language(identifier: "zh").displayName, "Chinese (Simplified)")
        XCTAssertEqual(Locale.Language(identifier: "en-US").displayName, "English")
        XCTAssertEqual(Locale.Language(identifier: "ja").displayName, "Japanese")
    }
}
