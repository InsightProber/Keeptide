import AppKit
import Foundation

struct OwnWriteToken: Equatable, Sendable {
    static let typeIdentifier = "io.github.insightprober.keeptide.own-write"

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
}

@MainActor
final class PasteboardWriter {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
    }

    func write(_ content: ResolvedContent) throws -> OwnWriteToken {
        guard content.isActionable else {
            throw PasteboardWriterError.nonActionableContent
        }
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

    private func prepareItems(_ representations: [RepresentationValue]) throws -> [NSPasteboardItem] {
        guard !representations.isEmpty else {
            throw PasteboardWriterError.emptyContent
        }
        let ordered = representations.sorted {
            ($0.itemIndex, $0.representationIndex) < ($1.itemIndex, $1.representationIndex)
        }

        var prepared: [NSPasteboardItem] = []
        var nextItemIndex = 0
        var nextRepresentationIndex = 0
        var currentItem: NSPasteboardItem?
        var currentTypes = Set<String>()

        for representation in ordered {
            if representation.itemIndex == nextItemIndex + 1 && nextRepresentationIndex > 0 {
                nextItemIndex += 1
                nextRepresentationIndex = 0
                currentItem = nil
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

            let item: NSPasteboardItem
            if let currentItem {
                item = currentItem
            } else {
                item = NSPasteboardItem()
                currentItem = item
                prepared.append(item)
            }
            guard item.setData(
                bytes,
                forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
            ) else {
                throw PasteboardWriterError.cannotPrepareRepresentation(
                    itemIndex: representation.itemIndex,
                    representationIndex: representation.representationIndex
                )
            }
            nextRepresentationIndex += 1
        }
        return prepared
    }
}
