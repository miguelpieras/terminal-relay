import Foundation

/// A bidirectional, non-PTY chat stream over one long-lived SSH process.
///
/// Standard output is the only protocol stream. Standard error is retained only
/// long enough to classify a transport failure and is never surfaced verbatim.
actor MacChatTransport: ChatTransport {
    private enum ProcessEvent: Sendable {
        case standardOutput(Data)
        case standardError(Data)
        case terminated(Int32)
    }

    private let configuration: SSHLaunchConfiguration
    private let connection: MacChatProcessConnection
    private var eventStream: AsyncStream<ChatTransportEvent>?
    private var eventContinuation: AsyncStream<ChatTransportEvent>.Continuation?

    private var decoder = ChatNDJSONDecoder()
    private var runID: UUID?
    private var diagnostic = Data()
    private var requestedDisconnect = false
    private var deliveredDisconnect = false
    private var terminalFailure: ChatTransportFailure?
    private var disconnectContinuations: [CheckedContinuation<Void, Never>] = []
    private var processEventTask: Task<Void, Never>?

    init(
        configuration: SSHLaunchConfiguration,
        connection: MacChatProcessConnection = MacChatProcessConnection()
    ) {
        self.configuration = configuration
        self.connection = connection
    }

    func connect() async throws {
        guard runID == nil else {
            throw ChatTransportFailure(
                category: "already_connected",
                message: "The chat connection is already open.",
                isRecoverable: false
            )
        }

        let newRunID = UUID()
        runID = newRunID
        decoder = ChatNDJSONDecoder()
        diagnostic.removeAll(keepingCapacity: true)
        requestedDisconnect = false
        deliveredDisconnect = false
        terminalFailure = nil
        let processEvents = AsyncStream.makeStream(of: ProcessEvent.self)
        processEventTask = Task { [weak self] in
            for await event in processEvents.stream {
                guard let self else { return }
                await self.receive(event, runID: newRunID)
            }
        }

        do {
            try connection.connect(
                configuration: configuration,
                callbacks: .init(
                    receiveStandardOutput: { data in
                        processEvents.continuation.yield(.standardOutput(data))
                    },
                    receiveStandardError: { data in
                        processEvents.continuation.yield(.standardError(data))
                    },
                    terminate: { status in
                        processEvents.continuation.yield(.terminated(status))
                        processEvents.continuation.finish()
                    }
                )
            )
        } catch {
            processEvents.continuation.finish()
            processEventTask?.cancel()
            processEventTask = nil
            runID = nil
            throw ChatTransportFailure(
                category: "launch_failed",
                message: "Terminal Relay could not start the secure chat connection.",
                isRecoverable: true
            )
        }
    }

    func send(_ envelope: ChatEnvelope) async throws {
        guard runID != nil, terminalFailure == nil else {
            throw ChatTransportFailure(
                category: "not_connected",
                message: "The chat connection is not open.",
                isRecoverable: true
            )
        }

        do {
            try connection.send(ChatNDJSONEncoder.encode(envelope))
        } catch let protocolError as ChatProtocolError {
            throw protocolError
        } catch {
            throw ChatTransportFailure(
                category: "write_failed",
                message: "Terminal Relay could not send data to the worker.",
                isRecoverable: true
            )
        }
    }

    func disconnect() async {
        guard runID != nil else { return }
        requestedDisconnect = true
        await withCheckedContinuation { continuation in
            disconnectContinuations.append(continuation)
            connection.disconnect()
        }
    }

    func events() async -> AsyncStream<ChatTransportEvent> {
        if let eventStream {
            return eventStream
        }
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        eventStream = pair.stream
        eventContinuation = pair.continuation
        return pair.stream
    }

    private func receive(_ event: ProcessEvent, runID: UUID) {
        switch event {
        case .standardOutput(let data):
            receiveStandardOutput(data, runID: runID)
        case .standardError(let data):
            receiveStandardError(data, runID: runID)
        case .terminated(let status):
            processTerminated(status: status, runID: runID)
        }
    }

    private func receiveStandardOutput(_ data: Data, runID: UUID) {
        guard self.runID == runID, terminalFailure == nil else { return }

        do {
            for envelope in try decoder.append(data) {
                eventContinuation?.yield(.envelope(envelope))
            }
        } catch {
            failProtocol(error, runID: runID)
        }
    }

    private func receiveStandardError(_ data: Data, runID: UUID) {
        guard self.runID == runID, diagnostic.count < 8_192 else { return }
        diagnostic.append(data.prefix(8_192 - diagnostic.count))
    }

    private func processTerminated(status: Int32, runID: UUID) {
        guard self.runID == runID else { return }

        if terminalFailure == nil {
            do {
                _ = try decoder.finish()
            } catch {
                terminalFailure = Self.protocolFailure(for: error)
            }
        }

        let failure: ChatTransportFailure?
        if let terminalFailure {
            failure = terminalFailure
        } else if status == 0 {
            failure = nil
        } else {
            failure = Self.transportFailure(exitStatus: status, diagnostic: diagnostic)
        }

        self.runID = nil
        processEventTask = nil
        diagnostic.removeAll(keepingCapacity: false)
        if !requestedDisconnect, !deliveredDisconnect {
            deliveredDisconnect = true
            eventContinuation?.yield(.disconnected(failure))
        }
        eventContinuation?.finish()
        eventContinuation = nil
        eventStream = nil
        let continuations = disconnectContinuations
        disconnectContinuations.removeAll(keepingCapacity: false)
        continuations.forEach { $0.resume() }
    }

    private func failProtocol(_ error: Error, runID: UUID) {
        guard self.runID == runID, terminalFailure == nil else { return }
        terminalFailure = Self.protocolFailure(for: error)
        if !deliveredDisconnect {
            deliveredDisconnect = true
            eventContinuation?.yield(.disconnected(terminalFailure))
        }
        connection.disconnect()
    }

    private static func protocolFailure(for error: Error) -> ChatTransportFailure {
        ChatTransportFailure(
            category: "protocol_error",
            message: (error as? LocalizedError)?.errorDescription
                ?? "The worker sent invalid chat data.",
            isRecoverable: false
        )
    }

    private static func transportFailure(
        exitStatus: Int32,
        diagnostic: Data
    ) -> ChatTransportFailure {
        let normalized = String(decoding: diagnostic, as: UTF8.self).lowercased()
        if normalized.contains("host key verification failed")
            || normalized.contains("remote host identification has changed") {
            return ChatTransportFailure(
                category: "host_key_failed",
                message: "The worker host identity could not be verified.",
                isRecoverable: false
            )
        }
        if normalized.contains("permission denied")
            || normalized.contains("authentication failed") {
            return ChatTransportFailure(
                category: "authentication_failed",
                message: "The worker rejected SSH authentication.",
                isRecoverable: false
            )
        }
        if normalized.contains("timed out")
            || normalized.contains("connection refused")
            || normalized.contains("no route to host") {
            return ChatTransportFailure(
                category: "network_unavailable",
                message: "The worker could not be reached.",
                isRecoverable: true
            )
        }
        return ChatTransportFailure(
            category: "ssh_exit_\(exitStatus)",
            message: "The secure chat connection ended unexpectedly.",
            isRecoverable: true
        )
    }
}
