import CoreGraphics

/// A frontmost app and its frontmost normal window. Identity stops at the window:
/// Keeptide never reads the app's controls.
struct PasteTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
    let windowNumber: Int

    var isTerminal: Bool { KnownTerminals.contains(bundleIdentifier) }

    /// The app's frontmost on-screen window at layer 0, or nil. `windowList` is CGWindowListCopyWindowInfo's
    /// result, front to back.
    static func frontmostWindow(in windowList: [[String: Any]], processIdentifier: pid_t) -> Int? {
        windowList.lazy.compactMap { window -> Int? in
            guard (window[kCGWindowOwnerPID as String] as? Int) == Int(processIdentifier),
                  (window[kCGWindowLayer as String] as? Int) == 0 else { return nil }
            return window[kCGWindowNumber as String] as? Int
        }.first
    }
}

/// Terminals can run pasted text as soon as it arrives. Listing an extra app only makes pasting stricter.
enum KnownTerminals {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty",
    ]

    static func contains(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier.map(bundleIdentifiers.contains) ?? false
    }
}
