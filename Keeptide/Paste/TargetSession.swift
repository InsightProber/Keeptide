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

    /// The front app's window to paste into, or nil. It is `frontmostWindow`, and in addition the topmost
    /// on-screen window at layer 0 that is not Keeptide's own must be the front app's. The list's z-order is
    /// live, so this also catches an app switch that `frontmostApplication` has not reported yet, and an
    /// active app whose windows sit behind another app's.
    static func targetWindow(in windowList: [[String: Any]], frontProcessIdentifier: pid_t,
                             ownProcessIdentifier: pid_t) -> Int? {
        for window in windowList where (window[kCGWindowLayer as String] as? Int) == 0 {
            let owner = window[kCGWindowOwnerPID as String] as? Int
            if owner == Int(ownProcessIdentifier) { continue }
            guard owner == Int(frontProcessIdentifier) else { return nil }
            if let number = window[kCGWindowNumber as String] as? Int { return number }
        }
        return nil
    }

    /// `<App>`: the localized name, else the bundle identifier, else "App". A blank value counts as missing.
    static func name(localizedName: String?, bundleIdentifier: String?) -> String {
        [localizedName, bundleIdentifier].lazy.compactMap { $0 }.first { !$0.allSatisfy(\.isWhitespace) } ?? "App"
    }
}

/// Terminals can run pasted text as soon as it arrives. Listing an extra app only makes pasting stricter.
enum KnownTerminals {
    static let bundleIdentifiers: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "com.mitchellh.ghostty",
    ]

    /// Bundle identifiers are compared without regard to case.
    static func contains(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased() else { return false }
        return bundleIdentifiers.contains { $0.lowercased() == identifier }
    }
}
