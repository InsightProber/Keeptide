import AppKit
import Foundation

struct OwnWriteToken: Equatable, Sendable {
    static let typeIdentifier = CaptureWire.ownWriteTypeIdentifier

    let changeCount: Int
    let marker: String

    @MainActor
    func matches(pasteboard: NSPasteboard) -> Bool {
        guard pasteboard.changeCount == changeCount,
              let markerData = marker.data(using: .utf8) else {
            return false
        }
        let markerType = NSPasteboard.PasteboardType(Self.typeIdentifier)
        return pasteboard.pasteboardItems?.contains {
            $0.data(forType: markerType) == markerData
        } == true
    }
}

enum PasteboardWriterError: Error, Equatable {
    case nonActionableContent
    case emptyContent
    case invalidRepresentationCoordinates
    case reservedTypeIdentifier
    case missingRepresentationBytes(itemIndex: Int, representationIndex: Int)
    case invalidRepresentationBytes(itemIndex: Int, representationIndex: Int)
    case cannotPrepareRepresentation(itemIndex: Int, representationIndex: Int)
    case writeFailed
    case noPlainText
    case commandTooLong
}

struct PreparedPasteboardContent: Sendable {
    fileprivate let representations: [RepresentationValue]
}

@MainActor
final class PasteboardWriter {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func write(_ content: PreparedPasteboardContent) throws -> OwnWriteToken {
        let prepared = try prepareItems(content.representations)
        let marker = UUID().uuidString
        let markerType = NSPasteboard.PasteboardType(OwnWriteToken.typeIdentifier)
        guard let markerData = marker.data(using: .utf8),
              prepared[0].setData(markerData, forType: markerType) else {
            throw PasteboardWriterError.cannotPrepareRepresentation(itemIndex: 0, representationIndex: 0)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(prepared) else {
            throw PasteboardWriterError.writeFailed
        }
        return OwnWriteToken(changeCount: pasteboard.changeCount, marker: marker)
    }

    nonisolated static func prepare(_ content: ResolvedContent) throws -> PreparedPasteboardContent {
        guard content.isActionable else { throw PasteboardWriterError.nonActionableContent }
        let representations = content.representations
        guard !representations.isEmpty else {
            throw PasteboardWriterError.emptyContent
        }
        let ordered = representations.sorted {
            ($0.itemIndex, $0.representationIndex) < ($1.itemIndex, $1.representationIndex)
        }

        var nextItemIndex = 0
        var nextRepresentationIndex = 0
        var currentTypes = Set<String>()

        for representation in ordered {
            if representation.itemIndex == nextItemIndex + 1 && nextRepresentationIndex > 0 {
                nextItemIndex += 1
                nextRepresentationIndex = 0
                currentTypes.removeAll(keepingCapacity: true)
            }
            guard representation.itemIndex == nextItemIndex,
                  representation.representationIndex == nextRepresentationIndex,
                  representation.itemIndex >= 0,
                  representation.representationIndex >= 0 else {
                throw PasteboardWriterError.invalidRepresentationCoordinates
            }
            guard representation.typeIdentifier != OwnWriteToken.typeIdentifier else {
                throw PasteboardWriterError.reservedTypeIdentifier
            }
            guard currentTypes.insert(representation.typeIdentifier).inserted else {
                throw PasteboardWriterError.invalidRepresentationCoordinates
            }
            guard let bytes = representation.bytes else {
                throw PasteboardWriterError.missingRepresentationBytes(
                    itemIndex: representation.itemIndex,
                    representationIndex: representation.representationIndex
                )
            }
            guard representation.byteCount == Int64(bytes.count),
                  representation.digest == ContentDigest.sha256(bytes) else {
                throw PasteboardWriterError.invalidRepresentationBytes(
                    itemIndex: representation.itemIndex,
                    representationIndex: representation.representationIndex
                )
            }

            nextRepresentationIndex += 1
        }
        return PreparedPasteboardContent(representations: ordered)
    }

    /// `prepare`, less every representation of text or a link (`ContentKind.isText`). Images, file URLs and other
    /// data stay, in their order, and an item left with nothing is dropped. Throws `.emptyContent` when nothing is
    /// left.
    nonisolated static func prepareWithoutText(_ content: ResolvedContent) throws -> PreparedPasteboardContent {
        var kept: [RepresentationValue] = []
        var lastSourceItem: Int?
        for var representation in try prepare(content).representations
        where !ContentKind.isText(representation.typeIdentifier) {
            // Numbered again from zero, as the write expects: dropped items and representations leave no gap.
            if representation.itemIndex == lastSourceItem, let previous = kept.last {
                representation.itemIndex = previous.itemIndex
                representation.representationIndex = previous.representationIndex + 1
            } else {
                lastSourceItem = representation.itemIndex
                representation.itemIndex = (kept.last?.itemIndex ?? -1) + 1
                representation.representationIndex = 0
            }
            kept.append(representation)
        }
        guard !kept.isEmpty else { throw PasteboardWriterError.emptyContent }
        return PreparedPasteboardContent(representations: kept)
    }

