import AppKit
import Foundation

enum PasteMode: Equatable, Sendable {
    case original, plainText
}

enum PasteRefusal: Equatable, Sendable {
    /// A newer query, selection or session owns the action now.
    case stale
    /// The content changed, was removed, or cannot be written in its original formats.
    case contentUnavailable
    case noPlainText
    case writeFailed
}

enum PasteOutcome: Equatable, Sendable {
    case copied
    case refused(PasteRefusal)
}

/// One panel or library session. A request carries the query generation it was
/// made for; advancing the generation or ending the session refuses it.
@MainActor
final class PasteSession {
    /// Shared by every session, so a number from one session never matches another's.
    private static var lastGeneration: UInt64 = 0
    private(set) var queryGeneration: UInt64 = 0
    private(set) var isOpen = true

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
}

/// The one path from a selected row to the clipboard. It re-reads the content,
/// re-checks the request after every suspension, and records one use receipt
/// per successful action.
@MainActor
final class PasteService {
    private let pasteboard: NSPasteboard
    private let read: @Sendable (ContentRef) async throws -> ResolvedContent
    private let recordUse: @Sendable (UseReceipt) async throws -> Void
    private let didWrite: @MainActor (OwnWriteToken) -> Void

    init(pasteboard: NSPasteboard,
         read: @escaping @Sendable (ContentRef) async throws -> ResolvedContent,
         recordUse: @escaping @Sendable (UseReceipt) async throws -> Void,
         didWrite: @escaping @MainActor (OwnWriteToken) -> Void) {
        self.pasteboard = pasteboard
        self.read = read
        self.recordUse = recordUse
        self.didWrite = didWrite
    }

    func beginSession() -> PasteSession {
        PasteSession()
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

        let token: OwnWriteToken
        do {
            token = try PasteboardWriter(pasteboard: pasteboard).write(prepared)
        } catch {
            return .refused(.writeFailed)
        }
        didWrite(token)
        // The copy is done once the clipboard is written: the receipt is stored without
        // holding up the caller, and one that cannot be stored never undoes the copy.
        let recordUse = recordUse
        let receipt = UseReceipt(ref: request.ref, outcome: .success)
        Task { try? await recordUse(receipt) }
        return .copied
    }
}
