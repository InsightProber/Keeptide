import CoreGraphics

/// A frontmost app and its frontmost normal window. Identity stops at the window:
/// Keeptide never reads the app's controls.
struct PasteTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let name: String
    let windowNumber: Int

    var isTerminal: Bool { KnownTerminals.contains(bundleIdentifier) }

    /// Finder, which is never a target: the window check cannot tell its desktop from one of its windows on top, and
    /// a paste into Finder copies files. Compared without regard to case.
    var isFinder: Bool { bundleIdentifier?.lowercased() == "com.apple.finder" }

    /// The front app's window to paste into, or nil: its frontmost on-screen window at layer 0, which must also be the
    /// topmost window at layer 0 that is not Keeptide's own. `windowList` is CGWindowListCopyWindowInfo's result, front
    /// to back. The list's z-order is live, so this also catches an app switch that `frontmostApplication` has not
    /// reported yet, and an active app whose windows sit behind another app's.
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
        "co.zeit.hyper", "org.tabby", "com.raphaelamorim.rio", "dev.warp.Warp-Preview",
    ]

    /// Bundle identifiers are compared without regard to case.
    static func contains(_ bundleIdentifier: String?) -> Bool {
        guard let identifier = bundleIdentifier?.lowercased() else { return false }
        return bundleIdentifiers.contains { $0.lowercased() == identifier }
    }
}
