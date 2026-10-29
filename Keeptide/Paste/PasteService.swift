import AppKit
import Foundation

enum PasteMode: Equatable, Sendable {
    case original, plainText
}

enum PasteRefusal: Error, Equatable, Sendable {
    /// A newer query, selection or session owns the action now.
    case stale
    /// The content changed, was removed, or cannot be written in its original formats.
    case contentUnavailable
    case noPlainText
    case writeFailed
}

enum PasteDelivery: Equatable, Sendable {
    case copy, paste
}

/// Why a paste that was asked for became a copy.
enum DirectPasteFallback: Equatable, Sendable {
    case noTarget, testSessionTarget, notPermitted, targetChanged, secureInput, cannotSendKeystroke
}

enum DirectPasteAvailability: Equatable, Sendable {
    case paste(PasteTarget)
    case copy(DirectPasteFallback)
}

enum PasteOutcome: Equatable, Sendable {
    case copied
    /// ⌘V was posted to the checked target. It does not prove the target pasted.
    case dispatched(PasteTarget)
    /// A paste was asked for and a check failed, so the clip was only copied.
    case copiedInstead(DirectPasteFallback)
    case refused(PasteRefusal)
}

/// One panel or library session. A request carries the query generation it was
/// made for; advancing the generation or ending the session refuses it.
@MainActor
final class PasteSession {
    /// Shared by every session, so a number from one session never matches another's.
    private static var lastGeneration: UInt64 = 0
    /// The app window recorded for this session, by `beginSession()` or carried over by `beginSession(target:)`;
    /// nil means copy only.
    let target: PasteTarget?
    let sessionGeneration: UInt64
    private(set) var queryGeneration: UInt64 = 0
    private(set) var isOpen = true

    fileprivate init(target: PasteTarget?) {
        self.target = target
        Self.lastGeneration += 1
        sessionGeneration = Self.lastGeneration
    }

    @discardableResult
    func advanceQueryGeneration() -> UInt64 {
        Self.lastGeneration += 1
        queryGeneration = Self.lastGeneration
        return queryGeneration
    }

    func end() {
        isOpen = false
    }

    fileprivate func accepts(_ generation: UInt64) -> Bool {
        isOpen && generation == queryGeneration
    }
}

@MainActor
struct PasteRequest {
    let ref: ContentRef
    let queryGeneration: UInt64
    let mode: PasteMode
    let session: PasteSession
    var delivery: PasteDelivery = .copy
    /// Hides the panel for a paste. Called once, after the clipboard is written and before the last check.
    var dismiss: (@MainActor () -> Void)? = nil
}

