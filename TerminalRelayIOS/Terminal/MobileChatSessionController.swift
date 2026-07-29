import Combine
import Foundation

struct MobileChatSessionDependencies {
    let execute: (String) async throws -> Data
    let makeTransport: (String) -> any ChatTransport

    static func live(
        profile: WorkerProfile,
        identityStore: SSHIdentityStore
    ) -> MobileChatSessionDependencies {
        let workerClient = SSHWorkerClient(identityStore: identityStore)
        return MobileChatSessionDependencies(
            execute: { command in
                try await workerClient.execute(command, on: profile)
            },
            makeTransport: { command in
                IOSSSHChatTransport(
                    profile: profile,
                    command: command,
                    identityStore: identityStore
                )
            }
        )
    }
}

enum MobileChatSessionPhase: Equatable {
    case preparing
    case chat
    case terminalFallback(reason: String?)
    case failed(String)
    case stopped
}

enum MobileChatSessionError: LocalizedError, Equatable {
    case sessionNotReady
    case stopFailed
    case terminalFallbackUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionNotReady:
            "The native chat session has not finished starting."
        case .stopFailed:
            "The agent could not be stopped. It may still be running; reconnect and try again."
        case .terminalFallbackUnavailable:
            "The chat ended, but the terminal fallback could not safely resume the same conversation."
        }
    }
}

@MainActor
final class MobileChatSessionController: ObservableObject {
    @Published private(set) var phase: MobileChatSessionPhase = .preparing
    @Published private(set) var coordinator: ConversationCoordinator?

    let kind: AgentKind
    let repositoryName: String

    private let route: TerminalRoute
    private let dependencies: MobileChatSessionDependencies
    private let launchArguments: [String]
    private var identity: ChatConversationIdentity?
    private var resolvedProviderThreadID: String?
    private var preparationTask: Task<Void, Never>?
    private var operationID = UUID()
    private var isOpeningTerminalFallback = false
    private var isStoppingChat = false

    init(
        profile: WorkerProfile,
        route: TerminalRoute,
        identityStore: SSHIdentityStore = SSHIdentityStore()
    ) {
        self.route = route
        self.kind = route.kind
        self.repositoryName = route.repositoryName
        self.dependencies = .live(profile: profile, identityStore: identityStore)
        self.launchArguments = AgentLaunchDefaults.standard.arguments(for: route.kind)
    }

    init(
        route: TerminalRoute,
        launchArguments: [String] = [],
        dependencies: MobileChatSessionDependencies
    ) {
        self.route = route
        self.kind = route.kind
        self.repositoryName = route.repositoryName
        self.dependencies = dependencies
        self.launchArguments = launchArguments
    }

    func start() {
        guard preparationTask == nil else { return }
        if route.presentation == .terminal {
            phase = .terminalFallback(reason: nil)
            return
        }

        phase = .preparing
        let operationID = UUID()
        self.operationID = operationID
        preparationTask = Task { [weak self] in
            await self?.prepare(operationID: operationID)
        }
    }

    func retryPreparation() {
        guard case .failed = phase else { return }
        start()
    }

    func detach() async {
        operationID = UUID()
        preparationTask?.cancel()
        preparationTask = nil
        await coordinator?.detach()
    }

    func suspendForBackground() async {
        switch phase {
        case .preparing:
            operationID = UUID()
            preparationTask?.cancel()
            preparationTask = nil
        case .chat:
            await coordinator?.detach()
        case .terminalFallback, .failed, .stopped:
            break
        }
    }

    func reconnectAfterForeground() {
        switch phase {
        case .preparing:
            start()
        case .chat:
            coordinator?.start()
        case .terminalFallback, .failed, .stopped:
            break
        }
    }

    func stopChat() async throws {
        guard let identity, !isStoppingChat else {
            throw MobileChatSessionError.sessionNotReady
        }
        isStoppingChat = true
        defer { isStoppingChat = false }
        await coordinator?.detach()
        let command = try WorkerRemoteCommand.stopChat(
            kind: kind,
            repositoryName: repositoryName,
            relayID: identity.relayID
        )
        do {
            _ = try await dependencies.execute(command)
        } catch {
            coordinator?.start()
            throw MobileChatSessionError.stopFailed
        }
        self.identity = nil
        coordinator = nil
        phase = .stopped
    }

