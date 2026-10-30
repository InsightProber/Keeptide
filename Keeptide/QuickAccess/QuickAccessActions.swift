/// What quick access offers for the selected clip. It follows from the session's target and from what the checks
/// allowed when the panel opened.
/// - The primary action is Return's, and the plain-text one is ⇧Return's.
/// - The copy-only item never pastes.
/// - The panel can offer to turn direct paste on, and can say why it only copies.
///
/// Text and links in a terminal are a command. Return and ⇧Return then give the same command, so there is no
/// plain-text item.
struct QuickAccessActions: Equatable {
    var primaryTitle: String
    /// nil in command mode.
    var plainTextTitle: String?
    /// "Copy" beside a paste. In a terminal's session it is "Copy As-Is" whether or not the panel pastes, and "Copy
    /// As-Is (Keeps Trailing Newline)" in command mode. nil when not offered.
    var copyOnlyTitle: String?
    /// How the copy-only item copies.
    var copyOnlyMode: PasteMode
    var offersEnableDirectPaste: Bool
    /// Why the panel only copies, when the user can do something about it.
    var hint: String?

    /// `availability` is what the session's checks found as the panel opened, nil without a library; `kind` is the
    /// selected row's, nil with nothing selected. `accessRequested` says whether direct paste access was asked for
    /// in this run of Keeptide.
    static func make(target: PasteTarget?, availability: DirectPasteAvailability?, kind: ContentKind?,
                     accessRequested: Bool = false) -> QuickAccessActions {
        var actions = QuickAccessActions(primaryTitle: "Copy", plainTextTitle: "Copy as Plain Text", copyOnlyTitle: nil,
                                         copyOnlyMode: .original, offersEnableDirectPaste: false, hint: nil)
        // With no target, or no library to check it, the panel copies as it did before direct paste.
        guard let target, let availability, availability != .copy(.noTarget) else { return actions }
        let fallback: DirectPasteFallback?
        switch availability {
        case .paste: fallback = nil
        case .copy(let reason): fallback = reason
        }
        actions.offersEnableDirectPaste = fallback == .notPermitted
        actions.hint = fallback.flatMap { hint(for: $0, accessRequested: accessRequested) }
        if target.isTerminal, kind == .text || kind == .url {
            // Only Copy As-Is keeps the clip as captured, trailing line break included.
            actions.primaryTitle = fallback == nil ? "Paste Command" : "Copy Command"
            actions.plainTextTitle = nil
            actions.copyOnlyTitle = "Copy As-Is (Keeps Trailing Newline)"
            actions.copyOnlyMode = .asIs
            return actions
        }
        if fallback == nil {
            actions.primaryTitle = "Paste into \(target.name)"
            actions.plainTextTitle = "Paste as Plain Text"
        }
        if target.isTerminal {
            // In a terminal's session the original formats keep only images and file references, and plain text is a
            // command, so only Copy As-Is copies the clip whole, whether the panel pastes or copies.
            actions.copyOnlyTitle = "Copy As-Is"
            actions.copyOnlyMode = .asIs
        } else if fallback == nil {
            actions.copyOnlyTitle = "Copy"
        }
        return actions
    }

    /// The confirmation card's button: what confirming the review does.
    static func confirmTitle(for review: CommandReview) -> String {
        switch review.confirmation.delivery {
        case .paste: "Confirm Paste into \(review.targetName ?? "App")"
        case .copy: "Confirm Copy Command"
        }
    }

    /// The reasons the user can act on. Without permission the menu offers Enable Direct Paste… instead, until access
    /// was asked for: the system lets Keeptide see it granted only once Keeptide reopens. A changed window or no
    /// target needs nothing from the user.
    private static func hint(for fallback: DirectPasteFallback, accessRequested: Bool) -> String? {
        switch fallback {
        case .secureInput: "Secure input is on"
        case .cannotSendKeystroke: "⌘V isn't on this keyboard layout"
        case .testSessionTarget: "Test sessions paste only into the system test host"
        case .notPermitted: accessRequested ? "Reopen Keeptide to finish turning on direct paste" : nil
        case .targetChanged, .noTarget, .returnHeld: nil
        }
    }
}

/// How an action in quick access ended once it wrote the clipboard.
enum QuickAccessCompletion: Equatable {
    case copied, copiedInstead(DirectPasteFallback), dispatched

    /// What the panel says as it closes. After ⌘V it says nothing: the keystroke does not prove that the target
    /// pasted.
    var toastMessage: String? {
        switch self {
        case .copied:
            "Copied — press ⌘V to paste"
        case .copiedInstead(let fallback):
            switch fallback {
            case .targetChanged: "The window changed — copied instead. Press ⌘V to paste."
            case .notPermitted: "Direct paste is off — copied instead. Press ⌘V to paste."
            case .secureInput: "Secure input is on — copied instead. Press ⌘V to paste."
            case .cannotSendKeystroke: "Couldn't send ⌘V — copied instead. Press ⌘V to paste."
            case .testSessionTarget: "Test sessions paste only into the system test host — copied instead."
            // Stub for the tests that land first.
            case .returnHeld: "Copied — press ⌘V to paste"
            // The panel asks for a paste only with a target, so without one the copy is all there is to tell.
            case .noTarget: "Copied — press ⌘V to paste"
            }
        case .dispatched:
            nil
        }
    }
}
