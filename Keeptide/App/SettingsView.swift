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
                Text("Larger cards give each clip more room and larger type. Space always shows the selected clip in full. Ticks play on a Force Touch trackpad while your fingers are on it.")
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
/// the next one beside it, and a third cut off by the right edge. Each card has its colour band, as the strip's cards
/// take theirs from their apps' icons. It is the same for every card size.
private struct StripPreview: View {
    private static let card = CGSize(width: 52, height: 57)
    /// The medium card the miniature is drawn after, and how much smaller the miniature is.
    private static let medium = StripLayout.cardDimensions(for: .medium)
    private static let scale = card.width / medium.frame.width
    /// A card's colour band and its corners, in proportion to the medium card's.
    private static let colourBand = (medium.header * scale).rounded()
    private static let cornerRadius = medium.radius * scale
    /// Bands of an orange app, a yellow one and a blue one, which show on the band in either appearance.
    private static let tints: [UInt32] = [0xB85410, 0xE3B528, 0x2563C9]
    private static let gap: CGFloat = 8
    /// How far in from the band's edges the first card rests.
    private static let inset: CGFloat = 10
    /// The band shows two cards and half of a third.
    private static let band = CGSize(width: inset + 2 * (card.width + gap) + card.width / 2,
                                     height: card.height + 2 * inset)

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Self.gap) {
            ForEach(0..<3, id: \.self) { index in
                VStack(spacing: 0) {
                    HeaderTint.RGB(hex: Self.tints[index]).color
                        .frame(height: Self.colourBand)
                    HeaderTint.RGB(hex: colorScheme == .dark ? 0x2C2C2E : 0xFFFFFF).color
                }
                .frame(width: Self.card.width, height: Self.card.height)
                .clipShape(.rect(cornerRadius: Self.cornerRadius, style: .continuous))
                .overlay {
                    // The ring keeps to the card's corners, 4 pt out.
                    if index == 0 {
                        RoundedRectangle(cornerRadius: Self.cornerRadius + 4, style: .continuous)
                            .strokeBorder(Color(nsColor: .controlAccentColor), lineWidth: 2)
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
