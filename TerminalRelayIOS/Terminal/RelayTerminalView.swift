import SwiftTerm
import UIKit

@MainActor
protocol RelayTerminalIO: AnyObject {
    func sendTerminalInput(_ data: Data)
    func resizeTerminal(columns: Int, rows: Int)
}

final class RelayTerminalView: TerminalView, TerminalViewDelegate {
    weak var relayIO: RelayTerminalIO?

    override init(frame: CGRect) {
        super.init(frame: frame)
        terminalDelegate = self
        backgroundColor = .black
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func scrolled(source: TerminalView, position: Double) {}

    func setTerminalTitle(source: TerminalView, title: String) {}

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        relayIO?.resizeTerminal(columns: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        relayIO?.sendTerminalInput(Data(data))
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        UIPasteboard.general.string = String(data: content, encoding: .utf8)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
