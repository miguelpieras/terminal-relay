import Combine
import Foundation

struct MobileChatSessionDependencies {
    let execute: (String) async throws -> Data
    let executeWithInput: (String, Data) async throws -> Data
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
            executeWithInput: { command, data in
                try await workerClient.execute(
                    command,
                    on: profile,
                    standardInput: data
                )
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
    @Published private(set) var attachmentActions: ChatAttachmentActions?

    let kind: AgentKind
    let repositoryName: String

    private let route: TerminalRoute
    private let dependencies: MobileChatSessionDependencies
    private let launchArguments: [String]
    private let capabilityCacheKey: String?
    private var preparationTask: Task<Void, Never>?
    private var operationID = UUID()

    /// Confirmed native-chat availability per worker and agent kind, so
    /// reopening a conversation skips one full SSH round trip. Only positive
    /// results are cached, and only briefly, so worker updates are noticed.
    private static var confirmedCapabilities: [String: Date] = [:]
    private static let capabilityCacheLifetime: TimeInterval = 10 * 60

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
        self.capabilityCacheKey = "\(profile.id)|\(route.kind.rawValue)"
    }

    init(
        route: TerminalRoute,
        launchArguments: [String] = [],
        dependencies: MobileChatSessionDependencies,
        capabilityCacheKey: String? = nil
    ) {
        self.route = route
        self.kind = route.kind
        self.repositoryName = route.repositoryName
        self.dependencies = dependencies
        self.launchArguments = launchArguments
        self.capabilityCacheKey = capabilityCacheKey
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
            if !hasFreshConfirmedCapability {
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
                if let capabilityCacheKey {
                    Self.confirmedCapabilities[capabilityCacheKey] = Date()
                }
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
            self.attachmentActions = makeAttachmentActions(identity: identity)
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

    private var hasFreshConfirmedCapability: Bool {
        guard let capabilityCacheKey,
              let confirmedAt = Self.confirmedCapabilities[capabilityCacheKey] else {
            return false
        }
        guard Date().timeIntervalSince(confirmedAt) < Self.capabilityCacheLifetime else {
            Self.confirmedCapabilities.removeValue(forKey: capabilityCacheKey)
            return false
        }
        return true
    }

    private func makeAttachmentActions(
        identity: ChatConversationIdentity
    ) -> ChatAttachmentActions? {
        return ChatAttachmentActions(
            upload: { [dependencies, kind, repositoryName] attachment, requestID in
                let command = try WorkerRemoteCommand.uploadChatAttachment(
                    kind: kind,
                    repositoryName: repositoryName,
                    relayID: identity.relayID,
                    requestID: requestID,
                    attachmentID: attachment.id,
                    fileExtension: attachment.fileExtension,
                    byteCount: attachment.byteCount
                )
                let output = try await dependencies.executeWithInput(
                    command,
                    attachment.data
                )
                let path = String(decoding: output, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"),
                      path.utf8.count <= 4_096,
                      path.unicodeScalars.allSatisfy({
                          !CharacterSet.controlCharacters.contains($0)
                      }) else {
                    throw WorkerChatProtocolError.invalidResponse
                }
                return attachment.reference(path: path)
            },
            discard: { [dependencies, kind, repositoryName] requestID in
                guard let command = try? WorkerRemoteCommand.deleteChatAttachmentUpload(
                    kind: kind,
                    repositoryName: repositoryName,
                    relayID: identity.relayID,
                    requestID: requestID
                ) else { return }
                _ = try? await dependencies.execute(command)
            }
        )
    }

    private var unavailableNativeChatMessage: String {
        if route.instanceToken != nil {
            return "This conversation is still running, but this worker cannot attach to it with native chat. Update the worker or try again."
        }
        return "Native chat is not available on this worker. Update the worker and try again."
    }
}
