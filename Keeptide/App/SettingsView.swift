import SwiftUI

/// Four native settings pages backed by the application's shared preference and service models.
struct SettingsView: View {
    @Bindable var model: SettingsModel

    private var lifecycle: LifecycleSettingsModel? { model.lifecycle }

    init(model: SettingsModel) {
        self.model = model
    }

    init(preferences: QuickAccessPreferences, lifecycle: LifecycleSettingsModel? = nil) {
        model = SettingsModel.compatibility(quickAccess: preferences, lifecycle: lifecycle)
    }

    var body: some View {
        TabView(selection: $model.selectedTab) {
            page("GeneralSettingsPage") { generalPage }
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)
            page("ShortcutSettingsPage") { shortcutPage }
                .tabItem { Label(SettingsTab.shortcuts.title, systemImage: SettingsTab.shortcuts.systemImage) }
                .tag(SettingsTab.shortcuts)
            page("RecordingPrivacySettingsPage") { recordingPage }
                .tabItem {
                    Label(SettingsTab.recordingAndPrivacy.title, systemImage: SettingsTab.recordingAndPrivacy.systemImage)
                }
                .tag(SettingsTab.recordingAndPrivacy)
            page("CloudSettingsPage") { cloudPage }
                .tabItem { Label(SettingsTab.iCloud.title, systemImage: SettingsTab.iCloud.systemImage) }
                .tag(SettingsTab.iCloud)
        }
        .frame(minWidth: 600, idealWidth: 600, maxWidth: 600, minHeight: 420)
        .accessibilityIdentifier("SettingsTabs")
        .alert(
            "Shorten History Retention?",
            isPresented: confirmationPresented
        ) {
            Button("Cancel", role: .cancel) { lifecycle?.cancelConfirmation() }
            Button("Apply Shorter Retention", role: .destructive) {
                guard let lifecycle else { return }
                Task { await lifecycle.confirmShortening() }
            }
        } message: {
            if let confirmation = lifecycle?.pendingConfirmation {
                Text(Self.confirmationMessage(historyCount: confirmation.historyCount))
            }
        }
    }

    private func page<Content: View>(
        _ identifier: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        ScrollView {
            content()
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .accessibilityIdentifier(identifier)
    }

    private var generalPage: some View {
        @Bindable var preferences = model.quickAccess
        return Form {
            Section {
                Picker("Card size", selection: $preferences.cardSize) {
                    ForEach(CardSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.radioGroup)
                StripPreview()
                Slider(value: $preferences.selectedCardScale, in: Self.scales, step: 0.01) {
                    Text("Enlarge the selected card")
                } minimumValueLabel: {
                    Text("None")
                } maximumValueLabel: {
                    Text("More")
                }
                .accessibilityValue(Text(Self.enlargement(preferences.selectedCardScale)))
                Toggle("Fade the ends of the strip", isOn: $preferences.fadesStripEnds)
                    .controlSize(.mini)
                Toggle(isOn: $preferences.showsFrequentClips) {
                    Text("Show frequent clips in the strip")
                    Text("Clips you've copied or pasted from Keeptide more than once, and used in the last 90 days, appear to the left of the newest clip.")
                }
                .controlSize(.mini)
                Toggle("Tick on the trackpad as each clip passes", isOn: $preferences.trackpadTicks)
                    .controlSize(.mini)
            } header: {
                Text("Quick Access")
            } footer: {
                Text("Larger cards give each clip more room and larger type. Space always shows the selected clip in full. Ticks play on a Force Touch trackpad while your fingers are on it.")
            }

            Section("Application") {
                launchAtLoginControl
                Button("Show Welcome", action: model.actions.showWelcome)
                    .accessibilityIdentifier("ShowWelcomeButton")
                if let exportArchive = model.actions.exportArchive {
                    Button("Export Library…", action: exportArchive)
                        .disabled(!model.canExportLibrary)
                        .help("Available when the local library is open and no export is running.")
                        .accessibilityIdentifier("ExportLibraryButton")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var shortcutPage: some View {
        Form {
            Section {
                Picker("Keyboard shortcut", selection: shortcutSelection) {
                    ForEach(QuickAccessShortcut.allCases, id: \.self) { shortcut in
                        Text(shortcut.displayName).tag(shortcut)
                    }
                }
                .accessibilityIdentifier("GlobalShortcutPicker")
                Text(shortcutStatusDescription)
                    .foregroundStyle(shortcutStatusIsFailure ? .red : .secondary)
                    .accessibilityIdentifier("GlobalShortcutStatus")
            } header: {
                Text("Quick Access")
            } footer: {
                Text("The shortcut follows the V key in your current keyboard input source. If a choice is unavailable, use the menu bar or choose another preset.")
            }
        }
        .formStyle(.grouped)
    }

    private var recordingPage: some View {
        Form {
            Section {
                Toggle("Record new clipboard content", isOn: captureEnabled)
                    .disabled(!model.canChangeRecordingConsent)
                    .accessibilityIdentifier("CaptureEnabledToggle")
                Text(model.recordingStatusDescription)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("RecordingAvailabilityStatus")
                Text("Recording affects only new copies. Turning it off does not remove existing history or saved snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Text(ignoredApplicationsDescription)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage Ignored Apps…", action: model.actions.manageIgnoredApplications)
                        .accessibilityIdentifier("ManageIgnoredApplicationsButton")
                }
            } header: {
                Text("Recording")
            }

            Section("History & Storage") {
                if let lifecycle {
                    lifecycleSettings(lifecycle)
                } else {
                    Label("History settings are unavailable", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("LifecycleSettingsUnavailable")
                }
                Text("Saved snippets are not affected by clipboard history retention.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("SavedSnippetRetentionExplanation")
            }
        }
        .formStyle(.grouped)
    }

    private var cloudPage: some View {
        Form {
            Section {
                Label("iCloud is not available in this build", systemImage: "icloud.slash")
                    .font(.headline)
                    .accessibilityIdentifier("CloudUnavailableTitle")
                Text("Your library is stored locally on this Mac.")
                    .accessibilityIdentifier("LocalLibraryExplanation")
                Text("Clipboard history, saved snippets, search, and the Library continue to work without iCloud.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var launchAtLoginControl: some View {
        switch model.launchAtLogin.state {
        case .unavailable:
            Label("Open at Login is unavailable in this build", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("LaunchAtLoginUnavailable")
        default:
            Toggle("Open Keeptide at Login", isOn: launchAtLoginEnabled)
                .disabled(model.launchAtLogin.isBusy)
                .accessibilityIdentifier("LaunchAtLoginToggle")
            if model.launchAtLogin.state == .requiresApproval {
                Text("Allow Keeptide in System Settings > General > Login Items.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if case .failed(_, let message) = model.launchAtLogin.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var captureEnabled: Binding<Bool> {
        Binding(get: { model.capture.isEnabled }, set: { model.capture.isEnabled = $0 })
    }

    private var shortcutSelection: Binding<QuickAccessShortcut> {
        Binding(
            get: { model.shortcut.selection },
            set: { _ = model.shortcut.apply($0) }
        )
    }

    private var launchAtLoginEnabled: Binding<Bool> {
        Binding(
            get: {
                [.enabled, .requiresApproval].contains(model.launchAtLogin.state.actualStatus)
            },
            set: { enabled in Task { await model.launchAtLogin.setEnabled(enabled) } }
        )
    }

    private var ignoredApplicationsDescription: String {
        let count = model.capture.excludedApplications.count
        return count == 0 ? "No ignored applications" : "\(count) ignored application\(count == 1 ? "" : "s")"
    }

    private var shortcutStatusDescription: String {
        switch model.shortcut.status {
        case .disabled: "The global shortcut is off. Quick Access remains available from the menu bar."
        case .registered(let shortcut): "\(shortcut.displayName) is ready."
        case .unavailable(let shortcut): "\(shortcut.displayName) is unavailable. Choose another preset or use the menu bar."
        case .failed(let shortcut, _): "Keeptide could not register \(shortcut.displayName). Choose another preset or use the menu bar."
        }
    }

    private var shortcutStatusIsFailure: Bool {
        switch model.shortcut.status {
        case .unavailable, .failed: true
        case .disabled, .registered: false
        }
    }

    @ViewBuilder
    private func lifecycleSettings(_ model: LifecycleSettingsModel) -> some View {
        Picker("Keep clipboard history", selection: retentionOption(model)) {
            Text("1 day").tag(LifecycleRetentionOption.oneDay)
            Text("7 days").tag(LifecycleRetentionOption.sevenDays)
            Text("30 days").tag(LifecycleRetentionOption.thirtyDays)
            Text("90 days").tag(LifecycleRetentionOption.ninetyDays)
            Text("1 year").tag(LifecycleRetentionOption.oneYear)
            Text("Custom…").tag(LifecycleRetentionOption.custom)
            Text("Forever").tag(LifecycleRetentionOption.permanent)
        }
        .disabled(model.phase == .evaluatingImpact || model.phase == .applying)
        .accessibilityIdentifier("HistoryRetentionPicker")

        if model.selectedOption == .custom {
            HStack {
                TextField("Days", text: customDays(model))
                    .frame(width: 88)
                    .accessibilityIdentifier("CustomRetentionDays")
                Text("days")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Apply") { Task { await model.submitCustomRetention() } }
                    .disabled(model.phase == .evaluatingImpact || model.phase == .applying)
                    .accessibilityIdentifier("ApplyCustomRetention")
            }
        }

        if model.requiresRetentionReview {
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    "The saved retention setting could not be read. Keeptide is keeping history forever until you review it.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                Button("Confirm Keep Forever") {
                    Task { await model.selectRetention(.permanent) }
                }
                .accessibilityIdentifier("ReviewRetentionSetting")
            }
            .accessibilityIdentifier("RetentionReviewRequired")
        }

        if model.phase == .evaluatingImpact {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Checking affected clips…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("RetentionImpactProgress")
        }

        if let message = model.message {
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
                .accessibilityIdentifier("LifecycleSettingsMessage")
        }

        Toggle("Warn when Keeptide storage grows large", isOn: warningEnabled(model))
            .accessibilityIdentifier("StorageWarningToggle")
        if model.warningIsEnabled {
            Stepper(
                "Warn at \(model.warningLimitGiB) GiB",
                value: warningGiB(model),
                in: 1...1_024
            )
            .accessibilityIdentifier("StorageWarningLimit")
        }
        Text("This is a warning only, not a storage quota. Keeptide never deletes saved content to stay below it.")
            .font(.caption)
            .foregroundStyle(.secondary)

        HStack {
            if let usage = model.usage {
                Text(Self.usageDescription(usage))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("StorageUsageSummary")
            } else {
                Text("Storage usage has not been measured.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh Usage") { Task { await model.refreshUsage() } }
                .disabled(model.isRefreshingUsage)
                .accessibilityIdentifier("RefreshStorageUsage")
        }
    }

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { lifecycle?.pendingConfirmation != nil },
            // Alert buttons own the transition. Treating SwiftUI's automatic dismissal write as
            // cancellation can race the confirmation Task and discard the exact staged change.
            set: { _ in }
        )
    }

    private func retentionOption(_ model: LifecycleSettingsModel) -> Binding<LifecycleRetentionOption> {
        Binding(
            get: { model.selectedOption },
            set: { option in Task { await model.selectOption(option) } }
        )
    }

    private func customDays(_ model: LifecycleSettingsModel) -> Binding<String> {
        Binding(get: { model.customDays }, set: { model.customDays = $0 })
    }

    private func warningEnabled(_ model: LifecycleSettingsModel) -> Binding<Bool> {
        Binding(get: { model.warningIsEnabled }, set: { model.setWarningEnabled($0) })
    }

    private func warningGiB(_ model: LifecycleSettingsModel) -> Binding<Int> {
        Binding(get: { model.warningLimitGiB }, set: { model.setWarningLimitGiB($0) })
    }

    static func confirmationMessage(historyCount: Int) -> String {
        let clips = historyCount == 1 ? "1 active clip" : "\(historyCount) active clips"
        return "This will expire \(clips) from clipboard history. Saved snippets are kept."
    }

    static func usageDescription(_ report: StorageUsageReport) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let amount = formatter.string(fromByteCount: Int64(clamping: report.totalAllocatedBytes))
        return report.isPartialCoverage ? "At least \(amount) used" : "\(amount) used"
    }

    /// The enlargement slider's range: the one the strip's style keeps the scale in.
    private static let scales = Double(StripStyle.scaleRange.lowerBound)...Double(StripStyle.scaleRange.upperBound)

    /// What VoiceOver reads for the enlargement: "None" where the selected card is drawn as large as the others, and
    /// otherwise how much larger it is in whole percent, such as "12% larger".
    static func enlargement(_ scale: Double) -> String {
        let normalized = scale.isFinite ? min(max(scale, scales.lowerBound), scales.upperBound)
            : Double(StripStyle.standard.selectedScale)
        let percent = Int(((normalized - 1) * 100).rounded())
        return percent == 0 ? "None" : "\(percent)% larger"
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
