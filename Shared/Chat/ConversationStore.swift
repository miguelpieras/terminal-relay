import Combine
import Foundation

struct ConversationState: Codable, Equatable, Sendable {
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

struct TranscriptRowInsertion: Equatable, Sendable {
    let id: String
    let index: Int
}

struct TranscriptMutation: Equatable, Sendable {
    var revision: UInt64 = 0
    var isAuthoritativeReset = false
    var insertions: [TranscriptRowInsertion] = []
    var prependedIDs: [String] = []
    var removedIDs: [String] = []
    var changedIDs: [String] = []

    static let empty = TranscriptMutation()
}

struct TranscriptProjectionDiagnostics: Equatable, Sendable {
    fileprivate(set) var fullItemBuilds = 0
    fileprivate(set) var boundedFirstRowBuilds = 0
    fileprivate(set) var incrementalTailBuilds = 0
    fileprivate(set) var totalIncrementalSourceBytes = 0
    fileprivate(set) var lastIncrementalSourceBytes = 0
    fileprivate(set) var maximumIncrementalSourceBytes = 0
    fileprivate(set) var lastFirstRowSourceBytes = 0
    fileprivate(set) var maximumFirstRowSourceBytes = 0
    fileprivate(set) var preparedCompletionAdoptions = 0
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

private func snapshotToolStatus(_ turnState: TurnState) -> ToolActivityStatus {
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

private func finalizedInactiveSnapshotItem(
    _ item: ConversationItem,
    toolStatus: ToolActivityStatus
) -> ConversationItem {
    switch item {
    case .message(var message) where message.isStreaming:
        message.complete(text: nil)
        return .message(message)
    case .reasoning(var reasoning) where reasoning.isStreaming:
        reasoning.isStreaming = false
        return .reasoning(reasoning)
    case .tool(var tool)
        where tool.status == .pending || tool.status == .running:
        tool.status = toolStatus
        return .tool(tool)
    default:
        return item
    }
}

/// Mirrors the reducer's authoritative transcript mutations so the final
/// bounded rows can be built off the main actor before the item is published.
/// Ordinary deltas continue through the store's incremental tail projection
/// path; compatibility `tool.updated` records qualify only when they carry a
/// cumulative `output` replacement.
private func completedTranscriptItem(
    for envelope: ChatEnvelope,
    currentItems: [ConversationItem]
) -> ConversationItem? {
    guard let itemID = envelope.itemID
        ?? envelope.payload["itemId"]?.stringValue
        ?? envelope.payload["id"]?.stringValue else {
        return nil
    }
    let currentItem = currentItems.first { $0.id == itemID }

    switch ChatEventKind(rawValue: envelope.type) {
    case .messageCompleted:
        let text = envelope.payload["text"]?.stringValue
            ?? envelope.payload["content"]?.stringValue
            ?? ""
        let role = ChatMessageRole(
            rawValue: envelope.payload["role"]?.stringValue ?? "assistant"
        ) ?? .assistant
        var message: ChatMessage
        if case .message(let current)? = currentItem {
            message = current
            message.turnID = envelope.turnID ?? message.turnID
            message.occurredAt = message.occurredAt ?? envelope.occurredAt
            message.complete(
                text: text.isEmpty
                    && envelope.payload["text"] == nil
                    && envelope.payload["content"] == nil
                    ? nil
                    : text,
                isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                originalByteCount: envelope.payload["originalByteCount"]?.intValue
            )
        } else {
            message = ChatMessage(
                id: itemID,
                turnID: envelope.turnID,
                role: role,
                text: text,
                occurredAt: envelope.occurredAt,
                isStreaming: false
            )
            message.complete(
                text: text,
                isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                originalByteCount: envelope.payload["originalByteCount"]?.intValue
            )
        }
        return .message(message)

    case .reasoningCompleted:
        let text = envelope.payload["text"]?.stringValue ?? ""
        if case .reasoning(var reasoning)? = currentItem {
            if !text.isEmpty { reasoning.text = text }
            reasoning.isStreaming = false
            return .reasoning(reasoning)
        }
        return .reasoning(
            ChatReasoning(
                id: itemID,
                turnID: envelope.turnID,
                text: text,
                isStreaming: false,
                occurredAt: envelope.occurredAt
            )
        )

    case .toolUpdated, .toolCompleted:
        let status: ToolActivityStatus = {
            if let raw = envelope.payload["status"]?.stringValue,
               let parsed = ToolActivityStatus(rawValue: raw) {
                return parsed
            }
            if ChatEventKind(rawValue: envelope.type) == .toolCompleted {
                return envelope.payload["error"]?.isNonNull == true
                    ? .failed
                    : .completed
            }
            return .running
        }()
        let kind = ToolActivityKind(
            rawValue: envelope.payload["kind"]?.stringValue ?? ""
        ) ?? .generic
        let title = envelope.payload["title"]?.stringValue
            ?? envelope.payload["name"]?.stringValue
            ?? "Agent activity"
        if case .tool(var tool)? = currentItem {
            tool.title = title
            tool.status = status
            tool.input = envelope.payload["input"]?.displayString ?? tool.input
            if let output = envelope.payload["output"]?.displayString {
                tool.output = output
            } else if let outputDelta = envelope.payload["outputDelta"]?.displayString {
                tool.appendOutput(outputDelta)
            }
            tool.errorMessage = envelope.payload["error"]?.displayString ?? tool.errorMessage
            tool.durationMilliseconds = envelope.payload["durationMs"]?.int64Value
                ?? tool.durationMilliseconds
            tool.exitCode = envelope.payload["exitCode"]?.intValue ?? tool.exitCode
            tool.isTruncated = envelope.payload["truncated"]?.boolValue ?? tool.isTruncated
            tool.originalByteCount = envelope.payload["originalByteCount"]?.intValue
                ?? tool.originalByteCount
            return .tool(tool)
        }
        return .tool(
            ToolActivity(
                id: itemID,
                turnID: envelope.turnID,
                kind: kind,
                title: title,
                status: status,
                input: envelope.payload["input"]?.displayString,
                output: envelope.payload["output"]?.displayString
                    ?? envelope.payload["outputDelta"]?.displayString,
                errorMessage: envelope.payload["error"]?.displayString,
                durationMilliseconds: envelope.payload["durationMs"]?.int64Value,
                exitCode: envelope.payload["exitCode"]?.intValue,
                occurredAt: envelope.occurredAt,
                isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                originalByteCount: envelope.payload["originalByteCount"]?.intValue
            )
        )

    default:
        return nil
    }
}

/// Returns the single mutable content ID when a completion only seals an
/// otherwise identical streaming message. That case must stay on the bounded
/// tail-update path; preparing/replacing every row would trade the main-thread
/// build hitch for an equally avoidable full-section diff.
private func tailOnlyMessageCompletionContentID(
    previous: ChatMessage,
    updated: ChatMessage
) -> String? {
    guard previous.isStreaming,
          previous.contents.count == 1,
          updated.contents.count == 1,
          let previousContent = previous.contents.first,
          let updatedContent = updated.contents.first,
          previousContent.id == updatedContent.id,
          previousContent.kind == updatedContent.kind,
          previousContent.sharesTextStorage(with: updatedContent),
          previousContent.language == updatedContent.language else {
        return nil
    }

    var normalizedUpdated = updated
    normalizedUpdated.contents = previous.contents
    normalizedUpdated.isStreaming = previous.isStreaming
    normalizedUpdated.isOptimistic = previous.isOptimistic
    guard ConversationItem.message(normalizedUpdated)
        .hasExactTranscriptIdentity(as: .message(previous)) else { return nil }
    return previousContent.id
}

private func appendOnlyMessageProjectionContentID(
    envelope: ChatEnvelope,
    previous: ChatMessage,
    updated: ChatMessage
) -> String? {
    guard previous.isStreaming,
          previous.contents.count == updated.contents.count,
          let previousContent = previous.contents.last,
          let updatedContent = updated.contents.last else {
        return nil
    }
    let contentID = envelope.payload["contentId"]?.stringValue
        ?? previousContent.id
    guard previousContent.id == contentID,
          updatedContent.id == contentID,
          previous.contents.dropLast() == updated.contents.dropLast() else {
        return nil
    }

    guard updatedContent.kind == previousContent.kind,
          updatedContent.language == previousContent.language,
          updatedContent.isTruncated == previousContent.isTruncated,
          updatedContent.originalByteCount == previousContent.originalByteCount else {
        return nil
    }

    var normalizedUpdated = updated
    normalizedUpdated.contents = previous.contents
    normalizedUpdated.isStreaming = previous.isStreaming
    return ConversationItem.message(normalizedUpdated)
        .hasExactTranscriptIdentity(as: .message(previous)) ? contentID : nil
}

private func appendOnlyReasoningProjection(
    previous: ChatReasoning,
    updated: ChatReasoning
) -> Bool {
    chatStringsHaveIdenticalUTF8(previous.id, updated.id)
        && chatStringsHaveIdenticalUTF8(previous.turnID, updated.turnID)
        && previous.occurredAt == updated.occurredAt
        && updated.isStreaming
}

private func appendOnlyToolOutputProjection(
    previous: ToolActivity,
    updated: ToolActivity
) -> Bool {
    guard previous.outputUTF8Count > 0,
          previous.errorMessage?.isEmpty != false else {
        return false
    }
    return chatStringsHaveIdenticalUTF8(previous.id, updated.id)
        && chatStringsHaveIdenticalUTF8(previous.turnID, updated.turnID)
        && previous.kind == updated.kind
        && chatStringsHaveIdenticalUTF8(previous.title, updated.title)
        && previous.status == updated.status
        && chatStringsHaveIdenticalUTF8(previous.input, updated.input)
        && chatStringsHaveIdenticalUTF8(
            previous.errorMessage,
            updated.errorMessage
        )
        && previous.durationMilliseconds == updated.durationMilliseconds
        && previous.exitCode == updated.exitCode
        && previous.occurredAt == updated.occurredAt
        && previous.isTruncated == updated.isTruncated
        && previous.originalByteCount == updated.originalByteCount
}

struct ConversationReducer {
    let maximumRetainedItems: Int
    let maximumRetainedContentBytes: Int

    init(maximumRetainedItems: Int = 1_000, maximumRetainedContentBytes: Int = 8 * 1_048_576) {
        self.maximumRetainedItems = maximumRetainedItems
        self.maximumRetainedContentBytes = maximumRetainedContentBytes
    }

    func reduce(
        _ envelope: ChatEnvelope,
        into state: inout ConversationState,
        itemIndex: inout [String: Int],
        preparedPayload: PreparedConversationReducerPayload? = nil
    ) throws -> Bool {
        let kind = ChatEventKind(rawValue: envelope.type)

        if kind == .conversationSnapshot {
            try applySnapshot(
                envelope,
                preparedPayload: preparedPayload,
                to: &state
            )
            rebuildItemIndex(for: state, into: &itemIndex)
            return true
        }

        // Reject failed detached authoritative preparation before mutating the
        // durable sequence/generation cursor. Reducer errors must leave the
        // working state retryable from the same event.
        if case .invalid = preparedPayload {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }

        // `session.hello` and a pre-attach `error` are attachment-local control
        // records with seq 0. They must be applied without advancing or
        // participating in the durable replay cursor.
        if let sequence = envelope.sequence, sequence > 0 {
            if sequence <= state.lastAppliedSequence {
                return false
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
                return true
            }
            applyUnknown(envelope, to: &state, itemIndex: &itemIndex)
            return true
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
                rebuildItemIndex(for: state, into: &itemIndex)
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
            try applyHistoryPage(
                envelope,
                preparedPayload: preparedPayload,
                to: &state
            )
            rebuildItemIndex(for: state, into: &itemIndex)
        case .messageStarted, .messageDelta, .messageCompleted:
            try applyMessage(
                envelope,
                kind: kind,
                preparedPayload: preparedPayload,
                to: &state,
                itemIndex: &itemIndex
            )
        case .reasoningStarted, .reasoningDelta, .reasoningCompleted:
            try applyReasoning(
                envelope,
                kind: kind,
                preparedPayload: preparedPayload,
                to: &state,
                itemIndex: &itemIndex
            )
        case .toolStarted, .toolUpdated, .toolCompleted:
            try applyTool(
                envelope,
                kind: kind,
                preparedPayload: preparedPayload,
                to: &state,
                itemIndex: &itemIndex
            )
        case .fileChangeUpdated, .diffUpdated:
            try applyDiff(envelope, to: &state, itemIndex: &itemIndex)
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
            try applyPlan(envelope, to: &state, itemIndex: &itemIndex)
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

        return true
    }

    private func applySnapshot(
        _ envelope: ChatEnvelope,
        preparedPayload: PreparedConversationReducerPayload?,
        to state: inout ConversationState
    ) throws {
        let snapshot: ConversationSnapshot
        if case .conversationSnapshot(let preparedSnapshot) = preparedPayload {
            snapshot = preparedSnapshot
        } else if case .invalid = preparedPayload {
            throw ConversationReducerError.invalidEvent(envelope.type)
        } else {
            do {
                snapshot = try envelope.decodePayload(ConversationSnapshot.self)
            } catch {
                throw ConversationReducerError.invalidEvent(envelope.type)
            }
        }
        // The worker admits attaches before its provider has resumed and
        // answers with an empty "connecting" placeholder snapshot. Adopt its
        // generation and cursor, but keep already-painted (cache-hydrated)
        // content: the rebuilt snapshot replaces it once history ingest
        // completes, and blanking here would flash the transcript empty.
        if snapshot.connectionState == .connecting,
           snapshot.items.isEmpty,
           snapshot.approvals.isEmpty,
           snapshot.questions.isEmpty,
           !state.items.isEmpty {
            state.snapshotGeneration = snapshot.snapshotGeneration
            state.lastAppliedSequence = snapshot.baseSequence
            state.connectionState = snapshot.connectionState
            state.capabilities = snapshot.capabilities
            state.lastErrorMessage = nil
            return
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

    private func applyHistoryPage(
        _ envelope: ChatEnvelope,
        preparedPayload: PreparedConversationReducerPayload?,
        to state: inout ConversationState
    ) throws {
        let items: [ConversationItem]
        if case .historyPage(let preparedItems) = preparedPayload {
            items = preparedItems
        } else if case .invalid = preparedPayload {
            throw ConversationReducerError.invalidEvent(envelope.type)
        } else {
            let values = envelope.payload["items"]?.arrayValue ?? []
            items = try values.map { value -> ConversationItem in
                do {
                    return try value.decoded()
                } catch {
                    throw ConversationReducerError.invalidEvent(envelope.type)
                }
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
        preparedPayload: PreparedConversationReducerPayload?,
        to state: inout ConversationState,
        itemIndex: inout [String: Int]
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
            rebuildItemIndex(for: state, into: &itemIndex)
        }

        // Detached preparation has already applied and compared the complete
        // authoritative text. Adopt that exact item so the main actor never
        // walks a megabyte-scale streamed value a second time at completion.
        if kind == .messageCompleted,
           case .completedItem(.message(let preparedMessage)) = preparedPayload,
           preparedMessage.id == itemID {
            if let index = itemIndex[itemID], state.items.indices.contains(index) {
                state.items[index] = .message(preparedMessage)
            } else {
                state.items.append(.message(preparedMessage))
                itemIndex[itemID] = state.items.count - 1
            }
            return
        }

        if let index = itemIndex[itemID],
           case .message(var message) = state.items[index] {
            message.turnID = envelope.turnID ?? message.turnID
            // A delta's timestamp describes the transport event, not a new
            // message. Keep the start timestamp stable so sealed projection
            // rows do not all acquire a new visual revision on every token.
            message.occurredAt = message.occurredAt ?? envelope.occurredAt
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
                if !text.isEmpty, !message.hasText {
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
        itemIndex[itemID] = state.items.count - 1
    }

    private func applyReasoning(
        _ envelope: ChatEnvelope,
        kind: ChatEventKind,
        preparedPayload: PreparedConversationReducerPayload?,
        to state: inout ConversationState,
        itemIndex: inout [String: Int]
    ) throws {
        guard let itemID = resolvedItemID(envelope) else {
            throw ConversationReducerError.invalidEvent(envelope.type)
        }
        let text = envelope.payload["text"]?.stringValue ?? ""

        if kind == .reasoningCompleted,
           case .completedItem(.reasoning(let preparedReasoning)) = preparedPayload,
           preparedReasoning.id == itemID {
            if let index = itemIndex[itemID], state.items.indices.contains(index) {
                state.items[index] = .reasoning(preparedReasoning)
            } else {
                state.items.append(.reasoning(preparedReasoning))
                itemIndex[itemID] = state.items.count - 1
            }
            return
        }

        if let index = itemIndex[itemID],
           case .reasoning(var reasoning) = state.items[index] {
            if kind == .reasoningCompleted {
                if !text.isEmpty { reasoning.text = text }
                reasoning.isStreaming = false
            } else if kind == .reasoningDelta {
                reasoning.appendText(text)
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
            itemIndex[itemID] = state.items.count - 1
        }
    }

    private func applyTool(
        _ envelope: ChatEnvelope,
        kind: ChatEventKind,
        preparedPayload: PreparedConversationReducerPayload?,
        to state: inout ConversationState,
        itemIndex: inout [String: Int]
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

        let hasAuthoritativeOutput = envelope.payload["output"]?.isNonNull == true
        if (kind == .toolCompleted || (kind == .toolUpdated && hasAuthoritativeOutput)),
           case .completedItem(.tool(let preparedTool)) = preparedPayload,
           preparedTool.id == itemID {
            if let index = itemIndex[itemID], state.items.indices.contains(index) {
                state.items[index] = .tool(preparedTool)
            } else {
                state.items.append(.tool(preparedTool))
                itemIndex[itemID] = state.items.count - 1
            }
            return
        }

        if let index = itemIndex[itemID],
           case .tool(var tool) = state.items[index] {
            tool.title = title
            tool.status = status
            tool.input = envelope.payload["input"]?.displayString ?? tool.input
            if let output = envelope.payload["output"]?.displayString {
                tool.output = output
            } else if let outputDelta = envelope.payload["outputDelta"]?.displayString {
                tool.appendOutput(outputDelta)
            }
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
                        output: envelope.payload["output"]?.displayString
                            ?? envelope.payload["outputDelta"]?.displayString,
                        errorMessage: envelope.payload["error"]?.displayString,
                        durationMilliseconds: envelope.payload["durationMs"]?.int64Value,
                        exitCode: envelope.payload["exitCode"]?.intValue,
                        occurredAt: envelope.occurredAt,
                        isTruncated: envelope.payload["truncated"]?.boolValue ?? false,
                        originalByteCount: envelope.payload["originalByteCount"]?.intValue
                    )
                )
            )
            itemIndex[itemID] = state.items.count - 1
        }
    }

    private func applyDiff(
        _ envelope: ChatEnvelope,
        to state: inout ConversationState,
        itemIndex: inout [String: Int]
    ) throws {
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
        replaceOrAppend(.diff(diff), in: &state, itemIndex: &itemIndex)
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

    private func applyPlan(
        _ envelope: ChatEnvelope,
        to state: inout ConversationState,
        itemIndex: inout [String: Int]
    ) throws {
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
            in: &state,
            itemIndex: &itemIndex
        )
    }

    private func applyUnknown(
        _ envelope: ChatEnvelope,
        to state: inout ConversationState,
        itemIndex: inout [String: Int]
    ) {
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
            in: &state,
            itemIndex: &itemIndex
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

    private func replaceOrAppend(
        _ item: ConversationItem,
        in state: inout ConversationState,
        itemIndex: inout [String: Int]
    ) {
        if let index = itemIndex[item.id] {
            state.items[index] = item
        } else {
            state.items.append(item)
            itemIndex[item.id] = state.items.count - 1
        }
    }

    private func rebuildItemIndex(
        for state: ConversationState,
        into itemIndex: inout [String: Int]
    ) {
        itemIndex.removeAll(keepingCapacity: true)
        itemIndex.reserveCapacity(state.items.count)
        for (index, item) in state.items.enumerated() {
            itemIndex[item.id] = index
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
        retainedContentBytes: inout Int,
        itemIndex: inout [String: Int]
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
            rebuildItemIndex(for: state, into: &itemIndex)
            state.didTruncateHistory = true
            state.hasOlderHistory = true
            state.oldestItemID = state.items.first?.id
        }
    }
}

struct PreparedTranscriptProjection: Sendable {
    let item: ConversationItem
    let rows: [TranscriptRowProjection]
}

typealias PreparedTranscriptProjectionBatch = [String: PreparedTranscriptProjection]

/// Typed authoritative payload decoded before the main-actor store applies an
/// event. Snapshot/history JSON can contain the entire retained transcript, so
/// re-encoding and decoding it inside `ConversationReducer.reduce` would still
/// interrupt an active scroll even when transcript publication is frozen.
enum PreparedConversationReducerPayload: Sendable {
    case conversationSnapshot(ConversationSnapshot)
    case historyPage([ConversationItem])
    case completedItem(ConversationItem)
    case invalid

    func preservesPaintedTranscript(previousItemCount: Int) -> Bool {
        guard previousItemCount > 0,
              case .conversationSnapshot(let snapshot) = self else {
            return false
        }
        return snapshot.connectionState == .connecting
            && snapshot.items.isEmpty
            && snapshot.approvals.isEmpty
            && snapshot.questions.isEmpty
    }
}

struct PreparedConversationApplication: Sendable {
    let transcriptProjections: PreparedTranscriptProjectionBatch
    let reducerPayload: PreparedConversationReducerPayload?
    let markdownWarmTexts: [String]
    let preservedSnapshotItemIDs: Set<String>
}

@MainActor
final class ConversationStore: ObservableObject {
    private struct ProjectionCacheEntry {
        var itemRevision: UInt64
        var rows: [TranscriptRowProjection]
    }

    private struct FirstProjectionCacheEntry {
        var itemRevision: UInt64
        var row: TranscriptRowProjection
    }

    private enum ProjectionAppendTarget: Equatable {
        case message(contentID: String)
        case reasoning
        case toolOutput
    }

    private enum PendingProjectionChange {
        case append(target: ProjectionAppendTarget, chunks: [String])
        case rebuild
    }

    private struct TerminalTranscriptChanges {
        var itemIDs: Set<String> = []
        var interactionRowIDs: Set<String> = []

        var rowIDs: Set<String> { itemIDs.union(interactionRowIDs) }
        var isEmpty: Bool { itemIDs.isEmpty && interactionRowIDs.isEmpty }
    }

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
    private(set) var transcriptMutation = TranscriptMutation.empty
    private(set) var projectionDiagnostics = TranscriptProjectionDiagnostics()

    /// Changes only when the hosted transcript's rows can change. Durable
    /// control traffic still advances `lastAppliedSequence`, but acknowledgements,
    /// heartbeats, and connection-state records must not make the macOS host
    /// synchronously remeasure every visible row.
    private(set) var transcriptContentRevision: UInt64 = 0

    private var workingState: ConversationState
    private var workingItemIndexByID: [String: Int] = [:]
    private let reducer: ConversationReducer
    private let streamingPublishNanoseconds: UInt64
    private var streamingPublishTask: Task<Void, Never>?
    private var isTranscriptLiveScrolling = false
    private var hasDeferredImmediatePublication = false
    private var retainedContentBytes: Int
    private var nextItemContentRevision: UInt64 = 1
    private var itemContentRevisions: [String: UInt64] = [:]
    private var publishedItemContentRevisions: [String: UInt64] = [:]
    private var projectionCache: [String: ProjectionCacheEntry] = [:]
    private var firstProjectionCache: [String: FirstProjectionCacheEntry] = [:]
    private var pendingProjectionChanges: [String: PendingProjectionChange] = [:]
    private var pendingPreparedTranscriptProjections:
        PreparedTranscriptProjectionBatch = [:]
    private var hasPendingStatePublication = false
    private var pendingTranscriptReset = false
    private var pendingTranscriptInsertions: [String: Int] = [:]
    private var pendingTranscriptPrepends: Set<String> = []
    private var pendingTranscriptRemovals: Set<String> = []
    private var pendingTranscriptChanges: Set<String> = []

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
        rebuildWorkingItemIndex()
        resetItemContentRevisions(for: state.items)
        publishedItemContentRevisions = itemContentRevisions
    }

    deinit {
        streamingPublishTask?.cancel()
    }

    var lastAppliedSequence: Int64 { workingState.lastAppliedSequence }
    var snapshotGeneration: String? { workingState.snapshotGeneration }
    var itemsForTranscriptProjectionPreparation: [ConversationItem] {
        workingState.items
    }
    var stateForTranscriptProjectionPreparation: ConversationState {
        workingState
    }
    var stateForCachePersistence: ConversationState {
        workingState
    }
    var hasActiveWorkingTurn: Bool {
        workingState.turnState.isActive
    }

    func transcriptProjectionPreparationItem(
        for envelope: ChatEnvelope
    ) -> ConversationItem? {
        guard let itemID = changedItemID(for: envelope),
              let index = workingItemIndexByID[itemID],
              workingState.items.indices.contains(index) else {
            return nil
        }
        return workingState.items[index]
    }

    func stagedTranscriptProjection(
        for envelope: ChatEnvelope
    ) -> PreparedTranscriptProjection? {
        guard let itemID = changedItemID(for: envelope) else { return nil }
        return pendingPreparedTranscriptProjections[itemID]
    }

    /// Lightweight revision used by the macOS transcript's section cache.
    /// It lets the view reuse every unchanged item's projected row array
    /// instead of flattening the complete retained transcript on each update.
    func transcriptItemContentRevision(for itemID: String) -> UInt64 {
        publishedItemContentRevisions[itemID] ?? 0
    }

    @discardableResult
    func apply(
        _ envelope: ChatEnvelope,
        preparedTranscriptProjections: PreparedTranscriptProjectionBatch = [:],
        preparedReducerPayload: PreparedConversationReducerPayload? = nil,
        preservedSnapshotItemIDs: Set<String> = []
    ) throws -> Bool {
        let previousItemCount = workingState.items.count
        let preservesPaintedTranscript = preparedReducerPayload?
            .preservesPaintedTranscript(
                previousItemCount: previousItemCount
            ) == true
        let terminalTranscriptChanges = Self.terminalTranscriptChanges(
            for: envelope,
            in: workingState
        )
        let changedItemID = changedItemID(for: envelope)
        let changedItemIndex = changedItemID.flatMap { id in
            workingItemIndexByID[id]
        }
        let previousChangedItem = changedItemIndex.map {
            workingState.items[$0]
        }
        let previousChangedItemBytes = changedItemIndex.map {
            workingState.items[$0].approximateContentByteCount
        } ?? 0
        let didApply = try TranscriptPerformance.measureStoreApply {
            try reducer.reduce(
                envelope,
                into: &workingState,
                itemIndex: &workingItemIndexByID,
                preparedPayload: preparedReducerPayload
            )
        }
        guard didApply else { return false }
        let adoptedPreparedTranscriptItem: Bool
        switch (ChatEventKind(rawValue: envelope.type), preparedReducerPayload) {
        case (.messageCompleted, .completedItem(.message(let item))):
            adoptedPreparedTranscriptItem = item.id == changedItemID
        case (.reasoningCompleted, .completedItem(.reasoning(let item))):
            adoptedPreparedTranscriptItem = item.id == changedItemID
        case (.toolCompleted, .completedItem(.tool(let item))):
            adoptedPreparedTranscriptItem = item.id == changedItemID
        case (.toolUpdated, .completedItem(.tool(let item))):
            adoptedPreparedTranscriptItem = envelope.payload["output"]?.isNonNull == true
                && item.id == changedItemID
        default:
            adoptedPreparedTranscriptItem = false
        }
        if adoptedPreparedTranscriptItem {
            projectionDiagnostics.preparedCompletionAdoptions += 1
        }
        if (envelope.sequence ?? 0) > 0
            || ChatEventKind(rawValue: envelope.type) != .sessionHeartbeat {
            hasPendingStatePublication = true
        }
        let isTerminalTurnEvent = Self.isTerminalTurnEvent(envelope)
        if !preservesPaintedTranscript,
           Self.affectsTranscriptContent(envelope),
           !isTerminalTurnEvent || !terminalTranscriptChanges.isEmpty {
            transcriptContentRevision &+= 1
        }
        let requiresFullByteRecount =
            envelope.type == ChatEventKind.conversationSnapshot.rawValue
            || envelope.type == ChatEventKind.historyPage.rawValue
            || envelope.payload["clientUserMessageId"]?.stringValue != nil
            || workingState.items.count != previousItemCount
        if requiresFullByteRecount && !preservesPaintedTranscript {
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
            retainedContentBytes: &retainedContentBytes,
            itemIndex: &workingItemIndexByID
        )
        recordTranscriptMutation(
            for: envelope,
            changedItemID: changedItemID,
            changedItemWasPresent: changedItemIndex != nil,
            previousItemCount: previousItemCount,
            terminalTranscriptChanges: terminalTranscriptChanges,
            preservesPaintedTranscript: preservesPaintedTranscript
        )
        synchronizeItemContentRevisions(
            after: envelope,
            changedItemID: changedItemID,
            previousItemCount: previousItemCount,
            terminalTranscriptChanges: terminalTranscriptChanges,
            preparedReducerPayload: preparedReducerPayload,
            preservedSnapshotItemIDs: preservedSnapshotItemIDs,
            preservesPaintedTranscript: preservesPaintedTranscript
        )
        recordProjectionChange(
            for: envelope,
            itemID: changedItemID,
            previousItem: previousChangedItem
        )
        stagePreparedTranscriptProjections(preparedTranscriptProjections)
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
            if isNearBottom, !isTranscriptLiveScrolling {
                scheduleStreamingPublish()
            }
        } else {
            publishImmediately()
            if !isNearBottom, workingState.items.count > previousItemCount {
                unreadCount += workingState.items.count - previousItemCount
            }
        }
        return true
    }

    nonisolated static func prepareTranscriptProjections(
        for items: [ConversationItem]
    ) async -> PreparedTranscriptProjectionBatch {
        let task = Task.detached(priority: .userInitiated) {
            var prepared: PreparedTranscriptProjectionBatch = [:]
            prepared.reserveCapacity(items.count)
            for item in items {
                guard !Task.isCancelled else { break }
                prepared[item.id] = PreparedTranscriptProjection(
                    item: item,
                    rows: TranscriptRowProjection.makeRows(item: item)
                )
            }
            return prepared
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Converts only transcript-sized authoritative payloads to typed values on
    /// a detached executor. Ordinary deltas already expose their small fields
    /// directly and do not need this extra preparation step.
    nonisolated static func prepareAuthoritativeReducerPayload(
        for envelope: ChatEnvelope,
        retaining currentItem: ConversationItem? = nil
    ) async -> PreparedConversationReducerPayload? {
        let kind = ChatEventKind(rawValue: envelope.type)
        let isCumulativeToolUpdate = kind == .toolUpdated
            && envelope.payload["output"]?.isNonNull == true
        guard kind == .conversationSnapshot
                || kind == .historyPage
                || kind == .messageCompleted
                || kind == .reasoningCompleted
                || kind == .toolCompleted
                || isCumulativeToolUpdate else {
            return nil
        }
        let task = Task.detached(priority: .userInitiated) {
            () -> PreparedConversationReducerPayload in
            switch kind {
            case .conversationSnapshot:
                guard let snapshot = try? envelope.decodePayload(
                    ConversationSnapshot.self
                ) else {
                    return .invalid
                }
                return .conversationSnapshot(snapshot)

            case .historyPage:
                let values = envelope.payload["items"]?.arrayValue ?? []
                var items: [ConversationItem] = []
                items.reserveCapacity(values.count)
                for value in values {
                    guard !Task.isCancelled,
                          let item: ConversationItem = try? value.decoded() else {
                        return .invalid
                    }
                    items.append(item)
                }
                return .historyPage(items)

            case .messageCompleted, .reasoningCompleted,
                 .toolCompleted, .toolUpdated:
                guard let item = completedTranscriptItem(
                    for: envelope,
                    currentItems: currentItem.map { [$0] } ?? []
                ) else {
                    return .invalid
                }
                return .completedItem(item)

            default:
                return .invalid
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated static func prepareMarkdownWarmTexts(
        for payload: PreparedConversationReducerPayload?
    ) async -> [String] {
        guard case .conversationSnapshot(let snapshot) = payload else {
            return []
        }
        let task = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return [String]() }
            return Array(
                SanitizedMarkdownCache.warmableTexts(
                    items: snapshot.items,
                    suffixLimit: 50
                ).reversed()
            )
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Computes authoritative snapshot cache reuse on a detached executor.
    /// Exact item equality can touch arbitrarily large nested content, so the
    /// main actor receives only the IDs proven unchanged.
    nonisolated static func preparePreservedSnapshotItemIDs(
        for payload: PreparedConversationReducerPayload?,
        retaining currentItems: [ConversationItem]
    ) async -> Set<String> {
        guard case .conversationSnapshot(let snapshot) = payload,
              !currentItems.isEmpty else {
            return []
        }
        let task = Task.detached(priority: .userInitiated) {
            () -> Set<String> in
            guard !Task.isCancelled else { return [] }
            if payload?.preservesPaintedTranscript(
                previousItemCount: currentItems.count
            ) == true {
                return Set(currentItems.map(\.id))
            }
            var previousByID: [String: ConversationItem] = [:]
            previousByID.reserveCapacity(currentItems.count)
            for item in currentItems where previousByID[item.id] == nil {
                previousByID[item.id] = item
            }
            var preserved: Set<String> = []
            let normalizedItems = normalizedSnapshotItems(snapshot)
            preserved.reserveCapacity(normalizedItems.count)
            for item in normalizedItems {
                guard !Task.isCancelled else { return [] }
                if previousByID[item.id]?.hasExactTranscriptIdentity(as: item) == true {
                    preserved.insert(item.id)
                }
            }
            return preserved
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated private static func normalizedSnapshotItems(
        _ snapshot: ConversationSnapshot
    ) -> [ConversationItem] {
        var seen: Set<String> = []
        var normalized = snapshot.items.filter {
            seen.insert($0.id).inserted
        }
        let reconciled = reconciledSnapshotTurn(
            turnState: snapshot.turnState,
            activeTurnID: snapshot.activeTurnID,
            items: normalized
        )
        if reconciled.activeTurnID == nil,
           !reconciled.state.isActive {
            let toolStatus = snapshotToolStatus(reconciled.state)
            normalized = normalized.map {
                finalizedInactiveSnapshotItem(
                    $0,
                    toolStatus: toolStatus
                )
            }
        }
        return normalized
    }

    /// Decodes and projects an authoritative snapshot/history page entirely
    /// before the store mutates. Adoption is then one synchronous main-actor
    /// transaction: the old published transcript and its cache remain intact
    /// while this work runs, and the new state cannot publish before its rows
    /// are installed.
    nonisolated static func prepareTranscriptProjections(
        for envelope: ChatEnvelope,
        retaining currentItems: [ConversationItem] = [],
        currentState: ConversationState? = nil,
        currentItem: ConversationItem? = nil,
        stagedProjection: PreparedTranscriptProjection? = nil,
        preparedReducerPayload: PreparedConversationReducerPayload? = nil,
        preservingSnapshotItemIDs: Set<String> = []
    ) async -> PreparedTranscriptProjectionBatch {
        let task = Task.detached(priority: .userInitiated) {
            () -> PreparedTranscriptProjectionBatch in
            let retainedItems = currentState?.items ?? currentItems
            let itemID = envelope.itemID
                ?? envelope.payload["itemId"]?.stringValue
                ?? envelope.payload["messageId"]?.stringValue
                ?? envelope.payload["toolId"]?.stringValue
                ?? envelope.payload["id"]?.stringValue
            let retainedItem = currentItem ?? itemID.flatMap { targetID in
                retainedItems.first { $0.id == targetID }
            }

            func simulatedChangedItems() -> [ConversationItem] {
                guard var simulatedState = currentState else { return [] }
                var itemIndex: [String: Int] = [:]
                itemIndex.reserveCapacity(simulatedState.items.count)
                var previousByID: [String: ConversationItem] = [:]
                previousByID.reserveCapacity(simulatedState.items.count)
                for (index, item) in simulatedState.items.enumerated() {
                    itemIndex[item.id] = index
                    previousByID[item.id] = item
                }
                let reducer = ConversationReducer()
                guard (try? reducer.reduce(
                    envelope,
                    into: &simulatedState,
                    itemIndex: &itemIndex
                )) == true else {
                    return []
                }
                var retainedBytes = simulatedState.items.reduce(0) {
                    $0 + $1.approximateContentByteCount
                }
                reducer.enforceMemoryBounds(
                    on: &simulatedState,
                    retainedContentBytes: &retainedBytes,
                    itemIndex: &itemIndex
                )
                return simulatedState.items.filter {
                    previousByID[$0.id]?.hasExactTranscriptIdentity(as: $0) != true
                }
            }

            func simulatedTargetItem() -> ConversationItem? {
                guard let itemID else { return nil }
                if case .completedItem(let preparedItem) = preparedReducerPayload,
                   preparedItem.id == itemID {
                    return preparedItem
                }
                var simulatedState = ConversationState()
                if let retainedItem {
                    simulatedState.items = [retainedItem]
                }
                var itemIndex: [String: Int] = retainedItem == nil
                    ? [:]
                    : [itemID: 0]
                let unsequencedEnvelope = ChatEnvelope(
                    v: envelope.v,
                    type: envelope.type,
                    requestID: envelope.requestID,
                    eventID: envelope.eventID,
                    relayID: envelope.relayID,
                    provider: envelope.provider,
                    providerThreadID: envelope.providerThreadID,
                    snapshotGeneration: envelope.snapshotGeneration,
                    sequence: nil,
                    sentAt: envelope.sentAt,
                    occurredAt: envelope.occurredAt,
                    turnID: envelope.turnID,
                    itemID: envelope.itemID,
                    payload: envelope.payload
                )
                let reducer = ConversationReducer()
                guard (try? reducer.reduce(
                    unsequencedEnvelope,
                    into: &simulatedState,
                    itemIndex: &itemIndex
                )) == true,
                      let index = itemIndex[itemID],
                      simulatedState.items.indices.contains(index) else {
                    return nil
                }
                return simulatedState.items[index]
            }

            func isPureIncrementalAppend(
                kind: ChatEventKind,
                updated: ConversationItem
            ) -> Bool {
                guard let previous = retainedItem else {
                    return false
                }
                switch (kind, previous, updated) {
                case (.messageDelta, .message(let before), .message(let after)):
                    return appendOnlyMessageProjectionContentID(
                        envelope: envelope,
                        previous: before,
                        updated: after
                    ) != nil
                case (.reasoningDelta, .reasoning(let before), .reasoning(let after)):
                    return before.isStreaming
                        && appendOnlyReasoningProjection(
                            previous: before,
                            updated: after
                        )
                case (.toolUpdated, .tool(let before), .tool(let after)):
                    return envelope.payload["output"]?.isNonNull != true
                        && envelope.payload["outputDelta"]?.displayString != nil
                        && appendOnlyToolOutputProjection(
                            previous: before,
                            updated: after
                        )
                default:
                    return false
                }
            }

            func incrementallyPreparedProjection(
                kind: ChatEventKind,
                updated: ConversationItem
            ) -> PreparedTranscriptProjection? {
                guard let retainedItem,
                      let stagedProjection,
                      stagedProjection.item.hasExactTranscriptIdentity(
                        as: retainedItem
                      ) else {
                    return nil
                }
                let append: TranscriptProjectionTailAppend
                switch (kind, retainedItem, updated) {
                case (.messageDelta, .message(let previous), .message(let next)):
                    guard let contentID = appendOnlyMessageProjectionContentID(
                        envelope: envelope,
                        previous: previous,
                        updated: next
                    ) else { return nil }
                    append = .message(
                        contentID: contentID,
                        text: envelope.payload["text"]?.stringValue
                            ?? envelope.payload["content"]?.stringValue
                            ?? ""
                    )
                case (.reasoningDelta, .reasoning, .reasoning):
                    append = .reasoning(
                        text: envelope.payload["text"]?.stringValue ?? ""
                    )
                case (.toolUpdated, .tool, .tool):
                    guard envelope.payload["output"]?.isNonNull != true,
                          let outputDelta = envelope.payload["outputDelta"]?.displayString else {
                        return nil
                    }
                    append = .toolOutput(text: outputDelta)
                case (.messageCompleted, .message(let previous), .message(let next)):
                    guard let contentID = tailOnlyMessageCompletionContentID(
                        previous: previous,
                        updated: next
                    ) else { return nil }
                    append = .message(contentID: contentID, text: "")
                default:
                    return nil
                }
                guard let result = TranscriptRowProjection.appendingToTail(
                    append,
                    item: updated,
                    previousRows: stagedProjection.rows
                ) else {
                    return nil
                }
                return PreparedTranscriptProjection(
                    item: updated,
                    rows: result.rows
                )
            }

            let items: [ConversationItem]
            let envelopeKind = ChatEventKind(rawValue: envelope.type)
            switch envelopeKind {
            case .conversationSnapshot:
                let snapshot: ConversationSnapshot
                if case .conversationSnapshot(let preparedSnapshot) = preparedReducerPayload {
                    snapshot = preparedSnapshot
                } else if case .invalid = preparedReducerPayload {
                    return [:]
                } else {
                    guard let decoded = try? envelope.decodePayload(
                        ConversationSnapshot.self
                    ) else {
                        return [:]
                    }
                    snapshot = decoded
                }
                if snapshot.connectionState == .connecting,
                   snapshot.items.isEmpty,
                   snapshot.approvals.isEmpty,
                   snapshot.questions.isEmpty,
                   !retainedItems.isEmpty {
                    return [:]
                } else {
                    items = normalizedSnapshotItems(snapshot).filter {
                        !preservingSnapshotItemIDs.contains($0.id)
                    }
                }
            case .historyPage:
                let retainedIDs = Set(retainedItems.map(\.id))
                let decodedItems: [ConversationItem]
                if case .historyPage(let preparedItems) = preparedReducerPayload {
                    decodedItems = preparedItems
                } else if case .invalid = preparedReducerPayload {
                    return [:]
                } else {
                    decodedItems = (envelope.payload["items"]?.arrayValue ?? [])
                        .compactMap { try? $0.decoded() }
                }
                items = decodedItems.filter { !retainedIDs.contains($0.id) }
            case .messageStarted, .reasoningStarted, .toolStarted,
                 .fileChangeUpdated, .diffUpdated, .planUpdated,
                 .messageCompleted, .reasoningCompleted, .toolCompleted:
                guard let updated = simulatedTargetItem() else {
                    return [:]
                }
                if envelopeKind == .messageCompleted,
                   case .message(let previous)? = retainedItem,
                   case .message(let completed) = updated,
                   tailOnlyMessageCompletionContentID(
                    previous: previous,
                    updated: completed
                   ) != nil {
                    if let prepared = incrementallyPreparedProjection(
                        kind: .messageCompleted,
                        updated: updated
                    ) {
                        return [updated.id: prepared]
                    }
                    items = []
                } else {
                    items = [updated]
                }
            case .turnCompleted, .turnFailed, .turnInterrupted:
                items = simulatedChangedItems()
            case .messageDelta, .reasoningDelta, .toolUpdated:
                guard let kind = ChatEventKind(rawValue: envelope.type),
                      let updated = simulatedTargetItem() else {
                    return [:]
                }
                if isPureIncrementalAppend(kind: kind, updated: updated) {
                    if let prepared = incrementallyPreparedProjection(
                        kind: kind,
                        updated: updated
                    ) {
                        return [updated.id: prepared]
                    }
                    return [:]
                }
                items = [updated]
            default:
                items = []
            }
            guard !Task.isCancelled else { return [:] }
            var prepared: PreparedTranscriptProjectionBatch = [:]
            prepared.reserveCapacity(items.count)
            for item in items {
                guard !Task.isCancelled else { break }
                guard prepared[item.id] == nil else { continue }
                prepared[item.id] = PreparedTranscriptProjection(
                    item: item,
                    rows: TranscriptRowProjection.makeRows(item: item)
                )
            }
            return prepared
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func stagePreparedTranscriptProjections(
        _ prepared: PreparedTranscriptProjectionBatch
    ) {
        for (itemID, value) in prepared {
            guard let itemIndex = workingItemIndexByID[itemID],
                  workingState.items.indices.contains(itemIndex),
                  workingState.items[itemIndex] == value.item else {
                continue
            }
            pendingPreparedTranscriptProjections[itemID] = value
            pendingProjectionChanges.removeValue(forKey: itemID)
        }
    }

    private func adoptPreparedTranscriptProjectionsForPublication() {
        let prepared = pendingPreparedTranscriptProjections
        pendingPreparedTranscriptProjections.removeAll(keepingCapacity: true)
        for (itemID, value) in prepared {
            guard let itemIndex = workingItemIndexByID[itemID],
                  workingState.items.indices.contains(itemIndex),
                  workingState.items[itemIndex] == value.item,
                  let revision = itemContentRevisions[itemID] else {
                continue
            }
            projectionCache[itemID] = ProjectionCacheEntry(
                itemRevision: revision,
                rows: value.rows
            )
            firstProjectionCache.removeValue(forKey: itemID)
            pendingProjectionChanges.removeValue(forKey: itemID)
        }
    }

    /// Adopts a cached state as the pre-connection baseline so the transcript
    /// paints instantly from disk. Only valid before any live envelope has
    /// applied; the attach cursor then resumes from the cached sequence and
    /// the worker replays just the delta (or a fresh snapshot when its
    /// generation changed).
    func hydrateFromCache(
        _ cached: ConversationState,
        preparedProjections: PreparedTranscriptProjectionBatch = [:]
    ) {
        guard workingState.lastAppliedSequence == 0,
              workingState.items.isEmpty else {
            return
        }
        var state = cached
        state.connectionState = .connecting
        state.lastErrorMessage = nil
        state.filePreview = nil
        // Interactive prompts and turn activity are only meaningful live: a
        // cached pending approval would render actionable buttons wired to a
        // dead worker generation. The attach replay restores any that are
        // genuinely still pending.
        state.approvals.removeAll { $0.status == .pending }
        state.questions.removeAll { $0.status == .pending }
        state.turnState = .idle
        state.activeTurnID = nil
        workingState = state
        rebuildWorkingItemIndex()
        recountRetainedContentBytes()
        reducer.enforceMemoryBounds(
            on: &workingState,
            retainedContentBytes: &retainedContentBytes,
            itemIndex: &workingItemIndexByID
        )
        clearStaleDestructiveApprovalConfirmation()
        transcriptContentRevision &+= 1
        resetItemContentRevisions(for: workingState.items)
        stagePreparedTranscriptProjections(preparedProjections)
        pendingTranscriptReset = true
        hasPendingStatePublication = true
        publishImmediately()
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
        rebuildWorkingItemIndex()
        recountRetainedContentBytes()
        reducer.enforceMemoryBounds(
            on: &workingState,
            retainedContentBytes: &retainedContentBytes,
            itemIndex: &workingItemIndexByID
        )
        resetReconnectTransients()
        clearStaleDestructiveApprovalConfirmation()
        transcriptContentRevision &+= 1
        resetItemContentRevisions(for: workingState.items)
        pendingTranscriptReset = true
        hasPendingStatePublication = true
        publishImmediately()
    }

    nonisolated static func optimisticUserMessage(
        requestID: String,
        text: String,
        occurredAt: Int64
    ) -> ConversationItem {
        let message = ChatMessage(
            id: "client:\(requestID)",
            role: .user,
            text: text,
            occurredAt: occurredAt,
            isOptimistic: true
        )
        return .message(message)
    }

    func addOptimisticUserMessage(
        _ item: ConversationItem,
        preparedTranscriptProjections: PreparedTranscriptProjectionBatch
    ) {
        guard case .message(let message) = item,
              message.isOptimistic,
              workingItemIndexByID[item.id] == nil else {
            return
        }
        workingState.items.append(item)
        workingItemIndexByID[item.id] = workingState.items.count - 1
        retainedContentBytes += item.approximateContentByteCount
        reducer.enforceMemoryBounds(
            on: &workingState,
            retainedContentBytes: &retainedContentBytes,
            itemIndex: &workingItemIndexByID
        )
        transcriptContentRevision &+= 1
        markItemContentChanged(message.id)
        pendingTranscriptInsertions[message.id] = max(0, workingState.items.count - 1)
        stagePreparedTranscriptProjections(preparedTranscriptProjections)
        hasPendingStatePublication = true
        publishImmediately()
    }

    func removeOptimisticUserMessage(requestID: String) {
        let previousItemCount = workingState.items.count
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
        rebuildWorkingItemIndex()
        retainedContentBytes = max(0, retainedContentBytes)
        if workingState.items.count != previousItemCount {
            transcriptContentRevision &+= 1
            itemContentRevisions.removeValue(forKey: "client:\(requestID)")
            projectionCache.removeValue(forKey: "client:\(requestID)")
            firstProjectionCache.removeValue(forKey: "client:\(requestID)")
            pendingTranscriptRemovals.insert("client:\(requestID)")
        }
        hasPendingStatePublication = true
        publishImmediately()
    }

    func flushStreamingUpdates() {
        publishImmediately(allowDuringLiveScroll: true)
    }

    func setConnectionState(_ connectionState: ChatConnectionState, message: String? = nil) {
        workingState.connectionState = connectionState
        if let message {
            workingState.lastErrorMessage = message
        } else if connectionState == .connecting {
            workingState.lastErrorMessage = nil
        }
        hasPendingStatePublication = true
        publishImmediately()
    }

    func clearLastError() {
        workingState.lastErrorMessage = nil
        hasPendingStatePublication = true
        publishImmediately()
    }

    func dismissFilePreview() {
        workingState.filePreview = nil
        hasPendingStatePublication = true
        publishImmediately()
    }

    func transcriptProjections(for item: ConversationItem) -> [TranscriptRowProjection] {
        let itemRevision = publishedItemContentRevisions[item.id] ?? 0
        if let cached = projectionCache[item.id],
           cached.itemRevision == itemRevision {
            return cached.rows
        }
        let projections = TranscriptPerformance.measureProjection {
            TranscriptRowProjection.makeRows(item: item)
        }
        projectionDiagnostics.fullItemBuilds += 1
        projectionCache[item.id] = ProjectionCacheEntry(
            itemRevision: itemRevision,
            rows: projections
        )
        firstProjectionCache.removeValue(forKey: item.id)
        return projections
    }

    /// Projects only the first bounded tile for collapsed disclosure rows.
    /// Expansion should call `transcriptProjections(for:)`, which replaces
    /// this lightweight cache entry with the complete inline row set.
    func transcriptFirstProjection(
        for item: ConversationItem
    ) -> TranscriptRowProjection? {
        let itemRevision = publishedItemContentRevisions[item.id] ?? 0
        if let cached = projectionCache[item.id],
           cached.itemRevision == itemRevision {
            return cached.rows.first
        }
        if let cached = firstProjectionCache[item.id],
           cached.itemRevision == itemRevision {
            return cached.row
        }
        guard let result = TranscriptPerformance.measureProjection({
            TranscriptRowProjection.makeFirstRow(item: item)
        }) else {
            return transcriptProjections(for: item).first
        }
        firstProjectionCache[item.id] = FirstProjectionCacheEntry(
            itemRevision: itemRevision,
            row: result.row
        )
        recordFirstProjection(bytes: result.projectedSourceBytes)
        return result.row
    }

    func copyRetainedMessage(itemID: String, fallback: String) {
        guard let index = workingItemIndexByID[itemID],
              workingState.items.indices.contains(index),
              case .message(let message) = workingState.items[index] else {
            ChatClipboard.copy(fallback)
            return
        }
        ChatClipboard.copy(message.text)
    }

    func copyRetainedToolSection(identifier: String, fallback: String) {
        let part: KeyPath<ToolActivity, String?>
        let suffix: String
        if identifier.hasSuffix(":input") {
            part = \.input
            suffix = ":input"
        } else if identifier.hasSuffix(":output") {
            part = \.output
            suffix = ":output"
        } else {
            ChatClipboard.copy(fallback)
            return
        }
        let itemID = String(identifier.dropLast(suffix.count))
        guard let index = workingItemIndexByID[itemID],
              workingState.items.indices.contains(index),
              case .tool(let tool) = workingState.items[index],
              let retained = tool[keyPath: part] else {
            ChatClipboard.copy(fallback)
            return
        }
        ChatClipboard.copy(retained)
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
        guard isNearBottom != value else { return }
        isNearBottom = value
        if value {
            unreadCount = 0
            if !isTranscriptLiveScrolling {
                publishImmediately()
            }
        } else {
            streamingPublishTask?.cancel()
            streamingPublishTask = nil
        }
    }

    /// The AppKit table owns the viewport while a live scroll gesture is in
    /// progress. Streaming records keep reducing into `workingState`, but the
    /// published transcript stays frozen so a gesture never triggers a full
    /// SwiftUI row projection/diff pass. Catch up once the gesture ends at the
    /// latest content; while browsing history, completion or an explicit jump
    /// remains the publication boundary.
    func setTranscriptLiveScrolling(_ value: Bool) {
        guard isTranscriptLiveScrolling != value else { return }
        isTranscriptLiveScrolling = value
        if value {
            streamingPublishTask?.cancel()
            streamingPublishTask = nil
        } else if isNearBottom || hasDeferredImmediatePublication {
            publishImmediately()
        }
    }

    func jumpToLatest() {
        isNearBottom = true
        unreadCount = 0
        publishImmediately()
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

    private static func affectsTranscriptContent(_ envelope: ChatEnvelope) -> Bool {
        guard let kind = ChatEventKind(rawValue: envelope.type) else {
            // Forward-compatible provider records render as generic timeline
            // items unless explicitly declared non-visual by the reducer.
            return true
        }
        switch kind {
        case .conversationSnapshot, .historyPage,
             .messageStarted, .messageDelta, .messageCompleted,
             .reasoningStarted, .reasoningDelta, .reasoningCompleted,
             .toolStarted, .toolUpdated, .toolCompleted,
             .fileChangeUpdated, .diffUpdated,
             .approvalRequested, .approvalResolved, .approvalExpired,
             .questionRequested, .questionResolved, .questionExpired,
             .planUpdated, .error,
             .turnCompleted, .turnFailed, .turnInterrupted:
            return true
        case .sessionHello, .sessionState, .sessionHeartbeat,
             .terminalFallbackRequired, .sessionEnded, .acknowledgement,
             .filePreview, .usageUpdated, .turnStarted:
            return false
        }
    }

    private static func isTerminalTurnEvent(_ envelope: ChatEnvelope) -> Bool {
        switch ChatEventKind(rawValue: envelope.type) {
        case .turnCompleted, .turnFailed, .turnInterrupted:
            true
        default:
            false
        }
    }

    /// Terminal turn records mutate only records that were still active when
    /// the terminal event arrived. Provider streams normally finalize each
    /// item first; in that common case the turn record must not evict and
    /// rebuild every already-sealed projection in the turn.
    private static func terminalTranscriptChanges(
        for envelope: ChatEnvelope,
        in state: ConversationState
    ) -> TerminalTranscriptChanges {
        guard isTerminalTurnEvent(envelope),
              let turnID = envelope.turnID
                ?? envelope.payload["turnId"]?.stringValue
                ?? state.activeTurnID,
              !turnID.isEmpty else {
            return TerminalTranscriptChanges()
        }
        var result = TerminalTranscriptChanges()
        for item in state.items {
            switch item {
            case .message(let message)
                where message.turnID == turnID && message.isStreaming:
                result.itemIDs.insert(item.id)
            case .reasoning(let reasoning)
                where reasoning.turnID == turnID && reasoning.isStreaming:
                result.itemIDs.insert(item.id)
            case .tool(let tool)
                where tool.turnID == turnID
                    && (tool.status == .pending || tool.status == .running):
                result.itemIDs.insert(item.id)
            default:
                break
            }
        }
        for approval in state.approvals
        where approval.turnID == turnID && approval.status == .pending {
            result.interactionRowIDs.insert("approval:\(approval.id)")
        }
        for question in state.questions
        where question.turnID == turnID && question.status == .pending {
            result.interactionRowIDs.insert("question:\(question.id)")
        }
        return result
    }

    private func recountRetainedContentBytes() {
        retainedContentBytes = workingState.items.reduce(0) {
            $0 + $1.approximateContentByteCount
        }
    }

    private func rebuildWorkingItemIndex() {
        workingItemIndexByID.removeAll(keepingCapacity: true)
        workingItemIndexByID.reserveCapacity(workingState.items.count)
        for (index, item) in workingState.items.enumerated() {
            workingItemIndexByID[item.id] = index
        }
    }

    private func resetItemContentRevisions(for items: [ConversationItem]) {
        var previousItems: [String: ConversationItem] = [:]
        previousItems.reserveCapacity(state.items.count)
        for item in state.items where previousItems[item.id] == nil {
            previousItems[item.id] = item
        }
        let previousRevisions = itemContentRevisions
        itemContentRevisions.removeAll(keepingCapacity: true)
        pendingProjectionChanges.removeAll(keepingCapacity: true)
        pendingPreparedTranscriptProjections.removeAll(keepingCapacity: true)
        var preservedIDs = Set<String>()
        preservedIDs.reserveCapacity(items.count)
        for item in items {
            if previousItems[item.id]?.hasExactTranscriptIdentity(as: item) == true,
               let revision = previousRevisions[item.id] {
                itemContentRevisions[item.id] = revision
                preservedIDs.insert(item.id)
            } else {
                itemContentRevisions[item.id] = nextItemContentRevision
                nextItemContentRevision &+= 1
            }
        }
        projectionCache = projectionCache.filter { preservedIDs.contains($0.key) }
        firstProjectionCache = firstProjectionCache.filter {
            preservedIDs.contains($0.key)
        }
    }

    /// Reuses only the item revisions proven unchanged by detached snapshot
    /// preparation. The main actor never compares authoritative transcript
    /// values, while unchanged sections keep their projected rows and wrapper
    /// arrays across reconnects.
    private func reconcilePreparedSnapshotItemContentRevisions(
        for items: [ConversationItem],
        preserving preparedPreservedIDs: Set<String>
    ) {
        let previousRevisions = itemContentRevisions
        itemContentRevisions.removeAll(keepingCapacity: true)
        itemContentRevisions.reserveCapacity(items.count)
        pendingProjectionChanges.removeAll(keepingCapacity: true)
        pendingPreparedTranscriptProjections.removeAll(keepingCapacity: true)
        var preservedIDs: Set<String> = []
        preservedIDs.reserveCapacity(preparedPreservedIDs.count)
        for item in items {
            if preparedPreservedIDs.contains(item.id),
               let revision = previousRevisions[item.id] {
                itemContentRevisions[item.id] = revision
                preservedIDs.insert(item.id)
            } else {
                itemContentRevisions[item.id] = nextItemContentRevision
                nextItemContentRevision &+= 1
            }
        }
        projectionCache = projectionCache.filter { preservedIDs.contains($0.key) }
        firstProjectionCache = firstProjectionCache.filter {
            preservedIDs.contains($0.key)
        }
    }

    private func markItemContentChanged(_ itemID: String) {
        itemContentRevisions[itemID] = nextItemContentRevision
        nextItemContentRevision &+= 1
    }

    private func synchronizeItemContentRevisions(
        after envelope: ChatEnvelope,
        changedItemID: String?,
        previousItemCount: Int,
        terminalTranscriptChanges: TerminalTranscriptChanges,
        preparedReducerPayload: PreparedConversationReducerPayload?,
        preservedSnapshotItemIDs: Set<String>,
        preservesPaintedTranscript: Bool
    ) {
        let kind = ChatEventKind(rawValue: envelope.type)
        if kind == .conversationSnapshot {
            if case .conversationSnapshot = preparedReducerPayload {
                if preservesPaintedTranscript {
                    return
                }
                reconcilePreparedSnapshotItemContentRevisions(
                    for: workingState.items,
                    preserving: preservedSnapshotItemIDs
                )
                return
            }
            resetItemContentRevisions(for: workingState.items)
            return
        }

        if kind == .historyPage || workingState.items.count != previousItemCount {
            let retainedIDs = Set(workingState.items.map(\.id))
            itemContentRevisions = itemContentRevisions.filter {
                retainedIDs.contains($0.key)
            }
            projectionCache = projectionCache.filter {
                retainedIDs.contains($0.key)
            }
            firstProjectionCache = firstProjectionCache.filter {
                retainedIDs.contains($0.key)
            }
            pendingProjectionChanges = pendingProjectionChanges.filter {
                retainedIDs.contains($0.key)
            }
            pendingPreparedTranscriptProjections =
                pendingPreparedTranscriptProjections.filter {
                    retainedIDs.contains($0.key)
                }
            for item in workingState.items where itemContentRevisions[item.id] == nil {
                markItemContentChanged(item.id)
            }
        }

        if let changedItemID,
           workingItemIndexByID[changedItemID] != nil {
            markItemContentChanged(changedItemID)
        }

        if kind == .turnCompleted || kind == .turnFailed || kind == .turnInterrupted {
            for itemID in terminalTranscriptChanges.itemIDs {
                guard let index = workingItemIndexByID[itemID],
                      workingState.items.indices.contains(index) else { continue }
                let item = workingState.items[index]
                markItemContentChanged(itemID)
                switch item {
                case .message(let message):
                    if let contentID = message.contents.last?.id {
                        queueProjectionAppend(
                            itemID: itemID,
                            target: .message(contentID: contentID),
                            text: ""
                        )
                    } else {
                        pendingProjectionChanges[itemID] = .rebuild
                    }
                case .reasoning:
                    queueProjectionAppend(
                        itemID: itemID,
                        target: .reasoning,
                        text: ""
                    )
                case .tool(let tool):
                    if tool.outputUTF8Count > 0 {
                        queueProjectionAppend(
                            itemID: itemID,
                            target: .toolOutput,
                            text: ""
                        )
                    } else {
                        pendingProjectionChanges[itemID] = .rebuild
                    }
                default:
                    pendingProjectionChanges[itemID] = .rebuild
                }
            }
        }
    }

    private func recordProjectionChange(
        for envelope: ChatEnvelope,
        itemID: String?,
        previousItem: ConversationItem?
    ) {
        guard let itemID,
              let previousItem,
              let index = workingItemIndexByID[itemID],
              workingState.items.indices.contains(index) else {
            if let itemID {
                pendingProjectionChanges[itemID] = .rebuild
            }
            return
        }
        let updatedItem = workingState.items[index]
        switch ChatEventKind(rawValue: envelope.type) {
        case .messageDelta:
            guard case .message(let previous) = previousItem,
                  case .message(let updated) = updatedItem,
                  let contentID = appendOnlyMessageContentID(
                    envelope: envelope,
                    previous: previous,
                    updated: updated
                  ) else {
                pendingProjectionChanges[itemID] = .rebuild
                return
            }
            let text = envelope.payload["text"]?.stringValue
                ?? envelope.payload["content"]?.stringValue
                ?? ""
            queueProjectionAppend(
                itemID: itemID,
                target: .message(contentID: contentID),
                text: text
            )

        case .messageCompleted:
            guard case .message(let previous) = previousItem,
                  case .message(let updated) = updatedItem,
                  let contentID = tailOnlyMessageCompletionContentID(
                    previous: previous,
                    updated: updated
                  ) else {
                pendingProjectionChanges[itemID] = .rebuild
                return
            }
            queueProjectionAppend(
                itemID: itemID,
                target: .message(contentID: contentID),
                text: ""
            )

        case .reasoningDelta:
            guard case .reasoning(let previous) = previousItem,
                  case .reasoning(let updated) = updatedItem,
                  previous.isStreaming,
                  appendOnlyReasoning(previous: previous, updated: updated) else {
                pendingProjectionChanges[itemID] = .rebuild
                return
            }
            queueProjectionAppend(
                itemID: itemID,
                target: .reasoning,
                text: envelope.payload["text"]?.stringValue ?? ""
            )

        case .toolUpdated:
            guard case .tool(let previous) = previousItem,
                  case .tool(let updated) = updatedItem,
                  envelope.payload["output"]?.isNonNull != true,
                  let outputDelta = envelope.payload["outputDelta"]?.displayString,
                  appendOnlyToolOutput(previous: previous, updated: updated) else {
                pendingProjectionChanges[itemID] = .rebuild
                return
            }
            queueProjectionAppend(
                itemID: itemID,
                target: .toolOutput,
                text: outputDelta
            )

        default:
            pendingProjectionChanges[itemID] = .rebuild
        }
    }

    private func appendOnlyMessageContentID(
        envelope: ChatEnvelope,
        previous: ChatMessage,
        updated: ChatMessage
    ) -> String? {
        appendOnlyMessageProjectionContentID(
            envelope: envelope,
            previous: previous,
            updated: updated
        )
    }

    private func appendOnlyReasoning(
        previous: ChatReasoning,
        updated: ChatReasoning
    ) -> Bool {
        appendOnlyReasoningProjection(previous: previous, updated: updated)
    }

    private func appendOnlyToolOutput(
        previous: ToolActivity,
        updated: ToolActivity
    ) -> Bool {
        appendOnlyToolOutputProjection(previous: previous, updated: updated)
    }

    private func queueProjectionAppend(
        itemID: String,
        target: ProjectionAppendTarget,
        text: String
    ) {
        switch pendingProjectionChanges[itemID] {
        case nil:
            pendingProjectionChanges[itemID] = .append(
                target: target,
                chunks: [text]
            )
        case .append(let existingTarget, var chunks) where existingTarget == target:
            chunks.append(text)
            pendingProjectionChanges[itemID] = .append(
                target: target,
                chunks: chunks
            )
        case .append, .rebuild:
            pendingProjectionChanges[itemID] = .rebuild
        }
    }

    private func applyPendingProjectionChanges() {
        for (itemID, change) in pendingProjectionChanges {
            switch change {
            case .rebuild:
                projectionCache.removeValue(forKey: itemID)
                firstProjectionCache.removeValue(forKey: itemID)

            case .append(let target, let chunks):
                guard let itemRevision = itemContentRevisions[itemID],
                      let itemIndex = workingItemIndexByID[itemID],
                      workingState.items.indices.contains(itemIndex) else {
                    projectionCache.removeValue(forKey: itemID)
                    firstProjectionCache.removeValue(forKey: itemID)
                    continue
                }
                let text = chunks.joined()
                let append: TranscriptProjectionTailAppend
                switch target {
                case .message(let contentID):
                    append = .message(contentID: contentID, text: text)
                case .reasoning:
                    append = .reasoning(text: text)
                case .toolOutput:
                    append = .toolOutput(text: text)
                }
                let updatedItem = workingState.items[itemIndex]
                if let cached = projectionCache[itemID],
                   cached.itemRevision == publishedItemContentRevisions[itemID] {
                    guard let result = TranscriptPerformance.measureProjection({
                        TranscriptRowProjection.appendingToTail(
                            append,
                            item: updatedItem,
                            previousRows: cached.rows
                        )
                    }) else {
                        projectionCache.removeValue(forKey: itemID)
                        continue
                    }
                    var rows = result.rows
                    if text.isEmpty,
                       rows.count > 1,
                       let first = TranscriptPerformance.measureProjection({
                           TranscriptRowProjection.makeFirstRow(item: updatedItem)
                       }) {
                        rows[0] = first.row
                        recordFirstProjection(bytes: first.projectedSourceBytes)
                    }
                    projectionCache[itemID] = ProjectionCacheEntry(
                        itemRevision: itemRevision,
                        rows: rows
                    )
                    recordIncrementalProjection(bytes: result.resegmentedSourceBytes)
                } else if let cached = firstProjectionCache[itemID],
                          cached.itemRevision == publishedItemContentRevisions[itemID] {
                    if cached.row.isLastInItem || text.isEmpty {
                        guard let result = TranscriptPerformance.measureProjection({
                            TranscriptRowProjection.makeFirstRow(item: updatedItem)
                        }) else {
                            firstProjectionCache.removeValue(forKey: itemID)
                            continue
                        }
                        firstProjectionCache[itemID] = FirstProjectionCacheEntry(
                            itemRevision: itemRevision,
                            row: result.row
                        )
                        recordFirstProjection(bytes: result.projectedSourceBytes)
                    } else {
                        // This first tile is already sealed. An append to the
                        // logical tail cannot alter it, so only advance the
                        // revision that pairs it with the published item.
                        firstProjectionCache[itemID] = FirstProjectionCacheEntry(
                            itemRevision: itemRevision,
                            row: cached.row
                        )
                    }
                }
            }
        }
        pendingProjectionChanges.removeAll(keepingCapacity: true)
    }

    private func recordIncrementalProjection(bytes: Int) {
        projectionDiagnostics.incrementalTailBuilds += 1
        projectionDiagnostics.totalIncrementalSourceBytes += bytes
        projectionDiagnostics.lastIncrementalSourceBytes = bytes
        projectionDiagnostics.maximumIncrementalSourceBytes = max(
            projectionDiagnostics.maximumIncrementalSourceBytes,
            bytes
        )
    }

    private func recordFirstProjection(bytes: Int) {
        projectionDiagnostics.boundedFirstRowBuilds += 1
        projectionDiagnostics.lastFirstRowSourceBytes = bytes
        projectionDiagnostics.maximumFirstRowSourceBytes = max(
            projectionDiagnostics.maximumFirstRowSourceBytes,
            bytes
        )
    }

    private func recordTranscriptMutation(
        for envelope: ChatEnvelope,
        changedItemID: String?,
        changedItemWasPresent: Bool,
        previousItemCount: Int,
        terminalTranscriptChanges: TerminalTranscriptChanges,
        preservesPaintedTranscript: Bool
    ) {
        let kind = ChatEventKind(rawValue: envelope.type)
        guard Self.affectsTranscriptContent(envelope) else { return }
        if kind == .conversationSnapshot {
            guard !preservesPaintedTranscript else { return }
            pendingTranscriptReset = true
            pendingTranscriptInsertions.removeAll()
            pendingTranscriptPrepends.removeAll()
            pendingTranscriptRemovals.removeAll()
            pendingTranscriptChanges.removeAll()
            return
        }

        let insertedChangedItem = changedItemID != nil && !changedItemWasPresent
        let previousKnownItemIDs: Set<String> = {
            guard workingState.items.count != previousItemCount
                    || kind == .historyPage
                    || insertedChangedItem else {
                return []
            }
            return Set(itemContentRevisions.keys)
        }()
        if workingState.items.count != previousItemCount
            || kind == .historyPage
            || insertedChangedItem {
            let currentIDs = Set(workingState.items.map(\.id))
            for (index, item) in workingState.items.enumerated()
                where !previousKnownItemIDs.contains(item.id) {
                pendingTranscriptInsertions[item.id] = index
                if kind == .historyPage {
                    pendingTranscriptPrepends.insert(item.id)
                }
            }
            for removed in previousKnownItemIDs.subtracting(currentIDs) {
                pendingTranscriptRemovals.insert(removed)
                pendingTranscriptChanges.remove(removed)
            }
        }

        if let changedItemID,
           changedItemWasPresent,
           !pendingTranscriptRemovals.contains(changedItemID) {
            pendingTranscriptChanges.insert(changedItemID)
        }

        switch kind {
        case .approvalRequested, .approvalResolved, .approvalExpired:
            if let id = envelope.itemID ?? envelope.payload["displayId"]?.stringValue {
                pendingTranscriptChanges.insert("approval:\(id)")
            }
        case .questionRequested, .questionResolved, .questionExpired:
            if let id = envelope.itemID ?? envelope.payload["displayId"]?.stringValue {
                pendingTranscriptChanges.insert("question:\(id)")
            }
        case .turnCompleted, .turnFailed, .turnInterrupted:
            pendingTranscriptChanges.formUnion(terminalTranscriptChanges.rowIDs)
        default:
            break
        }
    }

    private func scheduleStreamingPublish() {
        guard streamingPublishTask == nil else { return }
        streamingPublishTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: streamingPublishNanoseconds)
            guard !Task.isCancelled else { return }
            guard isNearBottom, !isTranscriptLiveScrolling else {
                streamingPublishTask = nil
                return
            }
            publishImmediately()
        }
    }

    private func publishImmediately(allowDuringLiveScroll: Bool = false) {
        streamingPublishTask?.cancel()
        streamingPublishTask = nil
        guard allowDuringLiveScroll || !isTranscriptLiveScrolling else {
            hasDeferredImmediatePublication = true
            return
        }
        hasDeferredImmediatePublication = false
        guard hasPendingStatePublication else { return }
        hasPendingStatePublication = false
        let hasTranscriptMutation = pendingTranscriptReset
            || !pendingTranscriptInsertions.isEmpty
            || !pendingTranscriptPrepends.isEmpty
            || !pendingTranscriptRemovals.isEmpty
            || !pendingTranscriptChanges.isEmpty
        if hasTranscriptMutation {
            transcriptMutation = TranscriptMutation(
                revision: transcriptMutation.revision &+ 1,
                isAuthoritativeReset: pendingTranscriptReset,
                insertions: pendingTranscriptInsertions
                    .map { TranscriptRowInsertion(id: $0.key, index: $0.value) }
                    .sorted { $0.index < $1.index },
                prependedIDs: pendingTranscriptPrepends.sorted {
                    (pendingTranscriptInsertions[$0] ?? 0)
                        < (pendingTranscriptInsertions[$1] ?? 0)
                },
                removedIDs: pendingTranscriptRemovals.sorted(),
                changedIDs: pendingTranscriptChanges.sorted()
            )
        }
        pendingTranscriptReset = false
        pendingTranscriptInsertions.removeAll(keepingCapacity: true)
        pendingTranscriptPrepends.removeAll(keepingCapacity: true)
        pendingTranscriptRemovals.removeAll(keepingCapacity: true)
        pendingTranscriptChanges.removeAll(keepingCapacity: true)
        adoptPreparedTranscriptProjectionsForPublication()
        applyPendingProjectionChanges()
        publishedItemContentRevisions = itemContentRevisions
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
            value.contents.reduce(0) { $0 + $1.textUTF8Count }
        case .reasoning(let value):
            value.textUTF8Count
        case .tool(let value):
            (value.input?.utf8.count ?? 0)
                + value.outputUTF8Count
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
