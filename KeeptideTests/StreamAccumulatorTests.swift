import XCTest
@testable import Keeptide

final class StreamAccumulatorTests: XCTestCase {
    private let recognized = OutputChannel("text")
    private var imageTranslation: StreamAccumulator.TaggedChannels {
        StreamAccumulator.TaggedChannels(["text": recognized, "translation": .main])
    }

    func testAnyChunkingJoinsToTheSameText() {
        let full = "Q4 planning, design review 👩‍💻\nCafe\u{301} 季度报告周五截止。\n\nNext 🇺🇸 paragraph"
        for size in [1, 2, 3, 5, 8, 13] {
            var accumulator = StreamAccumulator()
            for chunk in chunks(of: full, size: size) { accumulator.apply(.delta(chunk)) }
            accumulator.finish()
            XCTAssertEqual(accumulator.text(), full, "chunks of \(size) scalars")
        }
    }

    func testTaggedOutputSplitsIntoChannelsWhereverTheChunksBreak() {
        let output = "Note:\n<text>\nQ4 planning\n1. Ship the update\n</text>\n<translation>\nQ4 规划\n1. 发布更新\n</translation>\nThanks"
        for size in 1...12 {
            var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
            for chunk in chunks(of: output, size: size) { accumulator.apply(.delta(chunk)) }
            accumulator.finish()
            XCTAssertEqual(accumulator.text(recognized), "Q4 planning\n1. Ship the update", "chunks of \(size)")
            XCTAssertEqual(accumulator.text(), "Q4 规划\n1. 发布更新", "chunks of \(size)")
            XCTAssertEqual(accumulator.text(.untagged), "Note:\n\nThanks", "chunks of \(size)")
            XCTAssertFalse(accumulator.separationFailed, "chunks of \(size)")
        }
    }

