import AppKit
import Observation
import SwiftUI

struct ExportSuccess: Equatable, Sendable {
    let destination: URL
    let itemCount: Int
}

enum ExportCoordinatorPhase: Equatable, Sendable {
    case idle
    case preparing
    case choosingFolder
    case exporting(ExportProgress)
    case succeeded(ExportSuccess)
    case failed(String)
}

enum ExportPreparationError: Error, Equatable, Sendable {
    case compositionInProgress
    case selectionChanged
    case saveFailed
    case unavailable
}

enum ExportSelectionResolver {
    static func selectedScope(
        requested: [ContentRef],
        editorRef: ContentRef?,
        flushedRef: ContentRef?,
        displayed: [ContentRef]
    ) throws -> SnapshotScope {
        guard !requested.isEmpty else { throw ExportPreparationError.unavailable }
        var refs = requested
        if let editorRef,
           refs.contains(where: { $0.itemID == editorRef.itemID && $0.facet == editorRef.facet }) {
            guard refs.contains(editorRef) else { throw ExportPreparationError.selectionChanged }
            if let flushedRef, flushedRef != editorRef {
                guard flushedRef.itemID == editorRef.itemID, flushedRef.facet == editorRef.facet else {
                    throw ExportPreparationError.selectionChanged
                }
                refs = refs.map { $0 == editorRef ? flushedRef : $0 }
            }
        }
        guard displayed == requested || displayed == refs else {
            throw ExportPreparationError.selectionChanged
        }
        return .selected(refs)
    }
}

@MainActor @Observable
final class ExportCoordinator {
    typealias ScopePreparation = @MainActor () async throws -> SnapshotScope
    typealias ChooseFolder = @MainActor () async -> URL?

    @ObservationIgnored private let exporter: any Exporting
    @ObservationIgnored private let chooseFolder: ChooseFolder
    @ObservationIgnored private let cancelFolderChoice: @MainActor () -> Void
    @ObservationIgnored private let reveal: @MainActor (URL) -> Void
    private var operation: Task<Void, Never>?
    @ObservationIgnored private var runID: UUID?
    @ObservationIgnored private var acceptsProgress = false
    private var closed = false

    private(set) var phase: ExportCoordinatorPhase = .idle

    var canStart: Bool { !closed && operation == nil }

    var presentsStatus: Bool {
        switch phase {
        case .exporting, .succeeded, .failed: true
        case .idle, .preparing, .choosingFolder: false
        }
    }

    init(
        exporter: any Exporting,
        chooseFolder: @escaping ChooseFolder,
        cancelFolderChoice: @escaping @MainActor () -> Void = {},
        reveal: @escaping @MainActor (URL) -> Void = {
            NSWorkspace.shared.activateFileViewerSelecting([$0])
        }
    ) {
        self.exporter = exporter
        self.chooseFolder = chooseFolder
        self.cancelFolderChoice = cancelFolderChoice
        self.reveal = reveal
    }

    static func production(exporter: any Exporting) -> ExportCoordinator {
        let picker = ExportFolderPicker()
        return ExportCoordinator(
            exporter: exporter,
            chooseFolder: { await picker.chooseFolder() },
            cancelFolderChoice: { picker.cancel() }
        )
    }

