import Foundation
import NIOSSH

enum IOSSSHChatConnectionCallback: Equatable, Sendable {
    case event(SSHStreamingExecEvent)
    case state(SSHStreamingExecState)
}

/// A single ordered queue for every callback from one SSH connection
/// generation. The NIO transport invokes its callbacks on one serial queue;
/// yielding them into one AsyncStream preserves final-stdout-before-close
/// ordering while crossing into the transport actor.
final class IOSSSHChatOrderedCallbackPump: @unchecked Sendable {
    let stream: AsyncStream<IOSSSHChatConnectionCallback>
    private let continuation:
        AsyncStream<IOSSSHChatConnectionCallback>.Continuation

    init() {
        let pair = AsyncStream.makeStream(
            of: IOSSSHChatConnectionCallback.self
        )
        stream = pair.stream
        continuation = pair.continuation
    }

    @discardableResult
    func yield(
        _ callback: IOSSSHChatConnectionCallback
    ) -> AsyncStream<IOSSSHChatConnectionCallback>.Continuation.YieldResult {
        continuation.yield(callback)
    }

    func finish() {
        continuation.finish()
    }
}

struct IOSSSHChatConnectionLifecycle: Equatable {
    enum Phase: Equatable {
        case disconnected
        case connecting
        case connected
    }

    enum BeginResult: Equatable {
        case started
        case alreadyConnecting
        case alreadyConnected
    }

    private(set) var phase = Phase.disconnected
    private var didPublishDisconnect = true

    mutating func begin() -> BeginResult {
        switch phase {
        case .disconnected:
            phase = .connecting
            didPublishDisconnect = false
            return .started
        case .connecting:
            return .alreadyConnecting
        case .connected:
            return .alreadyConnected
        }
    }

    @discardableResult
    mutating func markConnected() -> Bool {
        guard phase == .connecting else { return false }
        phase = .connected
        return true
    }

    /// Returns true exactly once per connection generation so disconnect
    /// callbacks remain idempotent even when parent and child channels close.
    mutating func finish() -> Bool {
        phase = .disconnected
        guard !didPublishDisconnect else { return false }
        didPublishDisconnect = true
        return true
    }
}

struct IOSSSHChatStreamState {
    private var decoder = ChatNDJSONDecoder()
    private(set) var exitStatus: Int?
    private(set) var exitSignal: String?

    mutating func receive(_ event: SSHStreamingExecEvent) throws -> [ChatEnvelope] {
        switch event {
        case .standardOutput(let data):
            return try decoder.append(data)
        case .standardError:
            // Diagnostics never enter the NDJSON decoder or conversation.
            return []
        case .exitStatus(let status):
            if exitStatus == nil {
                exitStatus = status
            }
            return []
        case .exitSignal(let signal):
            if exitSignal == nil {
                exitSignal = signal
            }
            return []
        }
    }

    mutating func finish() throws {
        _ = try decoder.finish()
    }

    func terminationFailure() -> ChatTransportFailure? {
        if exitSignal != nil {
            return ChatTransportFailure(
                category: "remote_signal",
                message: "The worker closed the chat process.",
                isRecoverable: true
            )
        }
        if let exitStatus, exitStatus != 0 {
            return ChatTransportFailure(
                category: "remote_exit",
                message: "The worker chat process exited with status \(exitStatus).",
                isRecoverable: true
            )
        }
        return nil
    }
}

enum IOSSSHChatFailurePolicy {
    static func failure(
        for reason: SSHStreamingExecFailure
    ) -> ChatTransportFailure {
        switch reason {
        case .hostKey:
            ChatTransportFailure(
                category: "host_key",
                message: "The worker identity could not be verified. Check the saved pairing.",
                isRecoverable: false
            )
        case .authentication:
            ChatTransportFailure(
                category: "authentication",
                message: "The worker did not accept this device. Pair it again.",
                isRecoverable: false
            )
        case .connection:
            ChatTransportFailure(
                category: "ssh",
                message: "The secure worker connection was interrupted.",
                isRecoverable: true
            )
        }
    }
}

