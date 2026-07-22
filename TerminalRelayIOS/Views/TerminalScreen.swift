import SwiftUI

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: TerminalSessionController
    @State private var confirmsStop = false
    @State private var stopError: String?
    @State private var isStopping = false

    init(profile: WorkerProfile, route: TerminalRoute) {
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
                TerminalRepresentable(controller: controller)

                if let recovery = recoveryPresentation {
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
                                dismiss()
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
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    connectionLabel
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Stop", role: .destructive) { confirmsStop = true }
                        .disabled(isStopping)
                    Button("Disconnect") {
                        controller.disconnect(manually: true)
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                MobileTerminalKeyBar(controller: controller)
            }
        }
        .onChange(of: scenePhase) { _, phase in
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
            controller.disconnect(manually: true)
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
                dismiss()
            } catch {
                stopError = error.localizedDescription
                isStopping = false
            }
        }
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
