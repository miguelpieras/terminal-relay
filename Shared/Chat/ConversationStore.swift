import Combine
import Foundation

struct ConversationState: Equatable, Sendable {
    var snapshotGeneration: String?
    var lastAppliedSequence: Int64 = 0
    var items: [ConversationItem] = []
    var approvals: [ApprovalRequest] = []
    var questions: [QuestionRequest] = []
    var connectionState: ChatConnectionState = .connecting
    var turnState: TurnState = .idle
    var activeTurnID: String?
    var capabilities = ChatCapabilities()
    var usage: ChatUsage?
    var hasOlderHistory = false
    var oldestItemID: String?
    var didTruncateHistory = false
    var lastErrorMessage: String?
    var filePreview: ChatFilePreview?

    var messages: [ChatMessage] {
        items.compactMap {
            guard case .message(let value) = $0 else { return nil }
            return value
        }
    }

    var tools: [ToolActivity] {
        items.compactMap {
            guard case .tool(let value) = $0 else { return nil }
            return value
        }
    }

    var pendingApprovals: [ApprovalRequest] {
        approvals.filter { $0.status == .pending }
    }

    var pendingQuestions: [QuestionRequest] {
        questions.filter { $0.status == .pending }
    }
}

struct DestructiveApprovalConfirmation: Equatable, Sendable {
    let approvalID: String
    let decisionID: String
}

enum ConversationReducerError: LocalizedError, Equatable {
    case sequenceGap(expected: Int64, received: Int64)
    case snapshotGenerationChanged
    case invalidEvent(String)

    var errorDescription: String? {
        switch self {
        case .sequenceGap:
            "Some chat updates were missed. Reconnecting to refresh the conversation."
        case .snapshotGenerationChanged:
            "The worker rebuilt this conversation. Refreshing its current state."
        case .invalidEvent:
            "The worker sent an incomplete chat update."
        }
    }
}

private func reconciledSnapshotTurn(
    turnState: TurnState,
    activeTurnID: String?,
    items: [ConversationItem]
) -> (state: TurnState, activeTurnID: String?) {
    let canInfer: Bool
    switch turnState {
    case .idle, .unknown:
        canInfer = true
    default:
        canInfer = false
    }
    guard canInfer, let inferredTurnID = inFlightTurnID(in: items) else {
        return (turnState, activeTurnID)
    }
    return (.running, inferredTurnID)
}

private func inFlightTurnID(in items: [ConversationItem]) -> String? {
    for item in items.reversed() {
        let candidate: String?
        switch item {
        case .message(let message) where message.isStreaming:
            candidate = message.turnID
        case .reasoning(let reasoning) where reasoning.isStreaming:
            candidate = reasoning.turnID
        case .tool(let tool) where tool.status == .pending || tool.status == .running:
            candidate = tool.turnID
        default:
            candidate = nil
        }
        if let candidate, !candidate.isEmpty {
            return candidate
        }
    }
    return nil
}

struct ConversationReducer {
    let maximumRetainedItems: Int
    let maximumRetainedContentBytes: Int

    init(maximumRetainedItems: Int = 1_000, maximumRetainedContentBytes: Int = 8 * 1_048_576) {
        self.maximumRetainedItems = maximumRetainedItems
        self.maximumRetainedContentBytes = maximumRetainedContentBytes
    }

