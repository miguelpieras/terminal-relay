import SwiftUI

struct TerminalRepresentable: UIViewRepresentable {
    @ObservedObject var controller: TerminalSessionController

    func makeUIView(context: Context) -> RelayTerminalView {
        let view = RelayTerminalView(frame: .zero)
        controller.bind(to: view)
        return view
    }

    func updateUIView(_ uiView: RelayTerminalView, context: Context) {
        controller.bind(to: uiView)
    }
}
