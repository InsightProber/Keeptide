import SwiftUI

enum MarkdownReadingMode: String, CaseIterable, Identifiable, Sendable {
    case source
    case preview

    var id: Self { self }
}

struct MarkdownReadingRequest: Equatable, Hashable, Sendable {
    let documentID: UUID
    let source: String
}

enum MarkdownReadingPhase: Equatable, Sendable {
    case idle
    case loading(MarkdownReadingRequest)
    case ready(MarkdownReadingRequest, MarkdownPreviewDocument)

    mutating func begin(_ request: MarkdownReadingRequest) {
        self = .loading(request)
    }

    mutating func complete(
        _ document: MarkdownPreviewDocument,
        for request: MarkdownReadingRequest,
        current: MarkdownReadingRequest
    ) {
        guard request == current else { return }
        self = .ready(request, document)
    }

    func document(for request: MarkdownReadingRequest) -> MarkdownPreviewDocument? {
        guard case .ready(let completed, let document) = self,
              completed == request else { return nil }
        return document
    }
}

/// A read-only Markdown surface whose parser never runs on the main actor.
/// The exact document and source are fenced so an obsolete parse is never shown.
struct MarkdownReadingView: View {
    let documentID: UUID
    let source: String

    @State private var phase = MarkdownReadingPhase.idle

    private var request: MarkdownReadingRequest {
        MarkdownReadingRequest(documentID: documentID, source: source)
    }

    var body: some View {
        Group {
            if let document = phase.document(for: request) {
                ScrollView {
                    MarkdownPreviewView(document: document)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                }
                .accessibilityIdentifier("MarkdownPreviewReadingView")
            } else {
                ProgressView("Rendering preview…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("MarkdownPreviewLoading")
            }
        }
        .task(id: request) {
            let requested = request
            phase.begin(requested)
            let parsing = Task.detached(priority: .userInitiated) {
                MarkdownRenderer.parse(requested.source)
            }
            let document = await withTaskCancellationHandler {
                await parsing.value
            } onCancel: {
                parsing.cancel()
            }
            guard !Task.isCancelled else { return }
            phase.complete(document, for: requested, current: self.request)
        }
    }
}