    func reduce(_ envelope: ChatEnvelope, into state: inout ConversationState) throws {
        let kind = ChatEventKind(rawValue: envelope.type)

        if kind == .conversationSnapshot {
            try applySnapshot(envelope, to: &state)
            return
        }

        // `session.hello` and a pre-attach `error` are attachment-local control
        // records with seq 0. They must be applied without advancing or
        // participating in the durable replay cursor.
        if let sequence = envelope.sequence, sequence > 0 {
            if sequence <= state.lastAppliedSequence {
                return
            }
            let expectedSequence = state.lastAppliedSequence + 1
            if sequence != expectedSequence {
                throw ConversationReducerError.sequenceGap(
                    expected: expectedSequence,
                    received: sequence
                )
            }
            if let currentGeneration = state.snapshotGeneration,
               let incomingGeneration = envelope.snapshotGeneration,
               currentGeneration != incomingGeneration {
                throw ConversationReducerError.snapshotGenerationChanged
            }
            state.lastAppliedSequence = sequence
        }
        if let generation = envelope.snapshotGeneration {
            state.snapshotGeneration = generation
        }

        guard let kind else {
            if envelope.payload["interactive"]?.boolValue == true
                || envelope.payload["blocking"]?.boolValue == true {
                state.lastErrorMessage = "This agent interaction is not supported in native chat."
                state.connectionState = .failed
                return
            }
            applyUnknown(envelope, to: &state)
            return
        }

        switch kind {
        case .sessionHello:
            applyHello(envelope, to: &state)
        case .sessionState:
            if let rawState = envelope.payload["state"]?.stringValue
                ?? envelope.payload["connectionState"]?.stringValue {
                state.connectionState = ChatConnectionState(rawValue: rawState)
            }
        case .sessionHeartbeat, .acknowledgement:
            break
        case .terminalFallbackRequired:
            state.lastErrorMessage = "This agent interaction is not supported in native chat."
            state.connectionState = .failed
        case .sessionEnded:
            state.connectionState = .stopped
            state.turnState = .stopped
            state.activeTurnID = nil
        case .error:
            state.lastErrorMessage = envelope.payload["message"]?.stringValue
                ?? "The worker could not complete that chat action."
            if envelope.payload["code"]?.stringValue == "turnActive" {
                if let requestID = envelope.requestID
                    ?? envelope.payload["requestId"]?.stringValue {
                    state.items.removeAll { item in
                        guard case .message(let message) = item else { return false }
                        return message.isOptimistic && message.id == "client:\(requestID)"
                    }
                }
                let reconciled = reconciledSnapshotTurn(
                    turnState: state.turnState,
                    activeTurnID: state.activeTurnID,
                    items: state.items
                )
                state.turnState = reconciled.state
                state.activeTurnID = reconciled.activeTurnID
            }
            if envelope.payload["fatal"]?.boolValue == true {
                state.connectionState = .failed
            }
        case .historyPage:
            try applyHistoryPage(envelope, to: &state)
        case .messageStarted, .messageDelta, .messageCompleted:
            try applyMessage(envelope, kind: kind, to: &state)
        case .reasoningStarted, .reasoningDelta, .reasoningCompleted:
            try applyReasoning(envelope, kind: kind, to: &state)
        case .toolStarted, .toolUpdated, .toolCompleted:
            try applyTool(envelope, kind: kind, to: &state)
        case .fileChangeUpdated, .diffUpdated:
            try applyDiff(envelope, to: &state)
        case .filePreview:
            try applyFilePreview(envelope, to: &state)
        case .approvalRequested:
            try applyApproval(envelope, to: &state)
        case .approvalResolved, .approvalExpired:
            resolveApproval(envelope, expired: kind == .approvalExpired, in: &state)
        case .questionRequested:
            try applyQuestion(envelope, to: &state)
        case .questionResolved, .questionExpired:
            resolveQuestion(envelope, expired: kind == .questionExpired, in: &state)
        case .planUpdated:
            try applyPlan(envelope, to: &state)
        case .usageUpdated:
            state.usage = try? envelope.decodePayload(ChatUsage.self)
        case .turnStarted:
            state.activeTurnID = envelope.turnID ?? envelope.payload["turnId"]?.stringValue
            state.turnState = .running
            state.connectionState = .streaming
            state.lastErrorMessage = nil
        case .turnCompleted:
            finishTurnItems(
                turnID: terminalTurnID(from: envelope, fallback: state.activeTurnID),
                toolStatus: .completed,
                in: &state
            )
            state.turnState = .completed
            state.activeTurnID = nil
            state.connectionState = .streaming
        case .turnFailed:
            finishTurnItems(
                turnID: terminalTurnID(from: envelope, fallback: state.activeTurnID),
                toolStatus: .failed,
                in: &state
            )
            state.turnState = .failed
            state.activeTurnID = nil
            state.connectionState = .streaming
            state.lastErrorMessage = envelope.payload["message"]?.stringValue
                ?? "The agent could not finish this turn."
        case .turnInterrupted:
            finishTurnItems(
                turnID: terminalTurnID(from: envelope, fallback: state.activeTurnID),
                toolStatus: .cancelled,
                in: &state
            )
            state.turnState = .interrupted
            state.activeTurnID = nil
            state.connectionState = .interrupted
        case .conversationSnapshot:
            break
        }

    }

