import AppKit
import Observation
import SwiftUI

@MainActor
protocol FilePreviewPicking: AnyObject {
    func choose(isReattachment: Bool) async -> URL?
    func cancel()
}

@MainActor
final class SystemFilePreviewPicker: FilePreviewPicking {
    private var panel: NSOpenPanel?
    private var completion: CheckedContinuation<URL?, Never>?

    func choose(isReattachment: Bool) async -> URL? {
        cancel()
        let panel = NSOpenPanel()
        panel.title = isReattachment ? "Reattach Referenced File" : "Allow File Preview"
        panel.message = isReattachment
            ? "The original local reference is missing. Your selected file will be used for preview and copying on this Mac."
            : "Choose the originally referenced file to allow its preview. A different file cannot replace the original."
        panel.prompt = isReattachment ? "Reattach File" : "Allow Preview"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.canDownloadUbiquitousContents = false
        self.panel = panel
        return await withCheckedContinuation { continuation in
            completion = continuation
            let finish: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
                guard let self, let panel, self.panel === panel else { return }
                self.finish(response == .OK ? panel.url : nil)
            }
            if let parent = NSApp.keyWindow {
                panel.beginSheetModal(for: parent, completionHandler: finish)
            } else {
                panel.begin(completionHandler: finish)
            }
        }
    }

    func cancel() {
        panel?.cancel(nil)
        finish(nil)
    }

    private func finish(_ url: URL?) {
        let continuation = completion
        completion = nil
        panel = nil
        continuation?.resume(returning: url)
    }
}

/// File permission belongs to a particular local reference, never to a title or
/// a search result position. Quick Look retains the lease until its own teardown.
@MainActor @Observable
final class FilePreviewCoordinator {
    private(set) var lease: FilePreviewAccessLease?
    private(set) var isLoading = false
    private(set) var message: String?
    private(set) var reference: FilePreviewReference?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private let store: FileAccessStore
    private let identity: StoreIdentity
    private let picker: any FilePreviewPicking
    private let openAccess: @Sendable (Data) async throws -> FilePreviewAccessLease

    init(
        store: FileAccessStore,
        identity: StoreIdentity,
        picker: any FilePreviewPicking = SystemFilePreviewPicker(),
        openAccess: @escaping @Sendable (Data) async throws -> FilePreviewAccessLease = { bookmark in
            let operation = Task.detached(priority: .userInitiated) {
                try FilePreviewAccessLease.open(bookmarkData: bookmark, isCancelled: { Task.isCancelled })
            }
            return try await withTaskCancellationHandler {
                try await operation.value
            } onCancel: { operation.cancel() }
        }
    ) {
        self.store = store
        self.identity = identity
        self.picker = picker
        self.openAccess = openAccess
    }

