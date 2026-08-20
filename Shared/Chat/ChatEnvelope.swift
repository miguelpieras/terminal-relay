import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    subscript(key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int(exactly: value)
    }

    var int64Value: Int64? {
        guard case .number(let value) = self, value.rounded() == value else { return nil }
        return Int64(exactly: value)
    }

    var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

struct ChatEnvelope: Codable, Equatable, Identifiable, Sendable {
    static let legacyProtocolVersion = 1
    static let protocolVersion = 2

    let v: Int
    let type: String
    let requestID: String?
    let eventID: String?
    let relayID: String
    let provider: ChatProvider
    let accountID: ProviderAccountID?
    let providerThreadID: String?
    let snapshotGeneration: String?
    let sequence: Int64?
    let sentAt: Int64?
    let occurredAt: Int64?
    let turnID: String?
    let itemID: String?
    let payload: JSONValue

    var id: String {
        eventID ?? requestID ?? "\(relayID):\(type):\(sequence ?? 0)"
    }

    enum CodingKeys: String, CodingKey {
        case v
        case type
        case requestID = "requestId"
        case eventID = "eventId"
        case relayID = "relayId"
        case provider
        case accountID
        case providerThreadID = "providerThreadId"
        case snapshotGeneration
        case sequence = "seq"
        case sentAt
        case occurredAt
        case turnID = "turnId"
        case itemID = "itemId"
        case payload
    }

    init(
        v: Int = protocolVersion,
        type: String,
        requestID: String? = nil,
        eventID: String? = nil,
        relayID: String,
        provider: ChatProvider,
        accountID: ProviderAccountID? = nil,
        providerThreadID: String? = nil,
        snapshotGeneration: String? = nil,
        sequence: Int64? = nil,
        sentAt: Int64? = nil,
        occurredAt: Int64? = nil,
        turnID: String? = nil,
        itemID: String? = nil,
        payload: JSONValue = .object([:])
    ) {
        self.v = v
        self.type = type
        self.requestID = requestID
        self.eventID = eventID
        self.relayID = relayID
        self.provider = provider
        self.accountID = accountID
        self.providerThreadID = providerThreadID
        self.snapshotGeneration = snapshotGeneration
        self.sequence = sequence
        self.sentAt = sentAt
        self.occurredAt = occurredAt
        self.turnID = turnID
        self.itemID = itemID
        self.payload = payload
    }

    func decodePayload<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONEncoder.chat.encode(payload)
        return try JSONDecoder.chat.decode(type, from: data)
    }
}

enum ChatCommand: Equatable, Sendable {
    case attach(afterSequence: Int64?, snapshotGeneration: String?)
    case loadHistory(beforeItemID: String?, limit: Int)
    case startTurn(text: String, attachments: [ChatAttachmentReference], options: ChatLaunchOptions)
    case interrupt(turnID: String)
    case respondToApproval(
        providerConnectionGeneration: String,
        providerRequestID: JSONValue,
        decision: String,
        permissionChanges: JSONValue?
    )
    case answerQuestion(
        providerConnectionGeneration: String,
        providerRequestID: JSONValue,
        answers: [ChatQuestionAnswer]
    )
    case previewFile(ChatRepositoryLink)
    case stop
    case detach
    case ping

    var type: String {
        switch self {
        case .attach: "session.attach"
        case .loadHistory: "history.load"
        case .startTurn: "turn.start"
        case .interrupt: "turn.interrupt"
        case .respondToApproval: "approval.respond"
        case .answerQuestion: "question.respond"
        case .previewFile: "file.preview"
        case .stop: "session.stop"
        case .detach: "session.detach"
        case .ping: "ping"
        }
    }

