#if DEBUG
import AppKit
import Foundation

/// Fixed synthetic clips for UI tests in an isolated capture test session, and the seeding of an isolated library
/// with them or with other clips. Never reads or writes a pasteboard.
enum SyntheticClipSeeder {
    static let sourceApp = CaptureTestConfiguration.systemTestHostBundleIdentifier

    /// Oldest first, so the last clip is the newest recent clip.
    static func clips() -> [[(String, Data)]] {
        let link = Data("https://example.com/synthetic".utf8)
        return [
            [("public.png", pixel())],
            [("public.rtf", Data(#"{\rtf1\ansi Synthetic rich text}"#.utf8)),
             ("public.utf8-plain-text", Data("Synthetic rich text".utf8))],
            [("public.url", link), ("public.utf8-plain-text", link)],
            [("public.utf8-plain-text", Data("合成中文剪贴板条目，用于快捷面板测试".utf8))],
            [("public.utf8-plain-text", Data("set -e\necho synthetic-gamma\n".utf8))],
            [("public.utf8-plain-text", Data("echo synthetic-beta\n".utf8))],
            [("public.utf8-plain-text", Data("Synthetic alpha note".utf8))],
        ]
    }

    /// Captures `clips`, oldest first, each a second before the next and the last a second before `now`.
    static func seed(_ clips: [[(String, Data)]] = clips(), into controller: PersistenceController,
                     now: Date = Date()) async throws {
        let service = CaptureService(controller: controller)
        for (offset, representations) in clips.enumerated() {
            let snapshot = CaptureSnapshotValue(
                items: [CapturedPasteboardItem(representations: representations.map {
                    CapturedRepresentation(typeIdentifier: $0.0, bytes: $0.1)
                })],
                changeCount: offset + 1,
                sourceApp: sourceApp
            )
            _ = try await service.capture(snapshot, at: now.addingTimeInterval(Double(offset - clips.count)))
        }
    }

    private static func pixel() -> Data {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)
        return image?.representation(using: .png, properties: [:]) ?? Data()
    }
}
#endif
