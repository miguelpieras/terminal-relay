import Foundation
@testable import TerminalRelay

enum ChatTestFixtures {
    static let relayID = "00000000-0000-4000-8000-000000000001"
    static let threadID = "00000000-0000-4000-8000-000000000002"
    static let generation = "00000000-0000-4000-8000-000000000003"
    static let accountID = ProviderAccountID(
        UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    )

    static var identity: ChatConversationIdentity {
        ChatConversationIdentity(
            relayID: relayID,
            provider: .codex,
            accountID: accountID,
            providerThreadID: threadID
        )
    }

    static func event(
        _ type: String,
        sequence: Int64,
        itemID: String? = nil,
        turnID: String? = nil,
        payload: JSONValue = .object([:]),
        snapshotGeneration: String? = generation
    ) -> ChatEnvelope {
        ChatEnvelope(
            type: type,
            eventID: String(
                format: "00000000-0000-4000-8%03lld-%012lld",
                sequence % 1_000,
                sequence
            ),
            relayID: relayID,
            provider: .codex,
            accountID: accountID,
            providerThreadID: threadID,
            snapshotGeneration: snapshotGeneration,
            sequence: sequence,
            occurredAt: sequence,
            turnID: turnID,
            itemID: itemID,
            payload: payload
        )
    }

    static func snapshotEvent(
        baseSequence: Int64,
        items: [ConversationItem] = [],
        approvals: [ApprovalRequest] = [],
        questions: [QuestionRequest] = [],
        turnState: TurnState = .idle,
        activeTurnID: String? = nil,
        lastErrorMessage: String? = nil,
        hasOlderHistory: Bool = false
    ) throws -> ChatEnvelope {
        let snapshot = ConversationSnapshot(
            snapshotGeneration: generation,
            baseSequence: baseSequence,
            items: items,
            approvals: approvals,
            questions: questions,
            connectionState: .streaming,
            turnState: turnState,
            activeTurnID: activeTurnID,
            lastErrorMessage: lastErrorMessage,
            capabilities: ChatCapabilities(features: ["streaming"]),
            hasOlderHistory: hasOlderHistory,
            oldestItemID: items.first?.id
        )
        return event(
            "conversation.snapshot",
            sequence: max(baseSequence, 1),
            payload: try JSONValue.encoded(snapshot)
        )
    }

    static func pendingApproval(
        id: String = "approval-1",
        destructive: Bool = false
    ) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            turnID: "turn-1",
            providerConnectionGeneration: "provider-generation-1",
            providerRequestID: .number(42),
            title: "Run command?",
            reason: "The command changes files.",
            context: "git status",
            decisions: [
                ApprovalDecision(
                    id: "approve",
                    label: "Approve",
                    isDestructive: destructive
                ),
                ApprovalDecision(id: "deny", label: "Deny"),
            ],
            status: .pending,
            occurredAt: 1
        )
    }

    static func pendingQuestion(
        id: String = "question-1",
        kind: QuestionKind = .singleChoice
    ) -> QuestionRequest {
        QuestionRequest(
            id: id,
            turnID: "turn-1",
            providerConnectionGeneration: "provider-generation-1",
            providerRequestID: .string("request-1"),
            prompt: "Choose an option",
            kind: kind,
            options: [
                QuestionOption(id: "a", label: "A"),
                QuestionOption(id: "b", label: "B"),
            ],
            allowsOther: false,
            status: .pending,
            occurredAt: 1
        )
    }
}

/// Fails `connect()` a scripted number of times before succeeding, so tests
/// can drive a coordinator through the fast retry budget into the slow
/// lane and, optionally, back out via a delivered attach response.
actor SlowLaneScriptedTransport: ChatTransport {
    private let failuresBeforeSuccess: Int
    private let connectFailure: ChatTransportFailure
    private let attachResponse: @Sendable (Int) -> ChatEnvelope?
    private var connectAttempts = 0
    private var attachCount = 0
    private var isConnected = false
    private var stream: AsyncStream<ChatTransportEvent>
    private var continuation: AsyncStream<ChatTransportEvent>.Continuation

    init(
        failuresBeforeSuccess: Int,
        connectFailure: ChatTransportFailure = ChatTransportFailure(
            category: "network",
            message: "Connection refused.",
            isRecoverable: true
        ),
        attachResponse: @escaping @Sendable (Int) -> ChatEnvelope? = { _ in nil }
    ) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        self.connectFailure = connectFailure
        self.attachResponse = attachResponse
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func connect() async throws {
        connectAttempts += 1
        guard connectAttempts > failuresBeforeSuccess else {
            throw connectFailure
        }
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
        if envelope.type == "session.attach" {
            attachCount += 1
            if let response = attachResponse(attachCount) {
                continuation.yield(.envelope(response))
            }
        }
    }

    func disconnect(sendingBestEffort envelope: ChatEnvelope?) async {
        guard isConnected else { return }
        isConnected = false
        continuation.finish()
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func events() async -> AsyncStream<ChatTransportEvent> {
        stream
    }

    /// Mirrors a real remote failure: the transport emits `.disconnected`,
    /// finishes its stream, and serves a fresh one on the next connect.
    func emitRemoteDisconnect(_ failure: ChatTransportFailure?) {
        continuation.yield(.disconnected(failure))
        continuation.finish()
        isConnected = false
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        stream = pair.stream
        continuation = pair.continuation
    }

    func connectAttemptCount() -> Int {
        connectAttempts
    }
}