    private func applySnapshot(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        let snapshot: ConversationSnapshot
        do {
            snapshot = try envelope.decodePayload(ConversationSnapshot.self)
        } catch {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        state.snapshotGeneration = snapshot.snapshotGeneration
        state.lastAppliedSequence = snapshot.baseSequence
        state.items = stableDeduplicated(snapshot.items)
        state.approvals = stableDeduplicated(snapshot.approvals)
        state.questions = stableDeduplicated(snapshot.questions)
        state.connectionState = snapshot.connectionState
        let reconciledTurn = reconciledSnapshotTurn(
            turnState: snapshot.turnState,
            activeTurnID: snapshot.activeTurnID,
            items: state.items
        )
        state.turnState = reconciledTurn.state
        state.activeTurnID = reconciledTurn.activeTurnID
        if state.activeTurnID == nil, !state.turnState.isActive {
            finishInactiveSnapshotItems(
                toolStatus: snapshotToolStatus(for: state.turnState),
                in: &state
            )
        }
        state.capabilities = snapshot.capabilities
        state.usage = snapshot.usage
        state.hasOlderHistory = snapshot.hasOlderHistory
        state.oldestItemID = snapshot.oldestItemID
        state.lastErrorMessage = nil
    }

    private func applyHello(_ envelope: ChatEnvelope, to state: inout ConversationState) {
        if let capabilities = try? envelope.decodePayload(ChatCapabilities.self) {
            state.capabilities = capabilities
        } else if let capabilitiesValue = envelope.payload["capabilities"],
                  let capabilities: ChatCapabilities = try? capabilitiesValue.decoded() {
            state.capabilities = capabilities
        }
        if let rawState = envelope.payload["connectionState"]?.stringValue {
            state.connectionState = ChatConnectionState(rawValue: rawState)
        } else {
            state.connectionState = .streaming
        }
        state.lastErrorMessage = nil
    }

    private func applyHistoryPage(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        let values = envelope.payload["items"]?.arrayValue ?? []
        let items = try values.map { value -> ConversationItem in
            do {
                return try value.decoded()
            } catch {
                throw ConversationReducerError.invalidEvent(envelope.type)
            }
        }
        let existingIDs = Set(state.items.map(\.id))
        let newItems = items.filter { !existingIDs.contains($0.id) }
        state.items.insert(contentsOf: newItems, at: 0)
        state.hasOlderHistory = envelope.payload["hasOlderHistory"]?.boolValue ?? false
        state.oldestItemID = envelope.payload["oldestItemId"]?.stringValue ?? state.items.first?.id
    }

    private func applyMessage(
        _ envelope: ChatEnvelope,
        kind: ChatEventKind,
        to state: inout ConversationState
    ) throws {
        guard let itemID = resolvedItemID(envelope) else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let text = envelope.payload["text"]?.stringValue
            ?? envelope.payload["content"]?.stringValue
            ?? ""
        let role = ChatMessageRole(
            rawValue: envelope.payload["role"]?.stringValue ?? "assistant"
        ) ?? .assistant
        if let clientMessageID = envelope.payload["clientUserMessageId"]?.stringValue {
            state.items.removeAll { item in
                guard case .message(let message) = item else { return false }
                return message.id == "client:\(clientMessageID)" && message.id != itemID
            }
        }

        if let index = state.items.lastIndex(where: { $0.id == itemID }),
           case .message(var message) = state.items[index] {
            message.turnID = envelope.turnID ?? message.turnID
            message.occurredAt = envelope.occurredAt ?? message.occurredAt
            switch kind {
            case .messageDelta:
                message.append(text, contentID: envelope.payload["contentId"]?.stringValue)
            case .messageCompleted:
                message.complete(
                    text: text.isEmpty && envelope.payload["text"] == nil && envelope.payload["content"] == nil
                        ? nil
                        : text,
                    isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                    originalByteCount: envelope.payload["originalByteCount"]?.intValue
                )
            default:
                if !text.isEmpty, message.text.isEmpty {
                    message.complete(text: text)
                    message.isStreaming = true
                }
            }
            state.items[index] = .message(message)
            return
        }

        let isStreaming = kind != .messageCompleted
        var message = ChatMessage(
            id: itemID,
            turnID: envelope.turnID,
            role: role,
            text: text,
            occurredAt: envelope.occurredAt,
            isStreaming: isStreaming
        )
        if kind == .messageCompleted {
            message.complete(
                text: text,
                isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                originalByteCount: envelope.payload["originalByteCount"]?.intValue
            )
        }
        state.items.append(.message(message))
    }

    private func applyReasoning(
        _ envelope: ChatEnvelope,
        kind: ChatEventKind,
        to state: inout ConversationState
    ) throws {
        guard let itemID = resolvedItemID(envelope) else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let text = envelope.payload["text"]?.stringValue ?? ""
        if let index = state.items.lastIndex(where: { $0.id == itemID }),
           case .reasoning(var reasoning) = state.items[index] {
            if kind == .reasoningCompleted {
                if !text.isEmpty { reasoning.text = text }
                reasoning.isStreaming = false
            } else if kind == .reasoningDelta {
                reasoning.text += text
                reasoning.isStreaming = true
            }
            state.items[index] = .reasoning(reasoning)
        } else {
            state.items.append(
                .reasoning(
                    ChatReasoning(
                        id: itemID,
                        turnID: envelope.turnID,
                        text: text,
                        isStreaming: kind != .reasoningCompleted,
                        occurredAt: envelope.occurredAt
                    )
                )
            )
        }
    }

    private func applyTool(
        _ envelope: ChatEnvelope,
        kind: ChatEventKind,
        to state: inout ConversationState
    ) throws {
        guard let itemID = resolvedItemID(envelope) else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let status: ToolActivityStatus = {
            if let raw = envelope.payload["status"]?.stringValue,
               let parsed = ToolActivityStatus(rawValue: raw) {
                return parsed
            }
            switch kind {
            case .toolCompleted:
                return envelope.payload["error"]?.isNonNull == true ? .failed : .completed
            case .toolStarted:
                return .running
            default:
                return .running
            }
        }()

        let toolKind = ToolActivityKind(rawValue: envelope.payload["kind"]?.stringValue ?? "") ?? .generic
        let title = envelope.payload["title"]?.stringValue
            ?? envelope.payload["name"]?.stringValue
            ?? "Agent activity"

        if let index = state.items.lastIndex(where: { $0.id == itemID }),
           case .tool(var tool) = state.items[index] {
            tool.title = title
            tool.status = status
            tool.input = envelope.payload["input"]?.displayString ?? tool.input
            tool.output = envelope.payload["output"]?.displayString ?? tool.output
            tool.errorMessage = envelope.payload["error"]?.displayString ?? tool.errorMessage
            tool.durationMilliseconds = envelope.payload["durationMs"]?.int64Value ?? tool.durationMilliseconds
            tool.exitCode = envelope.payload["exitCode"]?.intValue ?? tool.exitCode
            tool.isTruncated = envelope.payload["truncated"]?.boolValue ?? tool.isTruncated
            tool.originalByteCount = envelope.payload["originalByteCount"]?.intValue ?? tool.originalByteCount
            state.items[index] = .tool(tool)
        } else {
            state.items.append(
                .tool(
                    ToolActivity(
                        id: itemID,
                        turnID: envelope.turnID,
                        kind: toolKind,
                        title: title,
                        status: status,
                        input: envelope.payload["input"]?.displayString,
                        output: envelope.payload["output"]?.displayString,
                        errorMessage: envelope.payload["error"]?.displayString,
                        durationMilliseconds: envelope.payload["durationMs"]?.int64Value,
                        exitCode: envelope.payload["exitCode"]?.intValue,
                        occurredAt: envelope.occurredAt,
                        isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                        originalByteCount: envelope.payload["originalByteCount"]?.intValue
                    )
                )
            )
        }
    }

    private func applyDiff(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        guard let itemID = resolvedItemID(envelope) else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let diff = ChatDiff(
            id: itemID,
            turnID: envelope.turnID,
            path: envelope.payload["path"]?.stringValue,
            unifiedDiff: envelope.payload["diff"]?.stringValue
                ?? envelope.payload["unifiedDiff"]?.stringValue
                ?? "",
            occurredAt: envelope.occurredAt,
            isTruncated: envelope.payload["truncated"]?.boolValue ?? false
        )
        replaceOrAppend(.diff(diff), in: &state)
    }

    private func applyFilePreview(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        guard let path = envelope.payload["path"]?.stringValue,
              let content = envelope.payload["content"]?.stringValue else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        state.filePreview = ChatFilePreview(
            id: envelope.itemID ?? path,
            path: path,
            content: content,
            line: envelope.payload["line"]?.intValue,
            column: envelope.payload["column"]?.intValue,
            isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
            originalByteCount: envelope.payload["originalByteCount"]?.intValue
        )
    }

    private func applyApproval(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        let payload = envelope.payload
        guard let displayID = payload["displayId"]?.stringValue ?? envelope.itemID,
              let generation = payload["providerConnectionGeneration"]?.stringValue,
              let providerRequestID = payload["providerRequestId"] else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let decisions = (payload["decisions"]?.arrayValue ?? []).compactMap { value -> ApprovalDecision? in
            guard let id = value["id"]?.stringValue else { return nil }
            return ApprovalDecision(
                id: id,
                label: value["label"]?.stringValue ?? id,
                isDestructive: value["destructive"]?.boolValue ?? false
            )
        }
        let request = ApprovalRequest(
            id: displayID,
            turnID: envelope.turnID,
            providerConnectionGeneration: generation,
            providerRequestID: providerRequestID,
            title: payload["title"]?.stringValue ?? "Approval needed",
            reason: payload["reason"]?.stringValue,
            context: payload["context"]?.displayString,
            decisions: decisions.isEmpty
                ? [
                    ApprovalDecision(id: "approve", label: "Approve"),
                    ApprovalDecision(id: "deny", label: "Deny"),
                ]
                : decisions,
            status: .pending,
            occurredAt: envelope.occurredAt
        )
        replaceOrAppend(request, in: &state.approvals)
        state.connectionState = .awaitingApproval
        state.turnState = .awaitingApproval
    }

    private func resolveApproval(_ envelope: ChatEnvelope, expired: Bool, in state: inout ConversationState) {
        guard let id = envelope.payload["displayId"]?.stringValue ?? envelope.itemID,
              let index = state.approvals.firstIndex(where: { $0.id == id }) else {
            return
        }
        let rawDecision = envelope.payload["decision"]?.stringValue
        state.approvals[index].status = expired
            ? .expired
            : (rawDecision == "deny" || rawDecision == "denied" ? .denied : .approved)
        restoreStreamingStateIfNoPendingInteraction(in: &state)
    }

    private func applyQuestion(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        let payload = envelope.payload
        let fields = questionFields(from: payload)
        let groupPrompt = payload["prompt"]?.stringValue
            ?? payload["title"]?.stringValue
            ?? (fields.count > 1
                ? "Agent needs \(fields.count) answers"
                : fields.first?.prompt)
        guard let displayID = payload["displayId"]?.stringValue ?? envelope.itemID,
              let generation = payload["providerConnectionGeneration"]?.stringValue
                ?? payload["connectionGeneration"]?.stringValue,
              let providerRequestID = payload["providerRequestId"]
                ?? payload["providerRequestID"],
              let prompt = groupPrompt else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let options = (payload["options"]?.arrayValue ?? []).compactMap { value -> QuestionOption? in
            guard let id = value["id"]?.stringValue ?? value["value"]?.stringValue else { return nil }
            return QuestionOption(
                id: id,
                label: value["label"]?.stringValue ?? id,
                detail: value["detail"]?.stringValue
            )
        }
        let request = QuestionRequest(
            id: displayID,
            turnID: envelope.turnID,
            providerConnectionGeneration: generation,
            providerRequestID: providerRequestID,
            prompt: prompt,
            kind: QuestionKind(rawValue: payload["kind"]?.stringValue ?? "")
                ?? fields.first?.kind
                ?? .freeText,
            options: options.isEmpty ? (fields.first?.options ?? []) : options,
            allowsOther: payload["allowsOther"]?.boolValue
                ?? fields.first?.allowsOther
                ?? false,
            status: .pending,
            occurredAt: envelope.occurredAt,
            fields: fields.isEmpty ? nil : fields
        )
        replaceOrAppend(request, in: &state.questions)
        state.connectionState = .awaitingApproval
        state.turnState = .awaitingApproval
    }

    private func questionFields(from payload: JSONValue) -> [QuestionField] {
        (payload["questions"]?.arrayValue ?? []).enumerated().compactMap {
            index,
            value -> QuestionField? in
            guard let prompt = value["prompt"]?.stringValue
                ?? value["question"]?.stringValue
                ?? value["header"]?.stringValue else {
                return nil
            }
            let options = (value["options"]?.arrayValue ?? []).enumerated().compactMap {
                optionIndex,
                optionValue -> QuestionOption? in
                if let rawValue = optionValue.stringValue {
                    return QuestionOption(id: rawValue, label: rawValue)
                }
                guard let label = optionValue["label"]?.stringValue
                    ?? optionValue["value"]?.stringValue else {
                    return nil
                }
                return QuestionOption(
                    id: optionValue["id"]?.stringValue
                        ?? optionValue["value"]?.stringValue
                        ?? "option-\(optionIndex + 1)",
                    label: label,
                    detail: optionValue["detail"]?.stringValue
                        ?? optionValue["description"]?.stringValue
                )
            }
            let kind = QuestionKind(rawValue: value["kind"]?.stringValue ?? "")
                ?? (value["isSecret"]?.boolValue == true
                    ? .secret
                    : value["allowsMultiple"]?.boolValue == true
                        || value["multiSelect"]?.boolValue == true
                        ? .multipleChoice
                        : options.isEmpty ? .freeText : .singleChoice)
            return QuestionField(
                id: value["id"]?.stringValue
                    ?? value["questionId"]?.stringValue
                    ?? "question-\(index + 1)",
                prompt: prompt,
                kind: kind,
                options: options,
                allowsOther: value["allowsOther"]?.boolValue ?? false
            )
        }
    }

    private func resolveQuestion(_ envelope: ChatEnvelope, expired: Bool, in state: inout ConversationState) {
        guard let id = envelope.payload["displayId"]?.stringValue ?? envelope.itemID,
              let index = state.questions.firstIndex(where: { $0.id == id }) else {
            return
        }
        state.questions[index].status = expired ? .expired : .answered
        restoreStreamingStateIfNoPendingInteraction(in: &state)
    }

    private func applyPlan(_ envelope: ChatEnvelope, to state: inout ConversationState) throws {
        let itemID = resolvedItemID(envelope) ?? "plan:\(envelope.turnID ?? "current")"
        let steps = (envelope.payload["steps"]?.arrayValue ?? []).enumerated().compactMap {
            index,
            value -> ChatPlanStep? in
            guard let title = value["title"]?.stringValue ?? value["text"]?.stringValue else { return nil }
            return ChatPlanStep(
                id: value["id"]?.stringValue ?? "\(itemID):\(index)",
                title: title,
                isCompleted: value["completed"]?.boolValue
                    ?? (value["status"]?.stringValue == "completed")
            )
        }
        replaceOrAppend(
            .plan(
                ChatPlan(
                    id: itemID,
                    turnID: envelope.turnID,
                    title: envelope.payload["title"]?.stringValue,
                    steps: steps,
                    occurredAt: envelope.occurredAt
                )
            ),
            in: &state
        )
    }

    private func applyUnknown(_ envelope: ChatEnvelope, to state: inout ConversationState) {
        let itemID = resolvedItemID(envelope) ?? envelope.eventID ?? envelope.id
        replaceOrAppend(
            .generic(
                ChatGenericItem(
                    id: itemID,
                    turnID: envelope.turnID,
                    type: envelope.type,
                    title: envelope.payload["title"]?.stringValue ?? "Agent update",
                    detail: envelope.payload["summary"]?.displayString,
                    occurredAt: envelope.occurredAt
                )
            ),
            in: &state
        )
    }

    private func restoreStreamingStateIfNoPendingInteraction(in state: inout ConversationState) {
        guard state.pendingApprovals.isEmpty, state.pendingQuestions.isEmpty else { return }
        state.connectionState = .streaming
        if state.activeTurnID != nil {
            state.turnState = .running
        }
    }

    private func terminalTurnID(from envelope: ChatEnvelope, fallback: String?) -> String? {
        envelope.turnID ?? envelope.payload["turnId"]?.stringValue ?? fallback
    }

    private func finishTurnItems(
        turnID: String?,
        toolStatus: ToolActivityStatus,
        in state: inout ConversationState
    ) {
        guard let turnID, !turnID.isEmpty else { return }

        for index in state.items.indices {
            switch state.items[index] {
            case .message(var message)
                where message.turnID == turnID && message.isStreaming:
                message.complete(text: nil)
                state.items[index] = .message(message)
            case .reasoning(var reasoning)
                where reasoning.turnID == turnID && reasoning.isStreaming:
                reasoning.isStreaming = false
                state.items[index] = .reasoning(reasoning)
            case .tool(var tool)
                where tool.turnID == turnID
                    && (tool.status == .pending || tool.status == .running):
                tool.status = toolStatus
                state.items[index] = .tool(tool)
            default:
                break
            }
        }

        for index in state.approvals.indices
        where state.approvals[index].turnID == turnID
            && state.approvals[index].status == .pending {
            state.approvals[index].status = .expired
        }
        for index in state.questions.indices
        where state.questions[index].turnID == turnID
            && state.questions[index].status == .pending {
            state.questions[index].status = .expired
        }
    }

    private func snapshotToolStatus(for turnState: TurnState) -> ToolActivityStatus {
        switch turnState {
        case .completed:
            .completed
        case .failed:
            .failed
        case .idle, .interrupted, .stopped, .unknown:
            .cancelled
        case .running, .awaitingApproval:
            .running
        }
    }

    private func finishInactiveSnapshotItems(
        toolStatus: ToolActivityStatus,
        in state: inout ConversationState
    ) {
        for index in state.items.indices {
            switch state.items[index] {
            case .message(var message) where message.isStreaming:
                message.complete(text: nil)
                state.items[index] = .message(message)
            case .reasoning(var reasoning) where reasoning.isStreaming:
                reasoning.isStreaming = false
                state.items[index] = .reasoning(reasoning)
            case .tool(var tool)
                where tool.status == .pending || tool.status == .running:
                tool.status = toolStatus
                state.items[index] = .tool(tool)
            default:
                break
            }
        }
    }

    private func resolvedItemID(_ envelope: ChatEnvelope) -> String? {
        envelope.itemID
            ?? envelope.payload["itemId"]?.stringValue
            ?? envelope.payload["id"]?.stringValue
    }

    private func replaceOrAppend(_ item: ConversationItem, in state: inout ConversationState) {
        if let index = state.items.lastIndex(where: { $0.id == item.id }) {
            state.items[index] = item
        } else {
            state.items.append(item)
        }
    }

    private func replaceOrAppend<T: Identifiable>(_ item: T, in values: inout [T]) where T.ID: Equatable {
        if let index = values.firstIndex(where: { $0.id == item.id }) {
            values[index] = item
        } else {
            values.append(item)
        }
    }

    private func stableDeduplicated<T: Identifiable>(_ values: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        return values.filter { seen.insert($0.id).inserted }
    }

    func enforceMemoryBounds(
        on state: inout ConversationState,
        retainedContentBytes: inout Int
    ) {
        var removed = false
        if state.items.count > maximumRetainedItems {
            let removalCount = state.items.count - maximumRetainedItems
            retainedContentBytes -= state.items.prefix(removalCount).reduce(0) {
                $0 + $1.approximateContentByteCount
            }
            state.items.removeFirst(removalCount)
            removed = true
        }

        while state.items.count > 1,
              retainedContentBytes > maximumRetainedContentBytes {
            retainedContentBytes -= state.items.removeFirst().approximateContentByteCount
            removed = true
        }
        retainedContentBytes = max(0, retainedContentBytes)

        if removed {
            state.didTruncateHistory = true
            state.hasOlderHistory = true
            state.oldestItemID = state.items.first?.id
        }
    }
}

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var state: ConversationState
    @Published var draft = ""
    @Published var attachments: [ChatAttachmentReference] = []
    @Published private(set) var expandedItemIDs: Set<String> = []
    @Published private(set) var expandedCodeBlockIDs: Set<String> = []
    @Published private(set) var copiedItemID: String?
    @Published private(set) var pendingDestructiveApprovalConfirmation:
        DestructiveApprovalConfirmation?
    @Published private(set) var respondingInteractionIDs: Set<String> = []
    @Published private(set) var selectedQuestionOptions: [String: Set<String>] = [:]
    @Published private(set) var questionText: [String: String] = [:]
    @Published private(set) var unreadCount = 0
    @Published private(set) var isNearBottom = true
    @Published private(set) var isLoadingOlderHistory = false