actor IOSSSHChatTransport: ChatTransport {
    private let profile: WorkerProfile
    private let command: String
    private let identityStore: SSHIdentityStore
    private var eventContinuation:
        AsyncStream<ChatTransportEvent>.Continuation?

    private var lifecycle = IOSSSHChatConnectionLifecycle()
    private var connection: SSHStreamingExecConnection?
    private var connectionGeneration = UUID()
    private var streamState = IOSSSHChatStreamState()
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var isLocalDisconnect = false
    private var callbackPump: IOSSSHChatOrderedCallbackPump?
    private var callbackTask: Task<Void, Never>?

    init(
        profile: WorkerProfile,
        command: String,
        identityStore: SSHIdentityStore = SSHIdentityStore()
    ) {
        self.profile = profile
        self.command = command
        self.identityStore = identityStore
    }

    func connect() async throws {
        switch lifecycle.begin() {
        case .alreadyConnected:
            return
        case .alreadyConnecting:
            throw ChatTransportFailure(
                category: "already_connecting",
                message: "The chat connection is already being opened.",
                isRecoverable: true
            )
        case .started:
            break
        }

        let privateKey: NIOSSHPrivateKey
        do {
            privateKey = try identityStore.loadOrCreatePrivateKey()
        } catch {
            _ = lifecycle.finish()
            throw ChatTransportFailure(
                category: "identity",
                message: "The device SSH identity is unavailable.",
                isRecoverable: false
            )
        }

        streamState = IOSSSHChatStreamState()
        isLocalDisconnect = false
        let generation = UUID()
        connectionGeneration = generation
        let callbackPump = IOSSSHChatOrderedCallbackPump()
        self.callbackPump = callbackPump
        callbackTask = Task { [weak self] in
            for await callback in callbackPump.stream {
                guard !Task.isCancelled else { return }
                await self?.receive(callback, generation: generation)
            }
        }

        let connection = SSHStreamingExecConnection(
            profile: profile,
            privateKey: privateKey,
            command: command,
            onEvent: { event in
                callbackPump.yield(.event(event))
            },
            onStateChange: { newState in
                callbackPump.yield(.state(newState))
            }
        )
        self.connection = connection

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connectContinuation = continuation
            connection.connect()
        }
    }

    func send(_ envelope: ChatEnvelope) async throws {
        guard lifecycle.phase == .connected, let connection else {
            throw ChatTransportFailure(
                category: "not_connected",
                message: "The chat connection is offline. Reconnect and try again.",
                isRecoverable: true
            )
        }

        let data = try ChatNDJSONEncoder.encode(envelope)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            connection.send(data) { result in
                continuation.resume(with: result)
            }
        }
    }

    func disconnect(sendingBestEffort envelope: ChatEnvelope?) async {
        isLocalDisconnect = true
        connectionGeneration = UUID()
        endCallbackPump(cancelTask: true)
        if let envelope,
           let data = try? ChatNDJSONEncoder.encode(envelope) {
            connection?.send(data)
        }
        connection?.disconnect()
        connection = nil
        resumeConnect(
            with: .failure(
                ChatTransportFailure(
                    category: "cancelled",
                    message: "The chat connection was closed.",
                    isRecoverable: true
                )
            )
        )
        _ = lifecycle.finish()
        eventContinuation?.finish()
        eventContinuation = nil
    }

    func events() async -> AsyncStream<ChatTransportEvent> {
        eventContinuation?.finish()
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        eventContinuation = pair.continuation
        return pair.stream
    }

    private func receive(
        _ callback: IOSSSHChatConnectionCallback,
        generation: UUID
    ) {
        guard generation == connectionGeneration else { return }
        switch callback {
        case .event(let event):
            receive(event, generation: generation)
        case .state(let state):
            receive(state, generation: generation)
        }
    }

    private func receive(
        _ event: SSHStreamingExecEvent,
        generation: UUID
    ) {
        guard generation == connectionGeneration else { return }

        do {
            for envelope in try streamState.receive(event) {
                eventContinuation?.yield(.envelope(envelope))
            }
        } catch {
            failProtocol(error)
        }
    }

    private func receive(
        _ newState: SSHStreamingExecState,
        generation: UUID
    ) {
        guard generation == connectionGeneration else { return }

        switch newState {
        case .connecting:
            break
        case .connected:
            if lifecycle.markConnected() {
                resumeConnect(with: .success(()))
            }
        case .disconnected:
            finishConnection(failure: streamState.terminationFailure())
        case .failed(let reason):
            finishConnection(
                failure: IOSSSHChatFailurePolicy.failure(for: reason)
            )
        }
    }

    private func failProtocol(_ error: Error) {
        let activeConnection = connection
        let failure = ChatTransportFailure(
            category: "protocol",
            message: error.localizedDescription,
            isRecoverable: false
        )
        finishConnection(failure: failure)
        activeConnection?.disconnect()
    }

    private func finishConnection(failure: ChatTransportFailure?) {
        guard lifecycle.phase != .disconnected else { return }
        let wasConnecting = lifecycle.phase == .connecting
        connection = nil

        if wasConnecting {
            resumeConnect(
                with: .failure(
                    failure ?? ChatTransportFailure(
                        category: "connection_closed",
                        message: "The worker closed the chat connection.",
                        isRecoverable: true
                    )
                )
            )
        }

        do {
            try streamState.finish()
        } catch {
            if lifecycle.finish() {
                eventContinuation?.yield(
                    .disconnected(
                        ChatTransportFailure(
                            category: "protocol",
                            message: error.localizedDescription,
                            isRecoverable: false
                        )
                    )
                )
            }
            eventContinuation?.finish()
            eventContinuation = nil
            endCallbackPump(cancelTask: false)
            return
        }
        if lifecycle.finish() {
            eventContinuation?.yield(
                .disconnected(isLocalDisconnect ? nil : failure)
            )
        }
        eventContinuation?.finish()
        eventContinuation = nil
        endCallbackPump(cancelTask: false)
    }

    private func resumeConnect(with result: Result<Void, Error>) {
        guard let continuation = connectContinuation else { return }
        connectContinuation = nil
        continuation.resume(with: result)
    }

    private func endCallbackPump(cancelTask: Bool) {
        callbackPump?.finish()
        callbackPump = nil
        let task = callbackTask
        callbackTask = nil
        if cancelTask {
            task?.cancel()
        }
    }

    deinit {
        callbackPump?.finish()
        callbackTask?.cancel()
        eventContinuation?.finish()
        connection?.disconnect()
    }
}