    func testWhatMightBeATagWaitsForTheNextDelta() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("<text>Hello wor"))
        XCTAssertEqual(accumulator.text(recognized), "Hello wor")
        accumulator.apply(.delta("ld</te"))
        XCTAssertEqual(accumulator.text(recognized), "Hello world")
        accumulator.apply(.delta("xt>\n<transl"))
        XCTAssertEqual(accumulator.text(), "")
        accumulator.apply(.delta("ation>你好"))
        XCTAssertEqual(accumulator.text(recognized), "Hello world")
        XCTAssertEqual(accumulator.text(), "你好")
    }

    func testOutputWithoutTagsStreamsIntoTheFallbackChannel() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("Just the translation, "))
        XCTAssertEqual(accumulator.text(), "Just the translation,", "a trailing space waits for what follows")
        accumulator.apply(.delta("no tags."))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(), "Just the translation, no tags.")
        XCTAssertEqual(accumulator.text(recognized), "")
        XCTAssertTrue(accumulator.separationFailed)
    }

    func testAPreambleMovesOutOfTheResultWhenTheFirstTagOpens() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("Here you go: "))
        XCTAssertEqual(accumulator.text(), "Here you go:")
        accumulator.apply(.delta("<text>A</text>\n<translation>B</translation>\nLet me know if you need more."))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(recognized), "A")
        XCTAssertEqual(accumulator.text(), "B")
        XCTAssertEqual(accumulator.text(.untagged), "Here you go:\n\nLet me know if you need more.")
        XCTAssertFalse(accumulator.separationFailed)
    }

    func testAResultOutsideItsTagsEndsUpInTheFallbackChannel() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("<text>A</text>\nB, the translation without its tags"))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(recognized), "A")
        XCTAssertEqual(accumulator.text(), "B, the translation without its tags")
        XCTAssertEqual(accumulator.text(.untagged), "")
        XCTAssertTrue(accumulator.separationFailed)
    }

    func testRepeatedTagsAreSeparatedByABlankLine() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("<translation>First</translation>\n<translation>\nSecond</translation>"))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(), "First\n\nSecond")
    }

    func testAnUnclosedTagKeepsItsText() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("<translation>\nPartial answer\n"))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(), "Partial answer")
        XCTAssertFalse(accumulator.separationFailed)
    }

    func testACutOffTagAtTheEndIsDropped() {
        var inside = StreamAccumulator(taggedChannels: imageTranslation)
        inside.apply(.delta("<translation>Cut off here</transl"))
        inside.finish()
        XCTAssertEqual(inside.text(), "Cut off here")

        var outside = StreamAccumulator(taggedChannels: imageTranslation)
        outside.apply(.delta("<text>A</text><transl"))
        outside.finish()
        XCTAssertEqual(outside.text(), "")
        XCTAssertEqual(outside.text(.untagged), "")

        var lone = StreamAccumulator(taggedChannels: imageTranslation)
        lone.apply(.delta("<translation>x <"))
        lone.finish()
        XCTAssertEqual(lone.text(), "x <", "a lone \"<\" is text")
    }

    func testALineBreakSplitAcrossDeltasStaysOneCharacter() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("<text>A\r"))
        accumulator.apply(.delta("\nB</text>"))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(recognized), "A\r\nB")
    }

    func testReplaceSwapsTheWholeChannel() {
        var accumulator = StreamAccumulator()
        accumulator.apply(.delta("Draft"))
        accumulator.apply(.replace("Rewritten"))
        accumulator.apply(.delta(" text"))
        XCTAssertEqual(accumulator.text(), "Rewritten text")
    }

    func testReplaceRoutesTaggedOutputAgain() {
        var accumulator = StreamAccumulator(taggedChannels: imageTranslation)
        accumulator.apply(.delta("<text>Old</text><translation>旧"))
        accumulator.apply(.replace("<text>New</text><translation>新</translation>"))
        accumulator.finish()
        XCTAssertEqual(accumulator.text(recognized), "New")
        XCTAssertEqual(accumulator.text(), "新")
    }

    func testEventsAfterTheFinishAreIgnored() {
        var accumulator = StreamAccumulator()
        accumulator.apply(.delta("Done"))
        accumulator.apply(.finished(.completed))
        accumulator.apply(.delta(" and more"))
        accumulator.apply(.finished(.truncated))
        XCTAssertEqual(accumulator.text(), "Done")
        XCTAssertEqual(accumulator.finishReason, .completed)
    }

    func testStartAndUsageAreKept() {
        var accumulator = StreamAccumulator()
        let info = GenerationInfo(engine: "Claude Haiku 5.5", model: "claude-haiku-5-5")
        accumulator.apply(.started(info))
        accumulator.apply(.usage(GenerationUsage(inputTokens: 120, outputTokens: 80)))
        XCTAssertEqual(accumulator.info, info)
        XCTAssertEqual(accumulator.usage, GenerationUsage(inputTokens: 120, outputTokens: 80))
        XCTAssertFalse(accumulator.hasText)
    }

    func testParagraphsSplitOnBlankLines() {
        XCTAssertEqual(
            StreamAccumulator.paragraphs(of: "One\n\nTwo\nlines\n \n\nThree\r\n\r\nFour\n"),
            ["One", "Two\nlines", "Three", "Four"])
        XCTAssertEqual(StreamAccumulator.paragraphs(of: "\n\n"), [])
    }

    func testOnlyParagraphsABlankLineHasFollowedAreDoneWhileStreaming() {
        var accumulator = StreamAccumulator()
        accumulator.apply(.delta("One\n\nTwo"))
        XCTAssertEqual(accumulator.completedParagraphCount(), 1)
        accumulator.apply(.delta("\n"))
        XCTAssertEqual(accumulator.completedParagraphCount(), 1, "one line break may continue the paragraph")
        accumulator.apply(.delta("\n"))
        XCTAssertEqual(accumulator.completedParagraphCount(), 2)
        accumulator.apply(.delta("Three"))
        accumulator.finish()
        XCTAssertEqual(accumulator.completedParagraphCount(), 3)
    }

    /// `text` cut into pieces of `size` Unicode scalars, so pieces can split an emoji's or an accent's characters.
    private func chunks(of text: String, size: Int) -> [String] {
        let scalars = Array(text.unicodeScalars)
        return stride(from: 0, to: scalars.count, by: size).map { start in
            var piece = String.UnicodeScalarView()
            piece.append(contentsOf: scalars[start..<min(start + size, scalars.count)])
            return String(piece)
        }
    }
}