    private var workingState: ConversationState
    private let reducer: ConversationReducer
    private let streamingPublishNanoseconds: UInt64
    private var streamingPublishTask: Task<Void, Never>?
    private var retainedContentBytes: Int

    init(
        state: ConversationState = ConversationState(),
        reducer: ConversationReducer = ConversationReducer(),
        streamingPublishNanoseconds: UInt64 = 33_000_000
    ) {
        self.state = state
        workingState = state
        self.reducer = reducer
        self.streamingPublishNanoseconds = streamingPublishNanoseconds
        retainedContentBytes = state.items.reduce(0) {
            $0 + $1.approximateContentByteCount
        }
    }

    deinit {
        streamingPublishTask?.cancel()
    }

    var lastAppliedSequence: Int64 { workingState.lastAppliedSequence }
    var snapshotGeneration: String? { workingState.snapshotGeneration }

    func apply(_ envelope: ChatEnvelope) throws {
        let previousItemCount = workingState.items.count
        let changedItemID = changedItemID(for: envelope)
        let changedItemIndex = changedItemID.flatMap { id in
            workingState.items.firstIndex(where: { $0.id == id })
        }
        let previousChangedItemBytes = changedItemIndex.map {
            workingState.items[$0].approximateContentByteCount
        } ?? 0
        try reducer.reduce(envelope, into: &workingState)
        let requiresFullByteRecount =
            envelope.type == ChatEventKind.conversationSnapshot.rawValue
            || envelope.type == ChatEventKind.historyPage.rawValue
            || envelope.payload["clientUserMessageId"]?.stringValue != nil
            || workingState.items.count != previousItemCount
        if requiresFullByteRecount {
            recountRetainedContentBytes()
        } else if let changedItemID,
                  let changedItemIndex,
                  workingState.items.indices.contains(changedItemIndex),
                  workingState.items[changedItemIndex].id == changedItemID {
            retainedContentBytes +=
                workingState.items[changedItemIndex].approximateContentByteCount
                    - previousChangedItemBytes
        }
        reducer.enforceMemoryBounds(
            on: &workingState,
            retainedContentBytes: &retainedContentBytes
        )
        if envelope.type == ChatEventKind.conversationSnapshot.rawValue {
            resetReconnectTransients()
        }
        clearStaleDestructiveApprovalConfirmation()

        let isStreamingDelta = envelope.type == ChatEventKind.messageDelta.rawValue
            || envelope.type == ChatEventKind.reasoningDelta.rawValue
            || envelope.type == ChatEventKind.toolUpdated.rawValue

        if isStreamingDelta {
            if !isNearBottom, workingState.items.count > previousItemCount {
                unreadCount += workingState.items.count - previousItemCount
            }
            scheduleStreamingPublish()
        } else {
            publishImmediately()
            if !isNearBottom, workingState.items.count > previousItemCount {
                unreadCount += workingState.items.count - previousItemCount
            }
        }
    }

