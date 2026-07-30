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
    case terminal
    case failed(String)
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
    private var preparationTask: Task<Void, Never>?
    private var operationID = UUID()

    init(
        profile: WorkerProfile,
        route: TerminalRoute,
        identityStore: SSHIdentityStore = SSHIdentityStore()
    ) {
        self.route = route
        self.kind = route.kind
        self.repositoryName = route.repositoryName
        self.dependencies = .live(profile: profile, identityStore: identityStore)
        self.launchArguments = AgentLaunchDefaults.standard.chatArguments(for: route.kind)
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
            guard route.instanceToken != nil else {
                phase = .failed("This legacy terminal is no longer available.")
                return
            }
            phase = .terminal
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
        case .terminal, .failed:
            break
        }
    }

    func reconnectAfterForeground() {
        switch phase {
        case .preparing:
            start()
        case .chat:
            coordinator?.start()
        case .terminal, .failed:
            break
        }
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
                phase = .failed(unavailableNativeChatMessage)
                return
            }

            let identity: ChatConversationIdentity
            if let relayID = route.instanceToken {
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
            self.coordinator = coordinator
            phase = .chat
            coordinator.start()
        } catch WorkerChatProtocolError.missingMarker {
            guard self.operationID == operationID else { return }
            phase = .failed(unavailableNativeChatMessage)
        } catch {
            guard self.operationID == operationID, !Task.isCancelled else { return }
            phase = .failed(
                "Could not prepare native chat. Check the worker connection and try again."
            )
        }
    }

    private var unavailableNativeChatMessage: String {
        if route.instanceToken != nil {
            return "This conversation is still running, but this worker cannot attach to it with native chat. Update the worker or try again."
        }
        return "Native chat is not available on this worker. Update the worker and try again."
    }
}
