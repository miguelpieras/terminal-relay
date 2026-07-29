import Foundation
@testable import TerminalRelay

enum ChatTestFixtures {
    static let relayID = "00000000-0000-4000-8000-000000000001"
    static let threadID = "00000000-0000-4000-8000-000000000002"
    static let generation = "00000000-0000-4000-8000-000000000003"

    static var identity: ChatConversationIdentity {
        ChatConversationIdentity(
            relayID: relayID,
            provider: .codex,
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