    func replaceWithSnapshot(_ snapshot: ConversationSnapshot) {
        let reconciledTurn = reconciledSnapshotTurn(
            turnState: snapshot.turnState,
            activeTurnID: snapshot.activeTurnID,
            items: snapshot.items
        )
        workingState = ConversationState(
            snapshotGeneration: snapshot.snapshotGeneration,
            lastAppliedSequence: snapshot.baseSequence,
            items: snapshot.items,
            approvals: snapshot.approvals,
            questions: snapshot.questions,
            connectionState: snapshot.connectionState,
            turnState: reconciledTurn.state,
            activeTurnID: reconciledTurn.activeTurnID,
            capabilities: snapshot.capabilities,
            usage: snapshot.usage,
            hasOlderHistory: snapshot.hasOlderHistory,
            oldestItemID: snapshot.oldestItemID
        )
        recountRetainedContentBytes()
        reducer.enforceMemoryBounds(
            on: &workingState,
            retainedContentBytes: &retainedContentBytes
        )
        resetReconnectTransients()
        clearStaleDestructiveApprovalConfirmation()
        publishImmediately()
    }

    func addOptimisticUserMessage(requestID: String, text: String) {
        let message = ChatMessage(
            id: "client:\(requestID)",
            role: .user,
            text: text,
            occurredAt: Int64(Date().timeIntervalSince1970 * 1_000),
            isOptimistic: true
        )
        let item = ConversationItem.message(message)
        workingState.items.append(item)
        retainedContentBytes += item.approximateContentByteCount
        reducer.enforceMemoryBounds(
            on: &workingState,
            retainedContentBytes: &retainedContentBytes
        )
        publishImmediately()
    }

