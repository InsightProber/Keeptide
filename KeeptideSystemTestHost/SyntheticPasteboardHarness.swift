import AppKit
import Foundation

@MainActor
final class SyntheticPasteboardHarness {
    static let pasteboardName = NSPasteboard.Name("io.github.insightprober.Keeptide.SystemTestHost.synthetic")

    private(set) var status = "No synthetic payload written"
    private(set) var receivedTypes: [String] = []
    private(set) var receivedText = ""
    private(set) var receivedPasteCount = 0
    private(set) var receivedPasteText = ""
    private(set) var receivedPasteModifiers = ""

    private let pasteboard: NSPasteboard

    init() {
        do {
            if let configuration = try CaptureTestConfiguration.parse(ProcessInfo.processInfo.arguments) {
                pasteboard = NSPasteboard(name: .init(configuration.pasteboardName))
            } else {
                pasteboard = NSPasteboard(name: Self.pasteboardName)
            }
        } catch {
            // A malformed explicit test session must fail, not write to another board.
            fatalError("Invalid synthetic capture session identifier")
        }
    }

    func writeText() {
        pasteboard.clearContents()
        pasteboard.setString("Synthetic Keeptide text", forType: .string)
        status = "Synthetic text written"
    }

    func writeAlternateText() {
        pasteboard.clearContents()
        pasteboard.setString("Synthetic paused text", forType: .string)
        status = "Synthetic alternate text written"
    }

    func writeRichText() {
        let attributedString = NSAttributedString(
            string: "Synthetic rich text",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 15)]
        )
        let range = NSRange(location: 0, length: attributedString.length)
        guard let data = try? attributedString.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) else {
            status = "Unable to create synthetic rich text"
            return
        }

        pasteboard.clearContents()
        pasteboard.setData(data, forType: .rtf)
        status = "Synthetic rich text written"
    }

    func writeImage() {
        let image = NSImage(size: NSSize(width: 160, height: 100), flipped: false) { bounds in
            NSColor.systemBlue.setFill()
            bounds.fill()
            return true
        }
        guard let data = image.tiffRepresentation else {
            status = "Unable to create synthetic image"
            return
        }

        pasteboard.clearContents()
        pasteboard.setData(data, forType: .tiff)
        status = "Synthetic image written"
    }

    func writeFileReference() {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("keeptide-system-test-host.txt", isDirectory: false)
        do {
            try Data("Synthetic file reference".utf8).write(to: fileURL, options: .atomic)
            pasteboard.clearContents()
            pasteboard.writeObjects([fileURL as NSURL])
            status = "Synthetic file reference written"
        } catch {
            status = "Unable to create synthetic file reference"
        }
    }

    func inspectSyntheticPasteboard() {
        receivedTypes = pasteboard.types?.map(\.rawValue).sorted() ?? []
        receivedText = pasteboard.string(forType: .string) ?? ""
        status = receivedTypes.isEmpty ? "No synthetic payload received" : "Synthetic payload received"
    }

    /// A ⌘V in the paste receiver. It reads this session's named pasteboard, never the general one, and records the
    /// modifiers the key arrived with, written in the order ⌃⌥⇧⌘.
    func receivePaste(modifiers: NSEvent.ModifierFlags) -> String {
        let text = pasteboard.string(forType: .string) ?? ""
        receivedPasteCount += 1
        receivedPasteText = text
        let symbols: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘"),
        ]
        receivedPasteModifiers = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return text
    }

    func receiveDroppedFiles(_ urls: [URL]) {
        receivedTypes = urls.map { $0.lastPathComponent }.sorted()
        status = urls.isEmpty ? "No file received" : "Synthetic file drop received"
    }
}
