import AppKit
import SwiftUI

struct SystemTestHostView: View {
    var body: some View {
        SyntheticHostAppKitView()
            .frame(minWidth: 680, minHeight: 360)
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

        let stack = NSStackView(views: [
            title,
            explanation,
            input,
            buttonRow,
            inspectButton,
            dropContainer,
            statusLabel,
            detailsLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -24),
            dropContainer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func makeButton(_ title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    @objc private func writeText() { harness.writeText(); refreshStatus() }
    @objc private func writeRichText() { harness.writeRichText(); refreshStatus() }
    @objc private func writeImage() { harness.writeImage(); refreshStatus() }
    @objc private func writeFileReference() { harness.writeFileReference(); refreshStatus() }
    @objc private func inspectPasteboard() { harness.inspectSyntheticPasteboard(); refreshStatus() }

    private func refreshStatus() {
        statusLabel.stringValue = harness.status
        detailsLabel.stringValue = harness.receivedTypes.joined(separator: "\n")
    }
}