/// The one path from a selected row to the clipboard. It re-reads the content,
/// re-checks the request after every suspension, and records one use receipt
/// per successful action. A paste also needs every target check to pass, both
/// before the clipboard is written and after the panel hides; otherwise the clip
/// is only copied.
@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private let read: @Sendable (ContentRef) async throws -> ResolvedContent
    private let recordUse: @Sendable (UseReceipt) async throws -> Void
    private let didWrite: @MainActor (OwnWriteToken) -> Void
    private let system: DirectPasteSystem
    /// The one bundle identifier a test session may paste into: other apps read the general clipboard, not
    /// the session's.
    private let directPasteOnlyTo: String?
    /// Only the newest session may paste.
    private var latestSessionGeneration: UInt64 = 0
    /// Called on a caller's programming error. Debug builds stop here; tests replace it to watch for a call.
    var reportProgrammingError: @MainActor (String) -> Void = { assertionFailure($0) }

    init(pasteboard: NSPasteboard,
         read: @escaping @Sendable (ContentRef) async throws -> ResolvedContent,
         recordUse: @escaping @Sendable (UseReceipt) async throws -> Void,
         didWrite: @escaping @MainActor (OwnWriteToken) -> Void,
         system: DirectPasteSystem = .unavailable,
         directPasteOnlyTo: String? = nil) {
        self.pasteboard = pasteboard
        self.read = read
        self.recordUse = recordUse
        self.didWrite = didWrite
        self.system = system
        self.directPasteOnlyTo = directPasteOnlyTo
    }

    /// A session whose target is the app window in front now, if any.
    func beginSession() -> PasteSession {
        beginSession(target: system.frontmostTarget())
    }

    /// A session with a target recorded earlier, or none. The system is not asked.
    func beginSession(target: PasteTarget?) -> PasteSession {
        let session = PasteSession(target: target)
        latestSessionGeneration = session.sessionGeneration
        return session
    }

    /// Whether a paste in this session could be sent now: the first failing check, in order, or the target.
    /// It only asks the system and changes nothing.
    func availability(for session: PasteSession) -> DirectPasteAvailability {
        guard let target = session.target else { return .copy(.noTarget) }
        if let directPasteOnlyTo, target.bundleIdentifier != directPasteOnlyTo { return .copy(.testSessionTarget) }
        guard system.canPostEvents() else { return .copy(.notPermitted) }
        guard session.isOpen, session.sessionGeneration == latestSessionGeneration,
              system.frontmostTarget() == target else { return .copy(.targetChanged) }
        guard !system.isSecureInputEnabled() else { return .copy(.secureInput) }
        guard system.commandVKeyCode() != nil else { return .copy(.cannotSendKeystroke) }
        return .paste(target)
    }

    /// Asks the system for access, and opens Accessibility settings when it is not granted: once the user has
    /// denied it, the system no longer asks.
    func requestDirectPasteAccess() {
        if !system.requestPostEventAccess() { system.openAccessibilitySettings() }
    }

    func execute(_ request: PasteRequest) async -> PasteOutcome {
        let session = request.session
        let generation = request.queryGeneration
        guard session.accepts(generation) else { return .refused(.stale) }

        let content: ResolvedContent
        do {
            content = try await read(request.ref)
        } catch {
            return .refused(session.accepts(generation) ? .contentUnavailable : .stale)
        }
        guard session.accepts(generation) else { return .refused(.stale) }

        let mode = request.mode
        let prepared: PreparedPasteboardContent
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                switch mode {
                case .original: try PasteboardWriter.prepare(content)
                case .plainText: try PasteboardWriter.preparePlainText(content)
                }
            }.value
        } catch {
            guard session.accepts(generation) else { return .refused(.stale) }
            return .refused(error as? PasteboardWriterError == .noPlainText ? .noPlainText : .contentUnavailable)
        }
        guard session.accepts(generation) else { return .refused(.stale) }
        return deliver(prepared, for: request)
    }

    /// Writes the clip and, for a paste whose checks all pass before the write and again after the panel hides,
    /// posts one ⌘V. It is synchronous so that the compiler rejects any suspension here: nothing else on the main
    /// actor runs between the checks, the write, hiding the panel and the keystroke.
    private func deliver(_ prepared: PreparedPasteboardContent, for request: PasteRequest) -> PasteOutcome {
        let session = request.session
        let check: DirectPasteAvailability?
        switch request.delivery {
        case .copy:
            check = nil
        case .paste where request.dismiss == nil:
            // Never post while the panel may still be key: the keystroke could reach Keeptide's own panel.
            reportProgrammingError("A paste request must be able to hide the panel before ⌘V is posted.")
            check = .copy(.cannotSendKeystroke)
        case .paste:
            check = availability(for: session)
        }
        let token: OwnWriteToken
        do {
            token = try PasteboardWriter(pasteboard: pasteboard).write(prepared)
        } catch {
            return .refused(.writeFailed)
        }
        didWrite(token)
        // The copy is done once the clipboard is written, whatever happens to the paste: one receipt per
        // action, stored without holding up the caller. One that cannot be stored never undoes the copy.
        let recordUse = recordUse
        let receipt = UseReceipt(ref: request.ref, outcome: .success)
        Task { try? await recordUse(receipt) }
        switch check {
        case nil: return .copied
        case .copy(let fallback)?: return .copiedInstead(fallback)
        case .paste?: break
        }
        request.dismiss?()
        // Hiding the panel can bring another window forward, so every check runs again.
        switch availability(for: session) {
        case .copy(let fallback):
            return .copiedInstead(fallback)
        case .paste(let target):
            // Resolved again here, after `dismiss`: the keyboard layout can change while the panel hides.
            guard let keyCode = system.commandVKeyCode(), system.postCommandV(keyCode) else {
                return .copiedInstead(.cannotSendKeystroke)
            }
            return .dispatched(target)
        }
    }
}
