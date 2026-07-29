import Foundation

struct ChatProvider: RawRepresentable, Codable, Equatable, Hashable, Sendable {
    let rawValue: String

    static let codex = ChatProvider(rawValue: "codex")
    static let claude = ChatProvider(rawValue: "claude")
}

struct ChatConversationIdentity: Codable, Equatable, Sendable {
    let relayID: String
    let provider: ChatProvider
    let providerThreadID: String?

    init(relayID: String, provider: ChatProvider, providerThreadID: String? = nil) {
        self.relayID = relayID
        self.provider = provider
        self.providerThreadID = providerThreadID
    }
}

enum ChatConnectionState: Equatable, Sendable {
    case connecting
    case streaming
    case awaitingApproval
    case offlineAgentRunning
    case interrupted
    case stopped
    case unsupportedWorker
    case failed
    case unknown(String)

    var rawValue: String {
        switch self {
        case .connecting: "connecting"
        case .streaming: "streaming"
        case .awaitingApproval: "awaitingApproval"
        case .offlineAgentRunning: "offlineAgentRunning"
        case .interrupted: "interrupted"
        case .stopped: "stopped"
        case .unsupportedWorker: "unsupportedWorker"
        case .failed: "failed"
        case .unknown(let value): value
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "connecting": self = .connecting
        case "streaming": self = .streaming
        case "awaitingApproval": self = .awaitingApproval
        case "offlineAgentRunning": self = .offlineAgentRunning
        case "interrupted": self = .interrupted
        case "stopped": self = .stopped
        case "unsupportedWorker": self = .unsupportedWorker
        case "failed": self = .failed
        default: self = .unknown(rawValue)
        }
    }
}

extension ChatConnectionState: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

enum TurnState: Equatable, Sendable {
    case idle
    case running
    case awaitingApproval
    case completed
    case failed
    case interrupted
    case stopped
    case unknown(String)

    var rawValue: String {
        switch self {
        case .idle: "idle"
        case .running: "running"
        case .awaitingApproval: "awaitingApproval"
        case .completed: "completed"
        case .failed: "failed"
        case .interrupted: "interrupted"
        case .stopped: "stopped"
        case .unknown(let value): value
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "idle": self = .idle
        case "running": self = .running
        case "awaitingApproval": self = .awaitingApproval
        case "completed": self = .completed
        case "failed": self = .failed
        case "interrupted": self = .interrupted
        case "stopped": self = .stopped
        default: self = .unknown(rawValue)
        }
    }

    var isActive: Bool {
        self == .running || self == .awaitingApproval
    }
}

extension TurnState: Codable {
    init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct ChatCapabilities: Codable, Equatable, Sendable {
    var protocolVersion: Int
    var features: [String]
    var supportsHistory: Bool
    var supportsFilePreview: Bool
    var supportsApprovals: Bool
    var supportsQuestions: Bool
    var supportsAttachments: Bool

    init(
        protocolVersion: Int = 1,
        features: [String] = [],
        supportsHistory: Bool = true,
        supportsFilePreview: Bool = true,
        supportsApprovals: Bool = true,
        supportsQuestions: Bool = true,
        supportsAttachments: Bool = false
    ) {
        self.protocolVersion = protocolVersion
        self.features = Array(Set(features)).sorted()
        self.supportsHistory = supportsHistory
        self.supportsFilePreview = supportsFilePreview
        self.supportsApprovals = supportsApprovals
        self.supportsQuestions = supportsQuestions
        self.supportsAttachments = supportsAttachments
    }
}

enum ChatMessageRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
    case system
}

enum MessageContentKind: String, Codable, Equatable, Sendable {
    case markdown
    case plainText
    case code
    case imagePlaceholder
    case generic
}

struct MessageContent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var kind: MessageContentKind
    var text: String
    var language: String?
    var isComplete: Bool
    var isTruncated: Bool
    var originalByteCount: Int?

    init(
        id: String,
        kind: MessageContentKind = .markdown,
        text: String,
        language: String? = nil,
        isComplete: Bool = true,
        isTruncated: Bool = false,
        originalByteCount: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.language = language
        self.isComplete = isComplete
        self.isTruncated = isTruncated
        self.originalByteCount = originalByteCount
    }
}

