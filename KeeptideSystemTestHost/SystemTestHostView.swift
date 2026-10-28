import AppKit
import SwiftUI

struct SystemTestHostView: View {
    var body: some View {
        SyntheticHostAppKitView()
            .frame(minWidth: 680, minHeight: 650)
    }
}

private struct SyntheticHostAppKitView: NSViewRepresentable {
    func makeNSView(context: Context) -> SyntheticHostView {
        SyntheticHostView()
    }

    func updateNSView(_ nsView: SyntheticHostView, context: Context) {}
}

@MainActor
private final class SyntheticHostView: NSView {
    private let harness = SyntheticPasteboardHarness()
    private let statusLabel = NSTextField(labelWithString: "No synthetic payload written")
    private let detailsLabel = NSTextField(wrappingLabelWithString: "")
    private let receivedTextLabel = NSTextField(labelWithString: "")
    private let receivedPasteCountLabel = NSTextField(labelWithString: "0")
    private let receivedPasteTextLabel = NSTextField(labelWithString: "")
    private let receivedPasteModifiersLabel = NSTextField(labelWithString: "")
    private let hostWindowNumberLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let title = NSTextField(labelWithString: "Synthetic System Test Host")
        title.font = .preferredFont(forTextStyle: .title2)
        let explanation = NSTextField(
            wrappingLabelWithString: "Every pasteboard action below uses Keeptide's isolated named test pasteboard."
        )
        explanation.textColor = .secondaryLabelColor

        let input = NSTextField(string: "")
        input.placeholderString = "Synthetic keyboard input target"
        input.setAccessibilityIdentifier("Synthetic input")

        let buttonRow = NSStackView(views: [
            makeButton("Write Text", action: #selector(writeText)),
            makeButton("Write Rich Text", action: #selector(writeRichText)),
            makeButton("Write Image", action: #selector(writeImage)),
            makeButton("Write File Reference", action: #selector(writeFileReference)),
        ])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let inspectButton = makeButton("Inspect Synthetic Pasteboard", action: #selector(inspectPasteboard))
        let alternateButton = makeButton("Write Alternate Text", action: #selector(writeAlternateText))
        let dropReceiver = DropView { [weak self] urls in
            self?.harness.receiveDroppedFiles(urls)
            self?.refreshStatus()
        }
        let dropLabel = NSTextField(labelWithString: "Drop synthetic test files here")
        dropLabel.textColor = .secondaryLabelColor
        dropLabel.alignment = .center

        let dropContainer = NSView()
        dropContainer.addSubview(dropReceiver)
        dropContainer.addSubview(dropLabel)
        dropReceiver.translatesAutoresizingMaskIntoConstraints = false
        dropLabel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dropReceiver.leadingAnchor.constraint(equalTo: dropContainer.leadingAnchor),
            dropReceiver.trailingAnchor.constraint(equalTo: dropContainer.trailingAnchor),
            dropReceiver.topAnchor.constraint(equalTo: dropContainer.topAnchor),
            dropReceiver.bottomAnchor.constraint(equalTo: dropContainer.bottomAnchor),
            dropLabel.centerXAnchor.constraint(equalTo: dropContainer.centerXAnchor),
            dropLabel.centerYAnchor.constraint(equalTo: dropContainer.centerYAnchor),
            dropContainer.heightAnchor.constraint(equalToConstant: 120),
        ])

        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.setAccessibilityIdentifier("Synthetic host status")
        detailsLabel.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        detailsLabel.isSelectable = true
        receivedTextLabel.setAccessibilityIdentifier("ReceivedSyntheticText")
        let pasteReceiver = makePasteReceiver()

        let stack = NSStackView(views: [
            title,
            explanation,
            input,
            buttonRow,
            alternateButton,
            inspectButton,
            dropContainer,
            statusLabel,
            detailsLabel,
            receivedTextLabel,
            pasteReceiver,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            dropContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pasteReceiver.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hostWindowNumberLabel.stringValue = window.map { String($0.windowNumber) } ?? ""
    }

    /// Below the pasteboard controls: a text area that takes ⌘V from this session's named pasteboard, a password
    /// field for the secure input check, and what the text area last received.
    private func makePasteReceiver() -> NSView {
        let title = NSTextField(labelWithString: "Paste Receiver")
        title.font = .preferredFont(forTextStyle: .headline)

        let scrollView = DirectPasteReceiverView.scrollableTextView()
        scrollView.borderType = .bezelBorder
        guard let receiver = scrollView.documentView as? DirectPasteReceiverView else {
            fatalError("The scrollable text view is not a paste receiver")
        }
        receiver.isRichText = false
        receiver.font = .systemFont(ofSize: NSFont.systemFontSize)
        receiver.setAccessibilityIdentifier("DirectPasteReceiver")
        receiver.onPaste = { [weak self] modifiers in
            guard let self else { return "" }
            let text = harness.receivePaste(modifiers: modifiers)
            refreshStatus()
            return text
        }

        let secureField = NSSecureTextField(string: "")
        secureField.placeholderString = "Synthetic secure input"
        secureField.setAccessibilityIdentifier("SyntheticSecureField")

        receivedPasteCountLabel.setAccessibilityIdentifier("ReceivedPasteCount")
        receivedPasteTextLabel.setAccessibilityIdentifier("ReceivedPasteText")
        receivedPasteModifiersLabel.setAccessibilityIdentifier("ReceivedPasteModifiers")
        hostWindowNumberLabel.setAccessibilityIdentifier("HostWindowNumber")
        let grid = NSGridView(views: [
            [caption("Pastes received"), receivedPasteCountLabel, caption("Modifiers"), receivedPasteModifiersLabel],
            [caption("Last paste"), receivedPasteTextLabel, caption("Window number"), hostWindowNumberLabel],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.column(at: 1).width = 220

        let section = NSStackView(views: [title, scrollView, secureField, grid])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 6
        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalTo: section.widthAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 56),
            secureField.widthAnchor.constraint(equalToConstant: 260),
        ])
        return section
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func writeText() { harness.writeText(); refreshStatus() }
    @objc private func writeAlternateText() { harness.writeAlternateText(); refreshStatus() }
    @objc private func writeRichText() { harness.writeRichText(); refreshStatus() }
    @objc private func writeImage() { harness.writeImage(); refreshStatus() }
    @objc private func writeFileReference() { harness.writeFileReference(); refreshStatus() }
    @objc private func inspectPasteboard() { harness.inspectSyntheticPasteboard(); refreshStatus() }

    private func refreshStatus() {
        statusLabel.stringValue = harness.status
        detailsLabel.stringValue = harness.receivedTypes.joined(separator: "\n")
        receivedTextLabel.stringValue = harness.receivedText
        receivedPasteCountLabel.stringValue = String(harness.receivedPasteCount)
        receivedPasteTextLabel.stringValue = harness.receivedPasteText
        receivedPasteModifiersLabel.stringValue = harness.receivedPasteModifiers
    }
}
