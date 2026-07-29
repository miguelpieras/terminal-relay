import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: TerminalSessionController
    @StateObject private var chatController: MobileChatSessionController
    @State private var confirmsStop = false
    @State private var confirmsTerminalFallback = false
    @State private var stopError: String?
    @State private var isStopping = false
    @State private var isSwitchingToTerminal = false
    private let isDemo: Bool
    private let onExitDemo: (() -> Void)?
    private let onClose: (() -> Void)?

    init(
        profile: WorkerProfile,
        route: TerminalRoute,
        isDemo: Bool = false,
        onExitDemo: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.isDemo = isDemo
        self.onExitDemo = onExitDemo
        self.onClose = onClose
        let opensExistingTerminal = route.presentation == .terminal
        _controller = StateObject(
            wrappedValue: TerminalSessionController(
                profile: profile,
                kind: route.kind,
                repositoryName: route.repositoryName,
                instanceToken: opensExistingTerminal ? route.instanceToken : nil,
                providerThreadID:
                    opensExistingTerminal ? nil : route.providerThreadID
            )
        )
        _chatController = StateObject(
            wrappedValue: MobileChatSessionController(
                profile: profile,
                route: route
            )
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                (showsTerminal ? Color.black : Color(uiColor: .systemBackground))
                    .ignoresSafeArea()
                sessionContent
                if isSwitchingToTerminal {
                    ZStack {
                        Color.black.opacity(0.18)
                            .ignoresSafeArea()
                        ProgressView("Switching to Terminal…")
                            .padding(18)
                            .background(
                                .regularMaterial,
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                    }
                    .transition(.opacity)
                }
            }
            .navigationTitle("\(controller.kind.displayName) · \(controller.repositoryName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(
                hidesEmbeddedDemoNavigation ? .hidden : .automatic,
                for: .navigationBar
            )
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
                        Button("Exit Demo") {
                            if let onExitDemo {
                                onExitDemo()
                            } else {
                                close()
                            }
                        }
                    } else {
                        Button("Stop", role: .destructive) { confirmsStop = true }
                            .disabled(
                                isStopping
                                    || isSwitchingToTerminal
                                    || !canStop
                            )
                        Button("Disconnect") {
                            disconnectAndClose()
                        }
                        .disabled(isStopping || isSwitchingToTerminal)
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
                } else if showsTerminal {
                    MobileTerminalKeyBar(controller: controller)
                }
            }
        }
        .onAppear {
            if !isDemo {
                chatController.start()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard !isDemo else { return }
            switch phase {
            case .background:
                if showsTerminal {
                    controller.suspendForBackground()
                } else {
                    Task {
                        await chatController.suspendForBackground()
                    }
                }
            case .active:
                if showsTerminal {
                    Task { await controller.reconnectAfterForeground() }
                } else {
                    chatController.reconnectAfterForeground()
                }
            default:
                break
            }
        }
        .onDisappear {
            if !isDemo {
                Task {
                    await chatController.detach()
                }
                if showsTerminal {
                    controller.disconnect(manually: true)
                }
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
        .alert("Open terminal fallback?", isPresented: $confirmsTerminalFallback) {
            Button("Switch to Terminal", role: .destructive) {
                Task {
                    isSwitchingToTerminal = true
                    defer { isSwitchingToTerminal = false }
                    do {
                        try await chatController.openTerminalFallback {
                            controller.configureForChatFallback(
                                providerThreadID: $0
                            )
                        }
                    } catch {
                        stopError = (error as? MobileChatSessionError)?
                            .localizedDescription
                            ?? "The terminal fallback could not be opened safely."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This stops the exact native-chat agent, then resumes the same provider conversation in the raw terminal."
            )
        }
        .alert(
            "Could not complete action",
            isPresented: Binding(get: { stopError != nil }, set: { if !$0 { stopError = nil } })
        ) {
            Button("OK") { stopError = nil }
        } message: {
            Text(stopError ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var sessionContent: some View {
        if isDemo {
            DemoChatConversationView()
                .padding(.top, hidesEmbeddedDemoNavigation ? 40 : 0)
        } else {
            switch chatController.phase {
            case .preparing:
                preparationView
            case .chat:
                if let coordinator = chatController.coordinator {
                    ConversationView(
                        coordinator: coordinator,
                        onOpenTerminalFallback: {
                            confirmsTerminalFallback = true
                        }
                    )
                } else {
                    preparationView
                }
            case .terminalFallback(let reason):
                TerminalRepresentable(controller: controller)
                if let reason {
                    VStack {
                        Label(reason, systemImage: "terminal")
                            .font(.caption)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(
                                .regularMaterial,
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                            .padding(12)
                        Spacer()
                    }
                }
                if let recovery = recoveryPresentation {
                    recoveryView(recovery)
                }
            case .failed(let message):
                failureView(message)
            case .stopped:
                endedView
            }
        }
    }

    private var preparationView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing native chat…")
                .font(.headline)
            Text("Connecting directly to your worker over SSH.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing native chat")
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Could not open native chat")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Back to Projects") {
                    disconnectAndClose()
                }
                .buttonStyle(.bordered)
                Button("Try Again") {
                    chatController.retryPreparation()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var endedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)
            Text("Agent session ended")
                .font(.headline)
            Button("Back to Projects") {
                close()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func recoveryView(
        _ recovery: (message: String, canReconnect: Bool)
    ) -> some View {
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

    @ViewBuilder
    private var connectionLabel: some View {
        switch chatController.phase {
        case .preparing:
            ProgressView()
        case .chat:
            if let coordinator = chatController.coordinator {
                ChatNavigationStatus(store: coordinator.store)
            } else {
                ProgressView()
            }
        case .terminalFallback:
            switch controller.state {
            case .connecting:
                ProgressView()
            case .connected:
                Label("Terminal", systemImage: "terminal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .disconnected:
                Text("Disconnected").font(.caption).foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .ended:
                Label("Ended", systemImage: "stop.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        case .failed:
            Label("Offline", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        case .stopped:
            Label("Ended", systemImage: "stop.circle.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var showsTerminal: Bool {
        guard !isDemo else { return false }
        if case .terminalFallback = chatController.phase {
            return true
        }
        return false
    }

    private var canStop: Bool {
        switch chatController.phase {
        case .chat, .terminalFallback:
            true
        case .preparing, .failed, .stopped:
            false
        }
    }

    private func stopAgent() {
        isStopping = true
        Task {
            do {
                if chatController.phase == .chat {
                    try await chatController.stopChat()
                } else {
                    try await controller.stopAgent()
                }
                close()
            } catch {
                stopError = "The agent could not be stopped. It may still be running; reconnect and try again."
                isStopping = false
            }
        }
    }

    private func disconnectAndClose() {
        Task {
            await chatController.detach()
        }
        if showsTerminal {
            controller.disconnect(manually: true)
        }
        close()
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

private struct DemoChatConversationView: View {
    @State private var coordinator: ConversationCoordinator

    init() {
        _coordinator = State(
            initialValue: MobileChatDemoFixture.makeCoordinator()
        )
    }

    var body: some View {
        ConversationView(coordinator: coordinator, isReadOnly: true)
    }
}

private struct ChatNavigationStatus: View {
    @ObservedObject var store: ConversationStore

    var body: some View {
        switch store.state.connectionState {
        case .connecting:
            ProgressView()
        case .streaming:
            Label(
                store.state.turnState.isActive ? "Working" : "Chat",
                systemImage: store.state.turnState.isActive
                    ? "sparkles"
                    : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(.green)
        case .awaitingApproval:
            Label("Needs you", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.orange)
        case .offlineAgentRunning:
            Label("Offline", systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .interrupted:
            Label("Interrupted", systemImage: "stop.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .stopped:
            Label("Ended", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .unsupportedWorker:
            Label("Terminal", systemImage: "terminal")
                .font(.caption)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        case .unknown:
            Label("Updating", systemImage: "circle.dotted")
                .font(.caption)
                .foregroundStyle(.secondary)
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