struct ChatMessage: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var role: ChatMessageRole
    var contents: [MessageContent]
    var occurredAt: Int64?
    var isStreaming: Bool
    var isOptimistic: Bool

    init(
        id: String,
        turnID: String? = nil,
        role: ChatMessageRole,
        text: String,
        occurredAt: Int64? = nil,
        isStreaming: Bool = false,
        isOptimistic: Bool = false
    ) {
        self.id = id
        self.turnID = turnID
        self.role = role
        self.contents = [
            MessageContent(
                id: "\(id):content:0",
                text: text,
                isComplete: !isStreaming
            ),
        ]
        self.occurredAt = occurredAt
        self.isStreaming = isStreaming
        self.isOptimistic = isOptimistic
    }

    var text: String {
        contents.map(\.text).joined()
    }

    mutating func append(_ delta: String, contentID: String? = nil) {
        let resolvedID = contentID ?? contents.last?.id ?? "\(id):content:0"
        if let index = contents.firstIndex(where: { $0.id == resolvedID }) {
            contents[index].text += delta
            contents[index].isComplete = false
        } else {
            contents.append(
                MessageContent(id: resolvedID, text: delta, isComplete: false)
            )
        }
        isStreaming = true
    }

    mutating func complete(
        text: String?,
        isTruncated: Bool = false,
        originalByteCount: Int? = nil
    ) {
        if let text {
            if contents.isEmpty {
                contents = [MessageContent(id: "\(id):content:0", text: text)]
            } else {
                contents[0].text = text
                if contents.count > 1 {
                    contents.removeSubrange(1...)
                }
            }
        }
        for index in contents.indices {
            contents[index].isComplete = true
            contents[index].isTruncated = isTruncated
            contents[index].originalByteCount = originalByteCount
        }
        isStreaming = false
        isOptimistic = false
    }
}

struct ChatReasoning: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var text: String
    var isStreaming: Bool
    var occurredAt: Int64?
}

enum ToolActivityStatus: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

enum ToolActivityKind: String, Codable, Equatable, Sendable {
    case shell
    case fileRead
    case search
    case edit
    case mcp
    case web
    case plan
    case generic
}

struct ToolActivity: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var kind: ToolActivityKind
    var title: String
    var status: ToolActivityStatus
    var input: String?
    var output: String?
    var errorMessage: String?
    var durationMilliseconds: Int64?
    var exitCode: Int?
    var occurredAt: Int64?
    var isTruncated: Bool
    var originalByteCount: Int?
}

struct ChatDiff: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var path: String?
    var unifiedDiff: String
    var occurredAt: Int64?
    var isTruncated: Bool
}

enum ApprovalStatus: String, Codable, Equatable, Sendable {
    case pending
    case approved
    case denied
    case expired
}

struct ApprovalDecision: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let isDestructive: Bool

    init(id: String, label: String, isDestructive: Bool = false) {
        self.id = id
        self.label = label
        self.isDestructive = isDestructive
    }
}

struct ApprovalRequest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var providerConnectionGeneration: String
    var providerRequestID: JSONValue
    var title: String
    var reason: String?
    var context: String?
    var decisions: [ApprovalDecision]
    var status: ApprovalStatus
    var occurredAt: Int64?
}

enum QuestionKind: String, Codable, Equatable, Sendable {
    case singleChoice
    case multipleChoice
    case freeText
    case secret
}

enum QuestionStatus: String, Codable, Equatable, Sendable {
    case pending
    case answered
    case expired
}

struct QuestionOption: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let label: String
    let detail: String?

    init(id: String, label: String, detail: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
    }
}

struct QuestionField: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var prompt: String
    var kind: QuestionKind
    var options: [QuestionOption]
    var allowsOther: Bool

    init(
        id: String,
        prompt: String,
        kind: QuestionKind,
        options: [QuestionOption] = [],
        allowsOther: Bool = false
    ) {
        self.id = id
        self.prompt = prompt
        self.kind = kind
        self.options = options
        self.allowsOther = allowsOther
    }
}