    func removeOptimisticUserMessage(requestID: String) {
        retainedContentBytes -= workingState.items.reduce(0) { result, item in
            guard case .message(let message) = item,
                  message.id == "client:\(requestID)" else {
                return result
            }
            return result + item.approximateContentByteCount
        }
        workingState.items.removeAll { item in
            guard case .message(let message) = item else { return false }
            return message.id == "client:\(requestID)"
        }
        retainedContentBytes = max(0, retainedContentBytes)
        publishImmediately()
    }

    func flushStreamingUpdates() {
        publishImmediately()
    }

    func setConnectionState(_ connectionState: ChatConnectionState, message: String? = nil) {
        workingState.connectionState = connectionState
        if let message {
            workingState.lastErrorMessage = message
        } else if connectionState == .connecting {
            workingState.lastErrorMessage = nil
        }
        publishImmediately()
    }

    func clearLastError() {
        workingState.lastErrorMessage = nil
        publishImmediately()
    }

    func dismissFilePreview() {
        workingState.filePreview = nil
        publishImmediately()
    }

    func beginLoadingOlderHistory() {
        isLoadingOlderHistory = true
    }

    func endLoadingOlderHistory() {
        isLoadingOlderHistory = false
    }

    func resetReconnectTransients() {
        pendingDestructiveApprovalConfirmation = nil
        respondingInteractionIDs.removeAll()
        isLoadingOlderHistory = false
    }