    /// Plain text built like the search body: each item's first cleanly decodable text,
    /// preferring text over a link, joined by line breaks and written as the only
    /// representation in UTF-8.
    nonisolated static func preparePlainText(_ content: ResolvedContent) throws -> PreparedPasteboardContent {
        try utf8PlainText(plainText(content), of: content)
    }

    /// The text `preparePlainText` writes, under the same rules and errors: each item's first cleanly
    /// decodable text, preferring text over a link, joined by line breaks. Throws `.noPlainText` when no
    /// item has any.
    nonisolated static func plainText(_ content: ResolvedContent) throws -> String {
        guard content.isActionable else { throw PasteboardWriterError.nonActionableContent }
        let items = Dictionary(grouping: content.representations, by: \.itemIndex)
        var texts: [String] = []
        for itemIndex in items.keys.sorted() {
            let candidates = items[itemIndex, default: []]
                .filter { ClipboardTextDecoder.isTextType($0.typeIdentifier) }
                .sorted { $0.representationIndex < $1.representationIndex }
            let isLink: (RepresentationValue) -> Bool = { $0.typeIdentifier.lowercased() == "public.url" }
            for representation in candidates.filter({ !isLink($0) }) + candidates.filter(isLink) {
                guard let bytes = representation.bytes,
                      representation.byteCount == Int64(bytes.count),
                      representation.digest == ContentDigest.sha256(bytes) else {
                    throw PasteboardWriterError.invalidRepresentationBytes(
                        itemIndex: representation.itemIndex,
                        representationIndex: representation.representationIndex
                    )
                }
                guard let decoded = ClipboardTextDecoder.decodeText(
                    bytes, typeIdentifier: representation.typeIdentifier, maximumBytes: bytes.count
                ), !decoded.isTruncated else { continue }
                texts.append(decoded.text)
                break
            }
        }
        guard !texts.isEmpty else { throw PasteboardWriterError.noPlainText }
        return texts.joined(separator: "\n")
    }

    /// One `public.utf8-plain-text` representation holding `command.text`; the clip's other formats are not
    /// written. Throws `.noPlainText` when there is no text, or nothing is left after removing the line break, and
    /// `.commandTooLong` when the command's text has more than `maximumByteCount` UTF-8 bytes. A command that long
    /// is never made, shown or encoded.
    nonisolated static func prepareCommand(_ content: ResolvedContent, maximumByteCount: Int) throws
        -> (PreparedPasteboardContent, TerminalCommand) {
        let text = try plainText(content)
        guard TerminalCommand.commandText(in: text).utf8.count <= maximumByteCount else {
            throw PasteboardWriterError.commandTooLong
        }
        let command = TerminalCommand(plainText: text)
        guard !command.text.isEmpty else { throw PasteboardWriterError.noPlainText }
        return (try utf8PlainText(command.text, of: content), command)
    }

    /// The one representation that `preparePlainText` and `prepareCommand` write.
    private nonisolated static func utf8PlainText(_ text: String, of content: ResolvedContent) throws
        -> PreparedPasteboardContent {
        guard let snapshotID = content.representations.first?.snapshotID else {
            throw PasteboardWriterError.noPlainText
        }
        let utf8 = Data(text.utf8)
        return PreparedPasteboardContent(representations: [RepresentationValue(
            snapshotID: snapshotID, itemIndex: 0, representationIndex: 0,
            typeIdentifier: "public.utf8-plain-text", storage: .portable,
            byteCount: Int64(utf8.count), digest: ContentDigest.sha256(utf8), bytes: utf8
        )])
    }

    private func prepareItems(_ representations: [RepresentationValue]) throws -> [NSPasteboardItem] {
        var items: [NSPasteboardItem] = []
        for representation in representations {
            if representation.itemIndex == items.count { items.append(NSPasteboardItem()) }
            guard let bytes = representation.bytes,
                  items[representation.itemIndex].setData(bytes, forType: .init(representation.typeIdentifier)) else {
                throw PasteboardWriterError.cannotPrepareRepresentation(
                    itemIndex: representation.itemIndex, representationIndex: representation.representationIndex)
            }
        }
        return items
    }
}