struct QuestionRequest: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var providerConnectionGeneration: String
    var providerRequestID: JSONValue
    var prompt: String
    var kind: QuestionKind
    var options: [QuestionOption]
    var allowsOther: Bool
    var status: QuestionStatus
    var occurredAt: Int64?
    var fields: [QuestionField]?

    init(
        id: String,
        turnID: String? = nil,
        providerConnectionGeneration: String,
        providerRequestID: JSONValue,
        prompt: String,
        kind: QuestionKind,
        options: [QuestionOption] = [],
        allowsOther: Bool = false,
        status: QuestionStatus = .pending,
        occurredAt: Int64? = nil,
        fields: [QuestionField]? = nil
    ) {
        self.id = id
        self.turnID = turnID
        self.providerConnectionGeneration = providerConnectionGeneration
        self.providerRequestID = providerRequestID
        self.prompt = prompt
        self.kind = kind
        self.options = options
        self.allowsOther = allowsOther
        self.status = status
        self.occurredAt = occurredAt
        self.fields = fields
    }

    var resolvedFields: [QuestionField] {
        if let fields, !fields.isEmpty {
            return fields
        }
        return [
            QuestionField(
                id: id,
                prompt: prompt,
                kind: kind,
                options: options,
                allowsOther: allowsOther
            ),
        ]
    }

    func draftKey(for field: QuestionField) -> String {
        "\(id):\(field.id)"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case turnID = "turnId"
        case providerConnectionGeneration
        case providerRequestID = "providerRequestId"
        case prompt
        case kind
        case options
        case allowsOther
        case status
        case occurredAt
        case fields = "questions"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        providerConnectionGeneration = try container.decode(
            String.self,
            forKey: .providerConnectionGeneration
        )
        providerRequestID = try container.decode(JSONValue.self, forKey: .providerRequestID)
        fields = try container.decodeIfPresent([QuestionField].self, forKey: .fields)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
            ?? fields?.first?.prompt
            ?? "Agent needs input"
        kind = try container.decodeIfPresent(QuestionKind.self, forKey: .kind)
            ?? fields?.first?.kind
            ?? .freeText
        options = try container.decodeIfPresent([QuestionOption].self, forKey: .options)
            ?? fields?.first?.options
            ?? []
        allowsOther = try container.decodeIfPresent(Bool.self, forKey: .allowsOther)
            ?? fields?.first?.allowsOther
            ?? false
        status = try container.decodeIfPresent(QuestionStatus.self, forKey: .status) ?? .pending
        occurredAt = try container.decodeIfPresent(Int64.self, forKey: .occurredAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(
            providerConnectionGeneration,
            forKey: .providerConnectionGeneration
        )
        try container.encode(providerRequestID, forKey: .providerRequestID)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(kind, forKey: .kind)
        try container.encode(options, forKey: .options)
        try container.encode(allowsOther, forKey: .allowsOther)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(occurredAt, forKey: .occurredAt)
        try container.encodeIfPresent(fields, forKey: .fields)
    }
}

struct ChatPlanStep: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var title: String
    var isCompleted: Bool
}

struct ChatPlan: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var title: String?
    var steps: [ChatPlanStep]
    var occurredAt: Int64?
}

struct ChatUsage: Codable, Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var contextTokens: Int?
    var contextLimit: Int?
}

struct ChatGenericItem: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var turnID: String?
    var type: String
    var title: String
    var detail: String?
    var occurredAt: Int64?
}

enum ConversationItem: Codable, Equatable, Identifiable, Sendable {
    case message(ChatMessage)
    case reasoning(ChatReasoning)
    case tool(ToolActivity)
    case diff(ChatDiff)
    case plan(ChatPlan)
    case generic(ChatGenericItem)

    var id: String {
        switch self {
        case .message(let item): item.id
        case .reasoning(let item): item.id
        case .tool(let item): item.id
        case .diff(let item): item.id
        case .plan(let item): item.id
        case .generic(let item): item.id
        }
    }