    func setNearBottom(_ value: Bool) {
        isNearBottom = value
        if value {
            unreadCount = 0
        }
    }

    func jumpToLatest() {
        isNearBottom = true
        unreadCount = 0
    }

    func toggleExpanded(itemID: String) {
        if expandedItemIDs.contains(itemID) {
            expandedItemIDs.remove(itemID)
        } else {
            expandedItemIDs.insert(itemID)
        }
    }

    func toggleCodeBlock(itemID: String) {
        if expandedCodeBlockIDs.contains(itemID) {
            expandedCodeBlockIDs.remove(itemID)
        } else {
            expandedCodeBlockIDs.insert(itemID)
        }
    }

    func markCopied(itemID: String?) {
        copiedItemID = itemID
    }

    func requestDestructiveApprovalConfirmation(
        approvalID: String,
        decisionID: String
    ) {
        pendingDestructiveApprovalConfirmation = DestructiveApprovalConfirmation(
            approvalID: approvalID,
            decisionID: decisionID
        )
    }

    func clearDestructiveApprovalConfirmation(approvalID: String? = nil) {
        if let approvalID,
           pendingDestructiveApprovalConfirmation?.approvalID != approvalID {
            return
        }
        pendingDestructiveApprovalConfirmation = nil
    }

    func setInteractionResponding(_ id: String, isResponding: Bool) {
        if isResponding {
            respondingInteractionIDs.insert(id)
        } else {
            respondingInteractionIDs.remove(id)
        }
    }

