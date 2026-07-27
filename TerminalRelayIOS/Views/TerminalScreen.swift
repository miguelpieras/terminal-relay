import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: TerminalSessionController
    @State private var confirmsStop = false
    @State private var stopError: String?
    @State private var isStopping = false
    private let isDemo: Bool
    private let onClose: (() -> Void)?

    init(
        profile: WorkerProfile,
        route: TerminalRoute,
        isDemo: Bool = false,
        onClose: (() -> Void)? = nil
    ) {
        self.isDemo = isDemo
        self.onClose = onClose
        _controller = StateObject(
            wrappedValue: TerminalSessionController(
                profile: profile,
                kind: route.kind,
                repositoryName: route.repositoryName,
                instanceToken: route.instanceToken
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if isDemo {
                    DemoTerminalRepresentable(
                        kind: controller.kind,
                        repositoryName: controller.repositoryName
                    )
                    .padding(.top, hidesEmbeddedDemoNavigation ? 40 : 0)
                } else {
                    TerminalRepresentable(controller: controller)
                }

                if !isDemo, let recovery = recoveryPresentation {
                    VStack(spacing: 12) {
                        Text(recovery.message)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                        if recovery.canReconnect {
                            Button("Reconnect") {
                                Task { await controller.reconnect() }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Back to Projects") {
                                controller.disconnect(manually: true)
                                close()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                }
            }
            .navigationTitle("\(controller.kind.displayName) · \(controller.repositoryName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(
                hidesEmbeddedDemoNavigation ? .hidden : .automatic,
                for: .navigationBar
            )
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if isDemo {
                        Label("Demo", systemImage: "play.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.indigo)
                    } else {
                        connectionLabel
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isDemo {
                        Button("Close Demo") {
                            close()
                        }
                    } else {
                        Button("Stop", role: .destructive) { confirmsStop = true }
                            .disabled(isStopping)
                        Button("Disconnect") {
                            controller.disconnect(manually: true)
                            close()
                        }
                        .keyboardShortcut("w", modifiers: .command)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isDemo {
                    HStack {
                        Label("Read-only local demo", systemImage: "lock.shield")
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text("No worker connection")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
                } else {
                    MobileTerminalKeyBar(controller: controller)
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !isDemo else { return }
            switch phase {
            case .background:
                controller.suspendForBackground()
            case .active:
                Task { await controller.reconnectAfterForeground() }
            default:
                break
            }
        }
        .onDisappear {
            if !isDemo {
                controller.disconnect(manually: true)
            }
        }
        .alert("Stop \(controller.kind.displayName)?", isPresented: $confirmsStop) {
            Button("Stop Agent", role: .destructive) {
                stopAgent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This ends the remote agent for every attached client. To leave it running, choose Disconnect instead.")
        }
        .alert(
            "Could not stop agent",
            isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })
        ) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var connectionLabel: some View {
        switch controller.state {
        case .connecting:
            ProgressView().tint(.white)
        case .connected:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .disconnected:
            Text("Disconnected").font(.caption).foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ended:
            Label("Ended", systemImage: "stop.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var hidesEmbeddedDemoNavigation: Bool {
        isDemo && onClose != nil
    }

    private var recoveryPresentation: (message: String, canReconnect: Bool)? {
        switch controller.state {
        case .disconnected:
            (
                "The terminal connection closed. Reconnect only if the same remote session is still running.",
                true
            )
        case .failed(let message):
            (message, true)
        case .ended(let message):
            (message, false)
        case .connecting, .connected:
            nil
        }
    }

    private func stopAgent() {
        isStopping = true
        Task {
            do {
                try await controller.stopAgent()
                close()
            } catch {
                stopError = error.localizedDescription
                isStopping = false
            }
        }
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct DemoTerminalRepresentable: UIViewRepresentable {
    let kind: AgentKind
    let repositoryName: String

    func makeUIView(context: Context) -> RelayTerminalView {
        let view = RelayTerminalView(frame: .zero)
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = UIColor(white: 0.88, alpha: 1)
        view.isUserInteractionEnabled = false
        DispatchQueue.main.async {
            view.feed(text: transcript)
        }
        return view
    }

    func updateUIView(_ uiView: RelayTerminalView, context: Context) {}

    private var transcript: String {
        let accent = "\u{001B}[38;5;75m"
        let success = "\u{001B}[38;5;114m"
        let muted = "\u{001B}[38;5;245m"
        let primary = "\u{001B}[38;5;252m"
        let reset = "\u{001B}[0m"

        let content = """
        \(muted)example-user@private-worker:/workspace/\(repositoryName)$\(reset) \(kind.rawValue)

        \(accent)> Make the iPad workspace feel native. Keep projects and terminals in a compact sidebar, then give the active terminal as much room as possible.\(reset)

        \(primary)I will simplify the iPad layout into two columns and keep the phone navigation compact. The worker, pairing, and session logic remains shared across both device experiences.\(reset)

        \(muted)- Inspecting the adaptive workspace
        - Combining projects and active terminals in the sidebar
        - Expanding the terminal detail across the remaining display\(reset)

        \(success)Done. The iPad now keeps navigation close at hand while the terminal uses the full detail area. Switching projects or sessions never stops the remote agent.\(reset)

        \(accent)> Review the private pairing path and prepare the App Store release.\(reset)

        \(primary)Pairing uses a short-lived, enrollment-only key. Every user connects to a worker they control; this demo contains example data and makes no network connection.\(reset)

        \(success)Ready for review.\(reset)
        """
        return content
            .components(separatedBy: "\n")
            .map { $0.isEmpty ? "" : "  \($0)" }
            .joined(separator: "\r\n")
    }
}

private struct MobileTerminalKeyBar: View {
    @ObservedObject var controller: TerminalSessionController

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MobileTerminalKey.allCases) { key in
                    Button(key.label) {
                        controller.sendKey(key)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .frame(minWidth: key == .controlC ? 72 : 44)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }
}