    var occurredAt: Int64? {
        switch self {
        case .message(let item): item.occurredAt
        case .reasoning(let item): item.occurredAt
        case .tool(let item): item.occurredAt
        case .diff(let item): item.occurredAt
        case .plan(let item): item.occurredAt
        case .generic(let item): item.occurredAt
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case value
        case turnID = "turnId"
        case itemID = "itemId"
        case occurredAt
        case payload
    }

    private enum Kind: String, Codable {
        case message
        case reasoning
        case tool
        case diff
        case plan
        case generic
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = try container.decode(String.self, forKey: .type)
        if let kind = Kind(rawValue: rawType) {
            switch kind {
            case .message:
                self = .message(try container.decode(ChatMessage.self, forKey: .value))
            case .reasoning:
                self = .reasoning(try container.decode(ChatReasoning.self, forKey: .value))
            case .tool:
                self = .tool(try container.decode(ToolActivity.self, forKey: .value))
            case .diff:
                self = .diff(try container.decode(ChatDiff.self, forKey: .value))
            case .plan:
                self = .plan(try container.decode(ChatPlan.self, forKey: .value))
            case .generic:
                self = .generic(try container.decode(ChatGenericItem.self, forKey: .value))
            }
            return
        }

        let itemID = try container.decodeIfPresent(String.self, forKey: .itemID)
        let turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        let occurredAt = try container.decodeIfPresent(Int64.self, forKey: .occurredAt)
        let payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload) ?? .object([:])
        let resolvedID = itemID
            ?? payload["itemId"]?.stringValue
            ?? payload["id"]?.stringValue
            ?? "\(rawType):\(occurredAt ?? 0)"

        switch rawType {
        case "message.started", "message.delta", "message.completed":
            self = .message(
                ChatMessage(
                    id: resolvedID,
                    turnID: turnID,
                    role: ChatMessageRole(rawValue: payload["role"]?.stringValue ?? "assistant") ?? .assistant,
                    text: payload["text"]?.stringValue ?? payload["content"]?.stringValue ?? "",
                    occurredAt: occurredAt,
                    isStreaming: rawType != "message.completed"
                )
            )
        case "reasoning.started", "reasoning.delta", "reasoning.completed":
            self = .reasoning(
                ChatReasoning(
                    id: resolvedID,
                    turnID: turnID,
                    text: payload["text"]?.stringValue ?? "",
                    isStreaming: rawType != "reasoning.completed",
                    occurredAt: occurredAt
                )
            )
        case "tool.started", "tool.updated", "tool.completed":
            let status = ToolActivityStatus(rawValue: payload["status"]?.stringValue ?? "")
                ?? (rawType == "tool.completed" ? .completed : .running)
            self = .tool(
                ToolActivity(
                    id: resolvedID,
                    turnID: turnID,
                    kind: ToolActivityKind(rawValue: payload["kind"]?.stringValue ?? "") ?? .generic,
                    title: payload["title"]?.stringValue ?? payload["name"]?.stringValue ?? "Agent activity",
                    status: status,
                    input: payload["input"]?.snapshotDisplayString,
                    output: payload["output"]?.snapshotDisplayString,
                    errorMessage: payload["error"]?.snapshotDisplayString,
                    durationMilliseconds: payload["durationMs"]?.int64Value,
                    exitCode: payload["exitCode"]?.intValue,
                    occurredAt: occurredAt,
                    isTruncated: payload["truncated"]?.boolValue ?? false,
                    originalByteCount: payload["originalByteCount"]?.intValue
                )
            )
        case "fileChange.updated", "diff.updated":
            self = .diff(
                ChatDiff(
                    id: resolvedID,
                    turnID: turnID,
                    path: payload["path"]?.stringValue,
                    unifiedDiff: payload["diff"]?.stringValue
                        ?? payload["unifiedDiff"]?.stringValue
                        ?? "",
                    occurredAt: occurredAt,
                    isTruncated: payload["truncated"]?.boolValue ?? false
                )
            )
        case "plan.updated":
            let steps = (payload["steps"]?.arrayValue ?? []).enumerated().compactMap {
                index,
                value -> ChatPlanStep? in
                guard let title = value["title"]?.stringValue ?? value["text"]?.stringValue else {
                    return nil
                }
                return ChatPlanStep(
                    id: value["id"]?.stringValue ?? "\(resolvedID):\(index)",
                    title: title,
                    isCompleted: value["completed"]?.boolValue
                        ?? (value["status"]?.stringValue == "completed")
                )
            }
            self = .plan(
                ChatPlan(
                    id: resolvedID,
                    turnID: turnID,
                    title: payload["title"]?.stringValue,
                    steps: steps,
                    occurredAt: occurredAt
                )
            )
        default:
            self = .generic(
                ChatGenericItem(
                    id: resolvedID,
                    turnID: turnID,
                    type: rawType,
                    title: payload["title"]?.stringValue ?? "Agent update",
                    detail: payload["summary"]?.snapshotDisplayString,
                    occurredAt: occurredAt
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let value):
            try container.encode(Kind.message, forKey: .type)
            try container.encode(value, forKey: .value)
        case .reasoning(let value):
            try container.encode(Kind.reasoning, forKey: .type)
            try container.encode(value, forKey: .value)
        case .tool(let value):
            try container.encode(Kind.tool, forKey: .type)
            try container.encode(value, forKey: .value)
        case .diff(let value):
            try container.encode(Kind.diff, forKey: .type)
            try container.encode(value, forKey: .value)
        case .plan(let value):
            try container.encode(Kind.plan, forKey: .type)
            try container.encode(value, forKey: .value)
        case .generic(let value):
            try container.encode(Kind.generic, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

private extension JSONValue {
    var snapshotDisplayString: String? {
        switch self {
        case .null:
            return nil
        case .string(let value):
            return value
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value ? String(Int64(value)) : String(value)
        case .array, .object:
            guard let data = try? JSONEncoder.chat.encode(self) else { return nil }
            return String(data: data, encoding: .utf8)
        }
    }
}

struct ConversationSnapshot: Codable, Equatable, Sendable {
    var snapshotGeneration: String
    var baseSequence: Int64
    var items: [ConversationItem]
    var approvals: [ApprovalRequest]
    var questions: [QuestionRequest]
    var connectionState: ChatConnectionState
    var turnState: TurnState
    var activeTurnID: String?
    var capabilities: ChatCapabilities
    var usage: ChatUsage?
    var hasOlderHistory: Bool
    var oldestItemID: String?

    enum CodingKeys: String, CodingKey {
        case snapshotGeneration
        case baseSequence = "baseSeq"
        case items
        case approvals
        case questions
        case connectionState
        case turnState
        case activeTurnID = "activeTurnId"
        case capabilities
        case usage
        case hasOlderHistory
        case oldestItemID = "oldestItemId"
    }

    init(
        snapshotGeneration: String,
        baseSequence: Int64,
        items: [ConversationItem] = [],
        approvals: [ApprovalRequest] = [],
        questions: [QuestionRequest] = [],
        connectionState: ChatConnectionState = .streaming,
        turnState: TurnState = .idle,
        activeTurnID: String? = nil,
        capabilities: ChatCapabilities = ChatCapabilities(),
        usage: ChatUsage? = nil,
        hasOlderHistory: Bool = false,
        oldestItemID: String? = nil
    ) {
        self.snapshotGeneration = snapshotGeneration
        self.baseSequence = baseSequence
        self.items = items
        self.approvals = approvals
        self.questions = questions
        self.connectionState = connectionState
        self.turnState = turnState
        self.activeTurnID = activeTurnID
        self.capabilities = capabilities
        self.usage = usage
        self.hasOlderHistory = hasOlderHistory
        self.oldestItemID = oldestItemID
    }
}

struct ChatAttachmentReference: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let displayName: String
    let mediaType: String?

    init(id: String = UUID().uuidString.lowercased(), path: String, displayName: String, mediaType: String? = nil) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.mediaType = mediaType
    }
}

struct ChatLaunchOptions: Codable, Equatable, Sendable {
    var model: String?
    var reasoningEffort: String?
    var sandbox: String?
    var approvalPolicy: String?
    var fastMode: Bool?

    init(
        model: String? = nil,
        reasoningEffort: String? = nil,
        sandbox: String? = nil,
        approvalPolicy: String? = nil,
        fastMode: Bool? = nil
    ) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.fastMode = fastMode
    }
}

struct ChatQuestionAnswer: Codable, Equatable, Sendable {
    let questionID: String
    var selectedOptionIDs: [String]
    var text: String?

    init(questionID: String, selectedOptionIDs: [String] = [], text: String? = nil) {
        self.questionID = questionID
        self.selectedOptionIDs = selectedOptionIDs
        self.text = text
    }
}

enum ChatLinkDestination: Equatable, Sendable {
    case external(URL)
    case repository(ChatRepositoryLink)
    case blocked
}

struct ChatRepositoryLink: Codable, Equatable, Sendable {
    let path: String
    let line: Int?
    let column: Int?
}

struct ChatFilePreview: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let content: String
    let line: Int?
    let column: Int?
    let isTruncated: Bool
    let originalByteCount: Int?
}
