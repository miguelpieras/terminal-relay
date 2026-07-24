import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    @ObservedObject var session: TerminalSession

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.startIfNeeded()
        let terminalView = session.terminalView
        DispatchQueue.main.async {
            guard let window = terminalView.window else { return }
            window.makeFirstResponder(terminalView)
        }
        return terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}