    func openTerminalFallback(
        configureTerminal: (String) -> Bool
    ) async throws {
        guard phase == .chat,
              !isOpeningTerminalFallback,
              let providerThreadID = terminalProviderThreadID,
              ChatWireValidation.isCanonicalUUID(providerThreadID) else {
            throw MobileChatSessionError.sessionNotReady
        }
        isOpeningTerminalFallback = true
        defer { isOpeningTerminalFallback = false }

        try await stopChat()
        guard configureTerminal(providerThreadID) else {
            phase = .failed(
                MobileChatSessionError.terminalFallbackUnavailable.localizedDescription
            )
            throw MobileChatSessionError.terminalFallbackUnavailable
        }
        phase = .terminalFallback(reason: nil)
    }

    var terminalProviderThreadID: String? {
        resolvedProviderThreadID ?? route.providerThreadID
    }

    private func prepare(operationID: UUID) async {
        defer {
            if self.operationID == operationID {
                preparationTask = nil
            }
        }

        do {
            let capabilityCommand = try WorkerRemoteCommand.chatCapabilities(
                kind: kind,
                repositoryName: repositoryName
            )
            let capabilityData = try await dependencies.execute(capabilityCommand)
            guard self.operationID == operationID, !Task.isCancelled else { return }
            let capability = try WorkerChatProtocol.parseCapabilities(
                capabilityData,
                expectedKind: kind
            )
            guard capability.isAvailable else {
                handleUnavailableNativeChat(
                    fallbackReason:
                        "Native chat is not available for \(kind.displayName) on this worker yet."
                )
                return
            }

            let identity: ChatConversationIdentity
            if let relayID = route.instanceToken {
                guard route.presentation == .chat else {
                    phase = .terminalFallback(reason: nil)
                    return
                }
                identity = ChatConversationIdentity(
                    relayID: relayID,
                    provider: ChatProvider(rawValue: kind.rawValue),
                    providerThreadID: route.providerThreadID
                )
            } else {
                let startCommand = try WorkerRemoteCommand.startChat(
                    kind: kind,
                    repositoryName: repositoryName,
                    providerThreadID: route.providerThreadID,
                    launchArguments: launchArguments
                )
                let startData = try await dependencies.execute(startCommand)
                guard self.operationID == operationID, !Task.isCancelled else { return }
                let started = try WorkerChatProtocol.parseStart(
                    startData,
                    expectedKind: kind
                )
                identity = ChatConversationIdentity(
                    relayID: started.relayID,
                    provider: ChatProvider(rawValue: started.kind.rawValue),
                    providerThreadID: started.providerThreadID
                )
            }

            guard identity.isValid else {
                throw WorkerChatProtocolError.invalidResponse
            }
            let attachCommand = try WorkerRemoteCommand.attachChat(
                kind: kind,
                repositoryName: repositoryName,
                relayID: identity.relayID
            )
            let coordinator = ConversationCoordinator(
                transport: dependencies.makeTransport(attachCommand),
                identity: identity
            )
            guard self.operationID == operationID, !Task.isCancelled else {
                await coordinator.detach()
                return
            }
            self.identity = identity
            resolvedProviderThreadID = identity.providerThreadID
            self.coordinator = coordinator
            phase = .chat
            coordinator.start()
        } catch WorkerChatProtocolError.missingMarker {
            guard self.operationID == operationID else { return }
            handleUnavailableNativeChat(
                fallbackReason:
                    "Update this worker to use native chat. The terminal remains available."
            )
        } catch {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            phase = .failed(
                "Could not prepare native chat. Check the worker connection and try again."
            )
        }
    }

    private func handleUnavailableNativeChat(fallbackReason: String) {
        if route.presentation == .chat {
            phase = .failed(
                "This chat is still running, but the worker cannot attach to it right now. Update the worker or try again."
            )
        } else {
            phase = .terminalFallback(reason: fallbackReason)
        }
    }
}