    func toggleQuestionOption(questionID: String, optionID: String, allowsMultiple: Bool) {
        if allowsMultiple {
            var values = selectedQuestionOptions[questionID, default: []]
            if values.contains(optionID) {
                values.remove(optionID)
            } else {
                values.insert(optionID)
            }
            selectedQuestionOptions[questionID] = values
        } else {
            selectedQuestionOptions[questionID] = [optionID]
        }
    }

    func updateQuestionText(questionID: String, text: String) {
        let suppressDraftPersistence = state.questions.contains { request in
            request.resolvedFields.contains { field in
                request.draftKey(for: field) == questionID && field.kind == .secret
            }
        } || state.questions.first(where: { $0.id == questionID })?.kind == .secret
        guard !suppressDraftPersistence else {
            return
        }
        questionText[questionID] = text
    }

    func clearQuestionDraft(questionID: String) {
        selectedQuestionOptions.removeValue(forKey: questionID)
        questionText.removeValue(forKey: questionID)
        let prefix = "\(questionID):"
        selectedQuestionOptions = selectedQuestionOptions.filter {
            !$0.key.hasPrefix(prefix)
        }
        questionText = questionText.filter {
            !$0.key.hasPrefix(prefix)
        }
    }

    func removeAttachment(id: String) {
        attachments.removeAll { $0.id == id }
    }

    func clearComposer() {
        draft = ""
        attachments.removeAll()
    }

    func restoreFailedSubmission(
        text: String,
        attachments failedAttachments: [ChatAttachmentReference]
    ) {
        if draft.isEmpty {
            draft = text
        } else if !text.isEmpty, draft != text {
            draft = "\(text)\n\n\(draft)"
        }

        let existingAttachmentIDs = Set(attachments.map(\.id))
        attachments.insert(
            contentsOf: failedAttachments.filter {
                !existingAttachmentIDs.contains($0.id)
            },
            at: 0
        )
    }

    private func clearStaleDestructiveApprovalConfirmation() {
        guard let confirmation = pendingDestructiveApprovalConfirmation else {
            return
        }
        let remainsConfirmable = workingState.approvals.contains { approval in
            approval.id == confirmation.approvalID
                && approval.status == .pending
                && approval.decisions.contains { decision in
                    decision.id == confirmation.decisionID && decision.isDestructive
                }
        }
        if !remainsConfirmable {
            pendingDestructiveApprovalConfirmation = nil
        }
    }

    private func changedItemID(for envelope: ChatEnvelope) -> String? {
        if let itemID = envelope.itemID
            ?? envelope.payload["itemId"]?.stringValue
            ?? envelope.payload["id"]?.stringValue {
            return itemID
        }
        guard ChatEventKind(rawValue: envelope.type) == nil else { return nil }
        return envelope.eventID ?? envelope.id
    }

    private func recountRetainedContentBytes() {
        retainedContentBytes = workingState.items.reduce(0) {
            $0 + $1.approximateContentByteCount
        }
    }

    private func scheduleStreamingPublish() {
        guard streamingPublishTask == nil else { return }
        streamingPublishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: streamingPublishNanoseconds)
            guard !Task.isCancelled else { return }
            publishImmediately()
        }
    }

    private func publishImmediately() {
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        guard workingState != state else { return }
        state = workingState
    }
}

private extension JSONValue {
    func decoded<T: Decodable>() throws -> T {
        try JSONDecoder.chat.decode(T.self, from: JSONEncoder.chat.encode(self))
    }

    var displayString: String? {
        switch self {
        case .null:
            nil
        case .string(let value):
            value
        case .bool(let value):
            value ? "true" : "false"
        case .number(let value):
            value.rounded() == value ? String(Int64(value)) : String(value)
        case .array, .object:
            String(data: try! JSONEncoder.chat.encode(self), encoding: .utf8)
        }
    }

    var isNonNull: Bool {
        if case .null = self { return false }
        return true
    }
}

private extension ConversationItem {
    var approximateContentByteCount: Int {
        switch self {
        case .message(let value):
            value.contents.reduce(0) { $0 + $1.text.utf8.count }
        case .reasoning(let value):
            value.text.utf8.count
        case .tool(let value):
            (value.input?.utf8.count ?? 0)
                + (value.output?.utf8.count ?? 0)
                + (value.errorMessage?.utf8.count ?? 0)
        case .diff(let value):
            value.unifiedDiff.utf8.count
        case .plan(let value):
            value.steps.reduce(0) { $0 + $1.title.utf8.count }
        case .generic(let value):
            value.title.utf8.count + (value.detail?.utf8.count ?? 0)
        }
    }
}
