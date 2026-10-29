import SwiftUI

/// The one page of the Settings window. Each control writes its preference at once.
struct SettingsView: View {
    @Bindable var preferences: QuickAccessPreferences

    var body: some View {
        Form {
            Section {
                Picker("Card size", selection: $preferences.cardSize) {
                    ForEach(CardSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.radioGroup)
                StripPreview()
                Toggle("Tick on the trackpad as each clip passes", isOn: $preferences.trackpadTicks)
                    .controlSize(.mini)
            } header: {
                Text("Quick Access")
            } footer: {
                Text("Larger cards show more of each clip. Space always shows the selected clip in full. Ticks play on a Force Touch trackpad while your fingers are on it.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
    }
}

extension CardSize {
    /// The name the Settings window gives the size.
    var title: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

/// A small, inert picture of the strip as it opens: the newest card selected at the band's left end, which is hard,
/// the next one beside it, and a third cut off by the right edge. It is the same for every card size.
private struct StripPreview: View {
    private static let card = CGSize(width: 52, height: 57)
    private static let gap: CGFloat = 8
    /// How far in from the band's edges the first card rests.
    private static let inset: CGFloat = 10
    /// The band shows two cards and half of a third.
    private static let band = CGSize(width: inset + 2 * (card.width + gap) + card.width / 2,
                                     height: card.height + 2 * inset)

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .frame(width: Self.card.width, height: Self.card.height)
                    .overlay {
                        if index == 0 {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 2)
                                .padding(-4)
                        }
                    }
            }
        }
        .padding(.leading, Self.inset)
        .frame(width: Self.band.width, height: Self.band.height, alignment: .leading)
        .background(.quaternary, in: .rect(cornerRadius: 12))
        .clipShape(.rect(cornerRadius: 12))
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
