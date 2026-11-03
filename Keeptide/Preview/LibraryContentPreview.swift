import SwiftUI

struct LibraryPreviewRequest: Equatable, Hashable, Sendable {
    let ref: ContentRef
    let kind: ContentKind
    let maximumImagePixels: Int
}

struct LibraryOriginalPreviewRequest: Equatable, Hashable, Sendable {
    let preview: LibraryPreviewRequest
    let generation: UInt64
}

enum LibraryPreviewPhase: Equatable {
    case idle
    case loading(LibraryPreviewRequest)
    case ready(LibraryPreviewRequest, PreviewContent)

    mutating func begin(_ request: LibraryPreviewRequest) {
        self = .loading(request)
    }

    mutating func complete(
        _ content: PreviewContent,
        for request: LibraryPreviewRequest,
        current: LibraryPreviewRequest
    ) {
        guard request == current else { return }
        self = .ready(request, content)
    }

    func content(for request: LibraryPreviewRequest) -> PreviewContent? {
        guard case .ready(let completed, let content) = self,
              completed == request else { return nil }
        return content
    }
}

/// Store-fresh Library preview state around the shared preview service and renderer.
/// Results are accepted only for the exact content reference and request currently shown.
struct LibraryContentPreview: View {
    let ref: ContentRef
    let kind: ContentKind
    let service: PreviewService?
    var fileAccessStore: FileAccessStore? = nil
    var fileAccessIdentity: StoreIdentity? = nil
    var applicationName: String? = nil
    var maximumImagePixels = 2_048

    @State private var phase = LibraryPreviewPhase.idle
    @State private var originalGeneration: UInt64 = 0
    @State private var isLoadingOriginal = false
    @State private var previewMessage: String?

    private var request: LibraryPreviewRequest {
        LibraryPreviewRequest(
            ref: ref,
            kind: kind,
            maximumImagePixels: maximumImagePixels
        )
    }

    private var originalRequest: LibraryOriginalPreviewRequest {
        LibraryOriginalPreviewRequest(preview: request, generation: originalGeneration)
    }

    var body: some View {
        QuickAccessPreviewView(
            preview: phase.content(for: request),
            applicationName: applicationName,
            fileAccessStore: fileAccessStore,
            fileAccessIdentity: fileAccessIdentity,
            isLoadingOriginal: isLoadingOriginal,
            previewMessage: previewMessage,
            onRequestOriginal: requestOriginalImage
        )
        .accessibilityIdentifier("LibraryContentPreview")
        .task(id: request) { await loadPreview(request) }
        .task(id: originalRequest) { await loadOriginalImage(originalRequest) }
    }

    private func requestOriginalImage() {
        guard originalGeneration < UInt64.max,
              case .image = phase.content(for: request) else { return }
        originalGeneration += 1
    }

    @MainActor
    private func loadPreview(_ requested: LibraryPreviewRequest) async {
        phase.begin(requested)
        originalGeneration = 0
        isLoadingOriginal = false
        previewMessage = nil
        guard let service else {
            phase.complete(.failed(.contentUnavailable), for: requested, current: request)
            return
        }
        do {
            let content = try await service.preview(
                for: requested.ref,
                kind: requested.kind,
                maximumImagePixels: requested.maximumImagePixels
            )
            guard !Task.isCancelled else { return }
            phase.complete(content, for: requested, current: request)
        } catch is CancellationError {
            // A newer reference or a removed view owns the result.
        } catch {
            guard !Task.isCancelled else { return }
            phase.complete(.failed(.contentUnavailable), for: requested, current: request)
        }
    }

    @MainActor
    private func loadOriginalImage(_ requested: LibraryOriginalPreviewRequest) async {
        guard requested.generation > 0,
              requested == originalRequest,
              case .image = phase.content(for: requested.preview),
              let service else { return }
        isLoadingOriginal = true
        previewMessage = nil
        defer {
            if requested == originalRequest { isLoadingOriginal = false }
        }
        do {
            guard let loaded = try await service.originalImage(for: requested.preview.ref) else {
                guard !Task.isCancelled, requested == originalRequest else { return }
                previewMessage = "The original image could not be decoded."
                return
            }
            guard !Task.isCancelled, requested == originalRequest else { return }
            phase.complete(
                .image(loaded.image, pixelSize: loaded.pixelSize),
                for: requested.preview,
                current: request
            )
        } catch is CancellationError {
            // A newer reference, request, or removed view owns the result.
        } catch PreviewLoadError.originalImageTooLarge {
            guard !Task.isCancelled, requested == originalRequest else { return }
            previewMessage = "This image is too large to load at full resolution. The fitted preview remains available."
        } catch {
            guard !Task.isCancelled, requested == originalRequest else { return }
            previewMessage = "The original image could not be loaded. The fitted preview remains available."
        }
    }
}
