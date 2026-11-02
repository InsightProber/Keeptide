import SwiftUI

enum CollectionEditorMode: Equatable, Identifiable {
    case create
    case edit(CollectionSnapshot)

    var title: String {
        switch self {
        case .create: "New Collection"
        case .edit: "Edit Collection"
        }
    }

    var id: String {
        switch self {
        case .create: "create"
        case .edit(let snapshot): "edit-\(snapshot.value.id.rawValue.uuidString)"
        }
    }
}

struct CollectionEditorSheet: View {
    static let colors = ["blue", "purple", "pink", "red", "orange", "yellow", "green", "teal", "gray"]

    let mode: CollectionEditorMode
    let onSave: @MainActor (String, String) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var color: String
    @State private var isSaving = false
    @State private var showsSaveFailure = false

    init(mode: CollectionEditorMode, onSave: @escaping @MainActor (String, String) async -> Bool) {
        self.mode = mode
        self.onSave = onSave
        switch mode {
        case .create:
            _name = State(initialValue: "")
            _color = State(initialValue: Self.colors[0])
        case .edit(let snapshot):
            _name = State(initialValue: snapshot.value.name)
            _color = State(initialValue: snapshot.value.color)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(mode.title)
                .font(.title2.weight(.semibold))

            Form {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("CollectionNameField")

                Picker("Color", selection: $color) {
                    ForEach(Self.colors, id: \.self) { value in
                        Label(value.capitalized, systemImage: "circle.fill")
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(displayColor(value))
                            .tag(value)
                    }
                }
                .accessibilityIdentifier("CollectionColorPicker")
            }
            .formStyle(.grouped)

            if showsSaveFailure {
                Label("The collection could not be saved. Your content was not changed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("CollectionSaveFailure")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(mode == .create ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || isSaving)
                    .accessibilityIdentifier("CollectionSaveButton")
            }
        }
        .padding(24)
        .frame(width: 420)
        .disabled(isSaving)
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        let submittedName = trimmedName
        guard !submittedName.isEmpty else { return }
        isSaving = true
        showsSaveFailure = false
        Task {
            let saved = await onSave(submittedName, color)
            isSaving = false
            if saved { dismiss() } else { showsSaveFailure = true }
        }
    }

    private func displayColor(_ value: String) -> Color {
        switch value {
        case "purple": .purple
        case "pink": .pink
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "teal": .teal
        case "gray": .gray
        default: .blue
        }
    }
}
