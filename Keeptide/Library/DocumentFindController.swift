import AppKit

@MainActor
final class DocumentFindController {
    private weak var textView: NSTextView?
    private(set) var isFindInterfaceVisible = false

    init(textView: NSTextView) {
        self.textView = textView
    }

    func showFind() {
        guard !isFindInterfaceVisible else { return }
        isFindInterfaceVisible = true
        textView?.performFindPanelAction(NSNumber(value: NSTextFinder.Action.showFindInterface.rawValue))
    }

    func hideFind() {
        guard isFindInterfaceVisible else { return }
        isFindInterfaceVisible = false
        textView?.performFindPanelAction(NSNumber(value: NSTextFinder.Action.hideFindInterface.rawValue))
    }
}
