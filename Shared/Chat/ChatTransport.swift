import Foundation

struct ChatTransportFailure: LocalizedError, Equatable, Sendable {
    let category: String
    let message: String
    let isRecoverable: Bool

    var errorDescription: String? { message }

    init(category: String, message: String, isRecoverable: Bool) {
        self.category = category
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

enum ChatTransportEvent: Equatable, Sendable {
    case envelope(ChatEnvelope)
    case disconnected(ChatTransportFailure?)
}

protocol ChatTransport: AnyObject {
    func connect() async throws
    func send(_ envelope: ChatEnvelope) async throws
    /// Closes only the local attachment. Intentional caller-initiated disconnects
    /// do not emit `.disconnected`; that event is reserved for remote/failure closure.
    func disconnect() async
    func events() async -> AsyncStream<ChatTransportEvent>
}

actor ChatFixtureTransport: ChatTransport {
    typealias CommandHandler = @Sendable (ChatEnvelope) -> [ChatEnvelope]

    private let stream: AsyncStream<ChatTransportEvent>
    private let continuation: AsyncStream<ChatTransportEvent>.Continuation
    private let initialEvents: [ChatEnvelope]
    private let commandHandler: CommandHandler
    private var sent: [ChatEnvelope] = []
    private var isConnected = false
    private var deliveredInitialEvents = false

    init(
        initialEvents: [ChatEnvelope] = [],
        commandHandler: @escaping CommandHandler = { _ in [] }
    ) {
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        stream = pair.stream
        continuation = pair.continuation
        self.initialEvents = initialEvents
        self.commandHandler = commandHandler
    }

    func connect() async throws {
        isConnected = true
    }

    func send(_ envelope: ChatEnvelope) async throws {
        guard isConnected else {
            throw ChatTransportFailure(
                category: "not_connected",
                message: "The chat transport is not connected.",
                isRecoverable: true
            )
        }
        sent.append(envelope)

        if envelope.type == "session.attach", !deliveredInitialEvents {
            deliveredInitialEvents = true
            for event in initialEvents {
                continuation.yield(.envelope(event))
            }
        }
        for event in commandHandler(envelope) {
            continuation.yield(.envelope(event))
        }
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
    }

    func events() async -> AsyncStream<ChatTransportEvent> {
        stream
    }

    func sentEnvelopes() -> [ChatEnvelope] {
        sent
    }

    func yield(_ event: ChatTransportEvent) {
        continuation.yield(event)
    }
}