    func select(_ requested: FilePreviewReference) {
        cancel()
        reference = requested
        let request = generation
        isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.isLoading = false } }
            do {
                let latest = try await self.store.filePreviewReferences(for: requested.ref, expecting: self.identity)
                guard !Task.isCancelled, self.generation == request,
                      let current = latest.first(where: { $0.representationID == requested.representationID }) else { return }
                self.reference = current
                if current.bindingSupport == .missingLegacyDescriptor {
                    self.message = "This older reference is missing its original local descriptor. Copy the file again to create a new, verifiable reference."
                    return
                }
                guard current.bindingSupport == .supportedFileURL else {
                    self.message = "This clipboard format contains a file list. Preview an individual file reference instead."
                    return
                }
                guard let access = current.localAccess, let bookmark = access.bookmark else {
                    self.message = current.localAccess == nil
                        ? "The original local reference is missing. Reattach a file to use it for preview and copying on this Mac."
                        : "Allow access to the originally referenced file to preview it. Referenced files are not stored in your library."
                    return
                }
                let opened = try await self.openAccess(bookmark)
                guard !Task.isCancelled, self.generation == request else { opened.close(); return }
                guard FileReferenceIdentity.matches(access, candidateURL: opened.url) else {
                    opened.close()
                    self.message = "The file permission points to a different file. Choose the originally referenced file, or copy it again."
                    return
                }
                do {
                    if let refreshed = opened.refreshedBookmarkData {
                        _ = try await self.store.refreshBookmark(
                            for: current, bookmarkData: refreshed, resolvedFileURL: opened.url,
                            expecting: access, identity: self.identity
                        )
                    }
                    // Recheck after bookmark resolution: deletion or a new binding
                    // while the OS resolves the URL must not publish stale access.
                    let checked = try await self.store.filePreviewReferences(for: current.ref, expecting: self.identity)
                    guard !Task.isCancelled, self.generation == request,
                          let stillCurrent = checked.first(where: { $0.representationID == current.representationID }),
                          stillCurrent.localAccess?.bytes == access.bytes,
                          stillCurrent.localAccess?.bookmark == (opened.refreshedBookmarkData ?? bookmark) else {
                        opened.close()
                        return
                    }
                    self.reference = stillCurrent
                    self.lease = opened
                } catch {
                    opened.close()
                    throw error
                }
            } catch {
                guard !Task.isCancelled, self.generation == request else { return }
                self.message = "The file could not be opened. Locate it again, or return to your clips."
            }
        }
    }

    func settle() async { await task?.value }

    func cancel() {
        generation = UUID()
        picker.cancel()
        task?.cancel()
        task = nil
        // Do not close here: the NSView must clear and close Quick Look first.
        // An unpublished lease has no view owner and closes in deinit instead.
        lease = nil
        isLoading = false
        message = nil
        reference = nil
    }

    func locate() async {
        guard let current = reference, current.bindingSupport == .supportedFileURL, !isLoading else { return }
        let request = generation
        isLoading = true
        defer { if generation == request { isLoading = false } }
        let selected = await picker.choose(isReattachment: current.localAccess == nil)
        guard let url = selected, generation == request, !Task.isCancelled else { return }
        do {
            let bookmark = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil
                )
            }.value
            guard generation == request, !Task.isCancelled else { return }
            _ = try await store.bind(current, selectedFileURL: url, bookmarkData: bookmark,
                                     expecting: current.localAccess, identity: identity)
            guard generation == request, !Task.isCancelled else { return }
            select(current)
        } catch FilePreviewReferenceError.differentFileReference {
            guard generation == request, !Task.isCancelled else { return }
            message = "That is a different file. Choose the originally referenced file, or copy the new file to create a separate clip."
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            message = "The file permission could not be saved. Your original clipboard content is unchanged."
        }
    }
}

struct FilePreviewPane: View {
    let references: [FilePreviewReference]
    let store: FileAccessStore?
    let identity: StoreIdentity?
    @State private var coordinator: FilePreviewCoordinator?
    @State private var selectedID: UUID?

    var body: some View {
        VStack(spacing: 10) {
            if references.count > 1 {
                Picker("File", selection: $selectedID) {
                    ForEach(references, id: \.representationID) { reference in
                        Text(verbatim: name(reference)).tag(Optional(reference.representationID))
                    }
                }
                .accessibilityIdentifier("PreviewFilePicker")
            }
            if let lease = coordinator?.lease {
                FilePreview(lease: lease)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if coordinator?.isLoading == true {
                ProgressView("Opening file…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("File Preview", systemImage: "doc")
                } description: {
                    Text(coordinator?.message ?? "This file needs permission on this Mac.")
                }
            }
            if let coordinator, coordinator.reference?.bindingSupport == .supportedFileURL {
                Button(coordinator.reference?.localAccess == nil ? "Reattach File…" : "Allow File Preview…") {
                    Task { await coordinator.locate() }
                }
                .disabled(coordinator.isLoading)
                .accessibilityIdentifier("LocatePreviewFile")
            }
        }
        .padding(12)
        .task(id: references.first?.ref) { configure() }
        .onChange(of: references) { _, _ in configure() }
        .onChange(of: selectedID) { _, _ in select() }
        .onDisappear { coordinator?.cancel() }
    }

    private func configure() {
        coordinator?.cancel()
        guard let store, let identity else { coordinator = nil; return }
        coordinator = FilePreviewCoordinator(store: store, identity: identity)
        selectedID = references.first(where: { $0.bindingSupport == .supportedFileURL })?.representationID
            ?? references.first?.representationID
        select()
    }

    private func select() {
        guard let reference = references.first(where: { $0.representationID == selectedID }) else {
            coordinator?.cancel()
            return
        }
        coordinator?.select(reference)
    }

    private func name(_ reference: FilePreviewReference) -> String {
        reference.displayName ?? "File \(reference.itemIndex + 1)"
    }
}