    func envelope(
        identity: ChatConversationIdentity,
        requestID: String = UUID().uuidString.lowercased(),
        sentAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) throws -> ChatEnvelope {
        guard identity.isValid else {
            throw ConversationCoordinatorError.invalidIdentity
        }
        let payload: JSONValue
        var turnID: String?

        switch self {
        case .attach(let afterSequence, let snapshotGeneration):
            payload = .object([
                "afterSeq": .number(Double(afterSequence ?? 0)),
                "snapshotGeneration": snapshotGeneration.map(JSONValue.string) ?? .null,
            ])
        case .loadHistory(let beforeItemID, let limit):
            payload = .object([
                "beforeItemId": beforeItemID.map(JSONValue.string) ?? .null,
                "limit": .number(Double(limit)),
            ])
        case .startTurn(let text, let attachments, let options):
            var values: [String: JSONValue] = [
                "text": .string(text),
                "attachments": try JSONValue.encoded(attachments),
            ]
            if let model = options.model { values["model"] = .string(model) }
            if let effort = options.reasoningEffort { values["reasoningEffort"] = .string(effort) }
            if let sandbox = options.sandbox { values["sandbox"] = .string(sandbox) }
            if let policy = options.approvalPolicy { values["approvalPolicy"] = .string(policy) }
            if let fastMode = options.fastMode { values["fastMode"] = .bool(fastMode) }
            payload = .object(values)
        case .interrupt(let exactTurnID):
            turnID = exactTurnID
            payload = .object(["turnId": .string(exactTurnID)])
        case .respondToApproval(
            let generation,
            let providerRequestID,
            let decision,
            let permissionChanges
        ):
            payload = .object([
                "providerConnectionGeneration": .string(generation),
                "providerRequestId": providerRequestID,
                "decision": .string(decision),
                "permissionChanges": permissionChanges ?? .null,
            ])
        case .answerQuestion(let generation, let providerRequestID, let answers):
            payload = .object([
                "providerConnectionGeneration": .string(generation),
                "providerRequestId": providerRequestID,
                "answers": try JSONValue.encoded(answers),
            ])
        case .previewFile(let link):
            var values: [String: JSONValue] = ["path": .string(link.path)]
            if let line = link.line { values["line"] = .number(Double(line)) }
            if let column = link.column { values["column"] = .number(Double(column)) }
            payload = .object(values)
        case .stop:
            payload = .object(["relayId": .string(identity.relayID)])
        case .detach, .ping:
            payload = .object([:])
        }

        return ChatEnvelope(
            v: identity.protocolVersion,
            type: type,
            requestID: requestID,
            relayID: identity.relayID,
            provider: identity.provider,
            accountID: identity.accountID,
            providerThreadID: identity.providerThreadID,
            sentAt: sentAt,
            turnID: turnID,
            payload: payload
        )
    }
}

enum ChatEventKind: String, CaseIterable, Sendable {
    case sessionHello = "session.hello"
    case sessionState = "session.state"
    case sessionHeartbeat = "session.heartbeat"
    case terminalFallbackRequired = "session.terminalFallbackRequired"
    case sessionEnded = "session.ended"
    case acknowledgement = "ack"
    case error
    case conversationSnapshot = "conversation.snapshot"
    case historyPage = "history.page"
    case messageStarted = "message.started"
    case messageDelta = "message.delta"
    case messageCompleted = "message.completed"
    case reasoningStarted = "reasoning.started"
    case reasoningDelta = "reasoning.delta"
    case reasoningCompleted = "reasoning.completed"
    case toolStarted = "tool.started"
    case toolUpdated = "tool.updated"
    case toolCompleted = "tool.completed"
    case fileChangeUpdated = "fileChange.updated"
    case diffUpdated = "diff.updated"
    case filePreview = "file.preview"
    case approvalRequested = "approval.requested"
    case approvalResolved = "approval.resolved"
    case approvalExpired = "approval.expired"
    case questionRequested = "question.requested"
    case questionResolved = "question.resolved"
    case questionExpired = "question.expired"
    case planUpdated = "plan.updated"
    case usageUpdated = "usage.updated"
    case turnStarted = "turn.started"
    case turnCompleted = "turn.completed"
    case turnFailed = "turn.failed"
    case turnInterrupted = "turn.interrupted"
}

enum ChatEvent: Equatable, Sendable {
    case known(ChatEventKind, ChatEnvelope)
    case unknown(ChatEnvelope)

    init(envelope: ChatEnvelope) {
        if let kind = ChatEventKind(rawValue: envelope.type) {
            self = .known(kind, envelope)
        } else {
            self = .unknown(envelope)
        }
    }

    var envelope: ChatEnvelope {
        switch self {
        case .known(_, let envelope), .unknown(let envelope):
            envelope
        }
    }
}

extension JSONValue {
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder.chat.encode(value)
        return try JSONDecoder.chat.decode(JSONValue.self, from: data)
    }
}

extension JSONEncoder {
    static var chat: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var chat: JSONDecoder {
        JSONDecoder()
    }
}

extension ChatConversationIdentity {
    var protocolVersion: Int {
        accountID == nil
            ? ChatEnvelope.legacyProtocolVersion
            : ChatEnvelope.protocolVersion
    }

    var isValid: Bool {
        ChatWireValidation.isCanonicalUUID(relayID)
            && providerThreadID.map(ChatWireValidation.isCanonicalUUID) != false
            && !provider.rawValue.isEmpty
    }

    func matches(_ envelope: ChatEnvelope) -> Bool {
        protocolVersion == envelope.v
            && relayID == envelope.relayID
            && provider == envelope.provider
            && accountID == envelope.accountID
            && providerThreadID == envelope.providerThreadID
    }
}

enum ChatWireValidation {
    static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }
}