    func start(preparingScope: @escaping ScopePreparation) {
        guard canStart else { return }
        let id = UUID()
        runID = id
        phase = .preparing
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(id: id, preparingScope: preparingScope)
        }
    }

    func cancel() {
        guard operation != nil else { return }
        acceptsProgress = false
        cancelFolderChoice()
        operation?.cancel()
        phase = .idle
    }

    func dismissResult() {
        guard operation == nil else { return }
        switch phase {
        case .succeeded, .failed: phase = .idle
        default: break
        }
    }

    func showInFinder() {
        guard case .succeeded(let result) = phase else { return }
        reveal(result.destination)
    }

    func stopAndDrain() async {
        closed = true
        acceptsProgress = false
        cancelFolderChoice()
        let current = operation
        current?.cancel()
        await current?.value
        operation = nil
        runID = nil
        phase = .idle
    }

    private func run(id: UUID, preparingScope: @escaping ScopePreparation) async {
        defer { finishRun(id) }
        do {
            let scope = try await preparingScope()
            try Task.checkCancellation()
            guard runID == id else { return }
            phase = .choosingFolder
            guard let destinationParent = await chooseFolder() else {
                guard runID == id else { return }
                phase = .idle
                return
            }
            try Task.checkCancellation()
            guard runID == id else { return }

            phase = .exporting(.preparing)
            acceptsProgress = true
            let usesSecurityScope = destinationParent.startAccessingSecurityScopedResource()
            defer {
                if usesSecurityScope { destinationParent.stopAccessingSecurityScopedResource() }
            }
            let result = try await exporter.export(
                ExportRequest(scope: scope, destinationParent: destinationParent)
            ) { [weak self] progress in
                Task { @MainActor in self?.receive(progress, for: id) }
            }
            // A returned result means the exclusive rename already committed.
            // A late cancellation cannot turn that published result into "cancelled".
            guard runID == id else { return }
            acceptsProgress = false
            phase = .succeeded(ExportSuccess(
                destination: result.destination,
                itemCount: result.verification.entryCount
            ))
        } catch is CancellationError {
            guard runID == id else { return }
            phase = .idle
        } catch let error as ExportError where error == .cancelled {
            guard runID == id else { return }
            phase = .idle
        } catch {
            guard runID == id else { return }
            acceptsProgress = false
            phase = .failed(Self.message(for: error))
        }
    }

    private func receive(_ progress: ExportProgress, for id: UUID) {
        guard runID == id, acceptsProgress else { return }
        phase = .exporting(progress)
    }

    private func finishRun(_ id: UUID) {
        guard runID == id else { return }
        acceptsProgress = false
        runID = nil
        operation = nil
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ExportPreparationError {
            switch error {
            case .compositionInProgress:
                return "Finish text composition before exporting."
            case .selectionChanged:
                return "The selection changed before it could be exported."
            case .saveFailed:
                return "Your current changes could not be saved, so nothing was exported."
            case .unavailable:
                return "Export is not available for the current view."
            }
        }
        guard let error = error as? ExportError else {
            return "The export could not be completed. No archive was published."
        }
        switch error {
        case .cancelled:
            return "The export was cancelled. No archive was published."
        case .diskWriteFailed:
            return "There is not enough space to finish this export, or the selected folder could not be written."
        case .changedSelection:
            return "The selection changed before it could be exported."
        case .snapshotExpired:
            return "The export could not be completed because its snapshot expired."
        case .destinationExists:
            return "An export with the generated name already exists. Choose another folder and try again."
        case .unsupportedDestination:
            return "The selected folder cannot safely publish this export."
        case .verificationFailed:
            return "The export could not be verified. No archive was published."
        case .unknown:
            return "The export could not be completed. No archive was published."
        }
    }
}

@MainActor
private final class ExportFolderPicker {
    private var panel: NSOpenPanel?

    func chooseFolder() async -> URL? {
        guard panel == nil else { return nil }
        let panel = NSOpenPanel()
        panel.title = "Export Keeptide Library"
        panel.message = "Choose a folder where Keeptide can create a new export directory."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        self.panel = panel
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                panel.begin { [weak self] response in
                    self?.panel = nil
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        panel?.cancel(nil)
    }
}

struct ExportStatusView: View {
    @Bindable var coordinator: ExportCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            Text(message).foregroundStyle(.secondary)
            if case .exporting = coordinator.phase { ProgressView().controlSize(.small) }
            HStack {
                Spacer()
                switch coordinator.phase {
                case .exporting:
                    Button("Cancel") { coordinator.cancel() }
                        .keyboardShortcut(.cancelAction)
                case .succeeded:
                    Button("Show in Finder") { coordinator.showInFinder() }
                    Button("Done") { coordinator.dismissResult() }
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close") { coordinator.dismissResult() }
                        .keyboardShortcut(.defaultAction)
                default:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 430)
        .accessibilityIdentifier("ExportStatus")
    }

    private var title: String {
        switch coordinator.phase {
        case .succeeded: "Export Complete"
        case .failed: "Export Failed"
        default: "Exporting"
        }
    }

    private var message: String {
        switch coordinator.phase {
        case .exporting(.preparing): "Preparing the current local snapshot…"
        case .exporting(.writing(let completed)): "Writing \(completed) items…"
        case .exporting(.verifying): "Verifying every exported file…"
        case .exporting(.publishing): "Publishing the verified export…"
        case .succeeded(let result): "Exported \(result.itemCount) items from this Mac."
        case .failed(let message): message
        default: ""
        }
    }
}
