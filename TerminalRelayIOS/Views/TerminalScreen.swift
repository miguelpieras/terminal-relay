import SwiftUI
import UIKit

struct TerminalScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller: TerminalSessionController
    @StateObject private var chatController: MobileChatSessionController
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
            }
            .navigationTitle(controller.repositoryName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close conversation")
                    .keyboardShortcut("w", modifiers: .command)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsTerminal {
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
    }

    @ViewBuilder
    private var sessionContent: some View {
#if DEBUG
        if isDemo {
            DemoChatConversationView()
        } else {
            liveSessionContent
        }
#else
        liveSessionContent
#endif
    }

    @ViewBuilder
    private var liveSessionContent: some View {
        switch chatController.phase {
        case .preparing:
            preparationView
        case .chat:
            if let coordinator = chatController.coordinator {
                ConversationView(
                    coordinator: coordinator,
                    startsCoordinator: false,
                    attachmentActions: chatController.attachmentActions
                )
            } else {
                preparationView
            }
        case .terminal:
            TerminalRepresentable(controller: controller)
            if let recovery = recoveryPresentation {
                recoveryView(recovery)
            }
        case .failed(let message):
            failureView(message)
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
                    close()
                }
                .buttonStyle(.bordered)
                .chatMinimumInteractionTarget()
                Button("Try Again") {
                    chatController.retryPreparation()
                }
                .buttonStyle(.borderedProminent)
                .chatMinimumInteractionTarget()
            }
        }
        .padding(24)
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
        if case .terminal = chatController.phase {
            return true
        }
        return false
    }

    private func close() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}

#if DEBUG
private struct DemoChatConversationView: View {
    @State private var fixture: MobileChatDemoFixture.Instance

    init() {
        _fixture = State(
            initialValue: MobileChatDemoFixture.makeInstance()
        )
    }

    var body: some View {
        ConversationView(
            coordinator: fixture.coordinator,
            isReadOnly: true
        )
        .overlay(alignment: .topTrailing) {
            if fixture.supportsScrollUITestUpdate {
                Button {
                    Task {
                        await fixture.appendScrollUITestUpdate()
                    }
                } label: {
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Append scroll test update")
                .accessibilityIdentifier("conversation.test.append")
            }
        }
    }
}
#endif

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
