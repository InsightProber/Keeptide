import SwiftUI

struct OnboardingActions {
    var startRecording: @MainActor () -> Void
    var notNow: @MainActor () -> Void
    var openLibrary: @MainActor () -> Void
}

struct OnboardingView: View {
    let actions: OnboardingActions

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image(systemName: "clipboard.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Keeptide")
                    .font(.largeTitle.bold())
                Text("Clipboard history and a reusable library for the commands, prompts, links, and notes you use again.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                Label("Recording starts only after you choose Start Recording.", systemImage: "record.circle")
                Label("You can use the Library and create notes without recording your clipboard.", systemImage: "note.text")
                Label("Keeptide does not request Accessibility or cloud access here.", systemImage: "hand.raised")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Library", action: actions.openLibrary)
                    .accessibilityIdentifier("OnboardingOpenLibrary")
                Spacer()
                Button("Not Now", action: actions.notNow)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("OnboardingNotNow")
                Button("Start Recording", action: actions.startRecording)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("OnboardingStartRecording")
            }
        }
        .padding(32)
        .frame(width: 560)
    }
}
