import SwiftUI

/// The one page of the Settings window. Each control writes its preference at once.
struct SettingsView: View {
    @Bindable var preferences: QuickAccessPreferences

    var body: some View {
        Form {
            Section {
                Picker("Clips in a row", selection: $preferences.density) {
                    Text("7 · Larger previews").tag(StripDensity.seven)
                    Text("9 · Balanced").tag(StripDensity.nine)
                    Text("11 · More at a glance").tag(StripDensity.eleven)
                }
                .pickerStyle(.radioGroup)
                DensityPreview(count: preferences.density.rawValue)
                Toggle("Tick on the trackpad as each clip passes", isOn: $preferences.trackpadTicks)
                    .controlSize(.mini)
            } header: {
                Text("Quick Access")
            } footer: {
                Text("Fewer clips in a row give each one a larger preview. Space always shows the selected clip in full. Ticks play on a Force Touch trackpad while your fingers are on it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

/// A small, inert picture of the strip: `count` clips in a row, the outer ones fading out and the
/// selected one in the middle. Its height is fixed, so the window keeps its size as the count changes.
private struct DensityPreview: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay {
                        if index == count / 2 {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 2)
                        }
                    }
            }
        }
        .mask(LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: StripLayout.fade),
            .init(color: .black, location: 1 - StripLayout.fade),
            .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing))
        .padding(8)
        .frame(height: 44)
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
