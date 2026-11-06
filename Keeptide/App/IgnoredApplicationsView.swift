import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sheet over Settings › Privacy that lists the applications whose copies are skipped.
struct IgnoredApplicationsView: View {
    @Bindable var preferences: CapturePreferences
    @Environment(\.dismiss) private var dismiss
    @State private var manualBundleID = ""
    @State private var showsApplicationPicker = false
    @State private var applicationPickerMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ignored Applications")
                        .font(.title2.weight(.semibold))
                    Text("New copies observed from these apps are skipped. Source identification is best effort.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            if preferences.excludedApplications.isEmpty {
                ContentUnavailableView(
                    "No ignored apps",
                    systemImage: "hand.raised.slash",
                    description: Text("Choose an application or add its bundle identifier.")
                )
            } else {
                List(preferences.excludedApplications, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID).textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            preferences.removeExclusion(bundleID)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(bundleID)")
                    }
                }
                .frame(minHeight: 150)
            }

            HStack {
                Button("Choose Application…") { showsApplicationPicker = true }
                TextField("Bundle identifier", text: $manualBundleID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManualBundleID)
                Button("Add", action: addManualBundleID)
                    .disabled(manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let applicationPickerMessage {
                Label(applicationPickerMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("IgnoredApplicationPickerMessage")
            }
        }
        .padding(24)
        .frame(minWidth: 560, minHeight: 360)
        .fileImporter(
            isPresented: $showsApplicationPicker,
            allowedContentTypes: [.application],
            allowsMultipleSelection: false,
            onCompletion: handleApplicationPicker
        )
    }

    private func addManualBundleID() {
        let bundleID = manualBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bundleID.isEmpty else { return }
        preferences.addExclusion(bundleID)
        manualBundleID = ""
    }

    private func handleApplicationPicker(_ result: Result<[URL], any Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else {
                applicationPickerMessage = "The selected application does not provide a readable bundle identifier."
                return
            }
            preferences.addExclusion(bundleID)
            applicationPickerMessage = nil
        case let .failure(error):
            if (error as NSError).code == NSUserCancelledError { return }
            applicationPickerMessage = "Keeptide could not read the selected application. No app was added."
        }
    }
}
