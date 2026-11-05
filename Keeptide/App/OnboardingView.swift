import SwiftUI

/// The welcome only explains: Keeptide records from first launch, and neither choice changes that.
struct OnboardingActions {
    var done: @MainActor () -> Void
    var openLibrary: @MainActor () -> Void
}

struct OnboardingView: View {
    let actions: OnboardingActions

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Image("BrandMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
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
                Label("Keeptide saves what you copy. Pause or resume it anytime from the menu bar or Settings.",
                      systemImage: "record.circle")
                Label("You can use the Library and create notes without recording your clipboard.", systemImage: "note.text")
                Label("Keeptide does not request Accessibility or cloud access here.", systemImage: "hand.raised")
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Open Library", action: actions.openLibrary)
                    .accessibilityIdentifier("OnboardingOpenLibrary")
                Spacer()
                Button("Done", action: actions.done)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("OnboardingDone")
            }
        }
        .padding(32)
        .frame(width: 560)
    }
}
