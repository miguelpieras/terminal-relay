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
        case "running", "streaming": self = .running
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

/// Transcript identity is byte-preserving. Swift `String` equality treats
/// canonically equivalent Unicode as equal, which is correct for normal UI
/// comparisons but not for deciding whether authoritative worker bytes may
/// reuse a projected/copyable transcript cache.
func chatStringsHaveIdenticalUTF8(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.count == rhs.utf8.count
        && lhs.utf8.elementsEqual(rhs.utf8)
}

func chatStringsHaveIdenticalUTF8(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none):
        true
    case (.some(let lhs), .some(let rhs)):
        chatStringsHaveIdenticalUTF8(lhs, rhs)
    default:
        false
    }
}

/// Persistent chunk storage keeps published transcript snapshots cheap. Small
/// deltas accumulate in a bounded value tail; once full, that tail becomes an
/// immutable shared chunk. Appending therefore copies at most one 4 KiB tail
/// plus the incoming delta, regardless of the accumulated transcript size.
private struct PersistentChatText: Equatable, Sendable {
    private static let maximumTailUTF8Count = 4 * 1_024

    private final class SealedChunk: @unchecked Sendable {
        let previous: SealedChunk?
        let chunk: String
        let chunkCount: Int

        init(previous: SealedChunk?, chunk: String) {
            self.previous = previous
            self.chunk = chunk
            chunkCount = (previous?.chunkCount ?? 0) + 1
        }
    }

    private final class MaterializationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cachedText: String?

        init(_ cachedText: String? = nil) {
            self.cachedText = cachedText
        }

        var value: String? {
            lock.lock()
            let value = cachedText
            lock.unlock()
            return value
        }

        func store(_ text: String) -> String {
            lock.lock()
            if cachedText == nil {
                cachedText = text
            }
            let resolved = cachedText ?? text
            lock.unlock()
            return resolved
        }

        /// When detached preparation proves that an authoritative value is
        /// unchanged, retain that exact String representation. The prepared
        /// completed item can then be adopted and later encoded without
        /// rebuilding the accumulated append chain on the main actor.
        func adoptEquivalent(_ text: String) {
            lock.lock()
            cachedText = text
            lock.unlock()
        }
    }

    private let sealedTail: SealedChunk?
    private let valueTail: String
    private let valueTailUTF8Count: Int
    private let totalUTF8Count: Int
    private let materializationCache: MaterializationCache

    init(_ value: String) {
        let utf8Count = value.utf8.count
        if utf8Count > Self.maximumTailUTF8Count {
            sealedTail = SealedChunk(previous: nil, chunk: value)
            valueTail = ""
            valueTailUTF8Count = 0
        } else {
            sealedTail = nil
            valueTail = value
            valueTailUTF8Count = utf8Count
        }
        totalUTF8Count = utf8Count
        materializationCache = MaterializationCache(value)
    }

    var string: String {
        if let cachedText = materializationCache.value {
            return cachedText
        }

        let result: String
        if sealedTail == nil {
            result = valueTail
        } else if valueTail.isEmpty,
                  sealedTail?.previous == nil,
                  let onlyChunk = sealedTail?.chunk {
            result = onlyChunk
        } else {
            var chunks: [String] = []
            chunks.reserveCapacity(sealedTail?.chunkCount ?? 0)
            var chunk = sealedTail
            while let current = chunk {
                chunks.append(current.chunk)
                chunk = current.previous
            }

            var accumulated = ""
            accumulated.reserveCapacity(totalUTF8Count)
            for chunk in chunks.reversed() {
                accumulated.append(contentsOf: chunk)
            }
            accumulated.append(contentsOf: valueTail)
            result = accumulated
        }
        return materializationCache.store(result)
    }

    var utf8Count: Int { totalUTF8Count }
    var chunkCount: Int {
        (sealedTail?.chunkCount ?? 0) + (valueTail.isEmpty ? 0 : 1)
    }
    var isMaterialized: Bool { materializationCache.value != nil }

    /// Exact append lineage check used by main-actor streaming bookkeeping.
    /// A false result means callers must rebuild from a prepared snapshot; it
    /// never falls back to materializing or comparing the accumulated text.
    func sharesStorage(with other: PersistentChatText) -> Bool {
        sealedTail === other.sealedTail
            && Self.hasIdenticalUTF8(valueTail, other.valueTail)
    }

    /// Performs the authoritative equality check where the caller chooses to
    /// run it (normally detached transcript preparation), while preserving the
    /// existing append lineage only when the completed UTF-8 payload did not
    /// change. Swift String equality is canonically normalized, but transcript
    /// projection/copy must preserve the worker's exact authoritative bytes.
    func matches(_ value: String) -> Bool {
        let valueUTF8Count = value.utf8.count
        guard valueUTF8Count == totalUTF8Count,
              string.utf8.elementsEqual(value.utf8) else { return false }
        materializationCache.adoptEquivalent(value)
        return true
    }

    func appending(_ value: String) -> PersistentChatText {
        guard !value.isEmpty else { return self }
        let valueUTF8Count = value.utf8.count

        if valueTailUTF8Count + valueUTF8Count <= Self.maximumTailUTF8Count {
            var appendedTail = valueTail
            appendedTail.append(contentsOf: value)
            return PersistentChatText(
                sealedTail: sealedTail,
                valueTail: appendedTail,
                valueTailUTF8Count: valueTailUTF8Count + valueUTF8Count,
                totalUTF8Count: totalUTF8Count + valueUTF8Count
            )
        }

        var appendedSealedTail = sealedTail
        if !valueTail.isEmpty {
            appendedSealedTail = SealedChunk(
                previous: appendedSealedTail,
                chunk: valueTail
            )
        }

        if valueUTF8Count > Self.maximumTailUTF8Count {
            appendedSealedTail = SealedChunk(
                previous: appendedSealedTail,
                chunk: value
            )
            return PersistentChatText(
                sealedTail: appendedSealedTail,
                valueTail: "",
                valueTailUTF8Count: 0,
                totalUTF8Count: totalUTF8Count + valueUTF8Count
            )
        }

        return PersistentChatText(
            sealedTail: appendedSealedTail,
            valueTail: value,
            valueTailUTF8Count: valueUTF8Count,
            totalUTF8Count: totalUTF8Count + valueUTF8Count
        )
    }

    private init(
        sealedTail: SealedChunk?,
        valueTail: String,
        valueTailUTF8Count: Int,
        totalUTF8Count: Int
    ) {
        self.sealedTail = sealedTail
        self.valueTail = valueTail
        self.valueTailUTF8Count = valueTailUTF8Count
        self.totalUTF8Count = totalUTF8Count
        materializationCache = MaterializationCache()
    }

    static func == (lhs: PersistentChatText, rhs: PersistentChatText) -> Bool {
        if lhs.sealedTail === rhs.sealedTail,
           hasIdenticalUTF8(lhs.valueTail, rhs.valueTail) {
            return true
        }
        guard lhs.utf8Count == rhs.utf8Count else { return false }
        guard hasIdenticalUTF8(lhs.valueTail, rhs.valueTail) else {
            return hasIdenticalUTF8(lhs.string, rhs.string)
        }

        var left = lhs.sealedTail
        var right = rhs.sealedTail
        while let leftNode = left, let rightNode = right {
            if leftNode === rightNode { return true }
            guard hasIdenticalUTF8(leftNode.chunk, rightNode.chunk) else {
                // Equal text can have different append chunk boundaries.
                return hasIdenticalUTF8(lhs.string, rhs.string)
            }
            left = leftNode.previous
            right = rightNode.previous
        }
        if left == nil, right == nil { return true }
        return hasIdenticalUTF8(lhs.string, rhs.string)
    }

    private static func hasIdenticalUTF8(_ lhs: String, _ rhs: String) -> Bool {
        chatStringsHaveIdenticalUTF8(lhs, rhs)
    }
}

struct MessageContent: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var kind: MessageContentKind
    private var textStorage: PersistentChatText
    var text: String {
        get { textStorage.string }
        set { textStorage = PersistentChatText(newValue) }
    }
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
        textStorage = PersistentChatText(text)
        self.language = language
        self.isComplete = isComplete
        self.isTruncated = isTruncated
        self.originalByteCount = originalByteCount
    }

    var textUTF8Count: Int { textStorage.utf8Count }
    var textStorageChunkCount: Int { textStorage.chunkCount }
    var isTextStorageMaterialized: Bool { textStorage.isMaterialized }

    mutating func appendText(_ delta: String) {
        textStorage = textStorage.appending(delta)
    }

    mutating func replaceTextUnlessEqual(_ text: String) {
        guard !textStorage.matches(text) else { return }
        textStorage = PersistentChatText(text)
    }

    func hasSameText(as other: MessageContent) -> Bool {
        textStorage == other.textStorage
    }

    func sharesTextStorage(with other: MessageContent) -> Bool {
        textStorage.sharesStorage(with: other.textStorage)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case language
        case isComplete
        case isTruncated
        case originalByteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(MessageContentKind.self, forKey: .kind)
        textStorage = PersistentChatText(
            try container.decode(String.self, forKey: .text)
        )
        language = try container.decodeIfPresent(String.self, forKey: .language)
        isComplete = try container.decode(Bool.self, forKey: .isComplete)
        isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        originalByteCount = try container.decodeIfPresent(
            Int.self,
            forKey: .originalByteCount
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(isComplete, forKey: .isComplete)
        try container.encode(isTruncated, forKey: .isTruncated)
        try container.encodeIfPresent(originalByteCount, forKey: .originalByteCount)
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

    /// Structural emptiness check that never materializes persistent streaming
    /// text. Footer/layout decisions only need to know whether content exists.
    var hasText: Bool {
        contents.contains { $0.textUTF8Count > 0 }
    }

    mutating func append(_ delta: String, contentID: String? = nil) {
        let resolvedID = contentID ?? contents.last?.id ?? "\(id):content:0"
        if let index = contents.firstIndex(where: { $0.id == resolvedID }) {
            contents[index].appendText(delta)
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
                contents[0].replaceTextUnlessEqual(text)
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
    private var textStorage: PersistentChatText
    var text: String {
        get { textStorage.string }
        set { textStorage = PersistentChatText(newValue) }
    }
    var isStreaming: Bool
    var occurredAt: Int64?

    init(
        id: String,
        turnID: String?,
        text: String,
        isStreaming: Bool,
        occurredAt: Int64?
    ) {
        self.id = id
        self.turnID = turnID
        textStorage = PersistentChatText(text)
        self.isStreaming = isStreaming
        self.occurredAt = occurredAt
    }

    var textUTF8Count: Int { textStorage.utf8Count }
    var textStorageChunkCount: Int { textStorage.chunkCount }
    var isTextStorageMaterialized: Bool { textStorage.isMaterialized }

    mutating func appendText(_ delta: String) {
        textStorage = textStorage.appending(delta)
    }

    func hasSameText(as other: ChatReasoning) -> Bool {
        textStorage == other.textStorage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnID
        case text
        case isStreaming
        case occurredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        textStorage = PersistentChatText(
            try container.decode(String.self, forKey: .text)
        )
        isStreaming = try container.decode(Bool.self, forKey: .isStreaming)
        occurredAt = try container.decodeIfPresent(Int64.self, forKey: .occurredAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(text, forKey: .text)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(occurredAt, forKey: .occurredAt)
    }
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
    private var outputStorage: PersistentChatText?
    var output: String? {
        get { outputStorage?.string }
        set { outputStorage = newValue.map(PersistentChatText.init) }
    }
    var errorMessage: String?
    var durationMilliseconds: Int64?
    var exitCode: Int?
    var occurredAt: Int64?
    var isTruncated: Bool
    var originalByteCount: Int?

    init(
        id: String,
        turnID: String?,
        kind: ToolActivityKind,
        title: String,
        status: ToolActivityStatus,
        input: String?,
        output: String?,
        errorMessage: String?,
        durationMilliseconds: Int64?,
        exitCode: Int?,
        occurredAt: Int64?,
        isTruncated: Bool,
        originalByteCount: Int?
    ) {
        self.id = id
        self.turnID = turnID
        self.kind = kind
        self.title = title
        self.status = status
        self.input = input
        outputStorage = output.map(PersistentChatText.init)
        self.errorMessage = errorMessage
        self.durationMilliseconds = durationMilliseconds
        self.exitCode = exitCode
        self.occurredAt = occurredAt
        self.isTruncated = isTruncated
        self.originalByteCount = originalByteCount
    }

    var outputUTF8Count: Int { outputStorage?.utf8Count ?? 0 }
    var outputStorageChunkCount: Int { outputStorage?.chunkCount ?? 0 }
    var isOutputStorageMaterialized: Bool {
        outputStorage?.isMaterialized ?? true
    }

    mutating func appendOutput(_ delta: String) {
        if let outputStorage {
            self.outputStorage = outputStorage.appending(delta)
        } else {
            outputStorage = PersistentChatText(delta)
        }
    }

    func hasSameOutput(as other: ToolActivity) -> Bool {
        outputStorage == other.outputStorage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case turnID
        case kind
        case title
        case status
        case input
        case output
        case errorMessage
        case durationMilliseconds
        case exitCode
        case occurredAt
        case isTruncated
        case originalByteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        turnID = try container.decodeIfPresent(String.self, forKey: .turnID)
        kind = try container.decode(ToolActivityKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(ToolActivityStatus.self, forKey: .status)
        input = try container.decodeIfPresent(String.self, forKey: .input)
        outputStorage = try container.decodeIfPresent(String.self, forKey: .output)
            .map(PersistentChatText.init)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
        durationMilliseconds = try container.decodeIfPresent(
            Int64.self,
            forKey: .durationMilliseconds
        )
        exitCode = try container.decodeIfPresent(Int.self, forKey: .exitCode)
        occurredAt = try container.decodeIfPresent(Int64.self, forKey: .occurredAt)
        isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        originalByteCount = try container.decodeIfPresent(
            Int.self,
            forKey: .originalByteCount
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(turnID, forKey: .turnID)
        try container.encode(kind, forKey: .kind)
        try container.encode(title, forKey: .title)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(input, forKey: .input)
        try container.encodeIfPresent(output, forKey: .output)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)
        try container.encodeIfPresent(durationMilliseconds, forKey: .durationMilliseconds)
        try container.encodeIfPresent(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(occurredAt, forKey: .occurredAt)
        try container.encode(isTruncated, forKey: .isTruncated)
        try container.encodeIfPresent(originalByteCount, forKey: .originalByteCount)
    }
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

    /// Typeless provider content blocks used to map to placeholder "generic"
    /// tool records. Workers no longer emit them, but stored history and
    /// older workers still do. Only the shapes that duplicate other rows are
    /// noise — thinking-signature blobs and echoes of the visible message
    /// text; a tool echo's output is the sole record of what ran, so it
    /// keeps rendering.
    var isTranscriptNoise: Bool {
        guard case .tool(let tool) = self,
              tool.kind == .generic,
              tool.title == "generic",
              (tool.input ?? "").isEmpty,
              (tool.errorMessage ?? "").isEmpty else {
            return false
        }
        guard let output = tool.output, !output.isEmpty else { return true }
        return output.hasPrefix("{\"signature\"")
            || output.hasPrefix("{\"text\"")
    }

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

    /// Stronger than synthesized `Equatable`: every String that can affect a
    /// row, action, accessibility label, or copied source must have identical
    /// UTF-8 before an authoritative snapshot may retain the old projection.
    func hasExactTranscriptIdentity(as other: ConversationItem) -> Bool {
        guard self == other else { return false }
        switch (self, other) {
        case (.message(let lhs), .message(let rhs)):
            guard chatStringsHaveIdenticalUTF8(lhs.id, rhs.id),
                  chatStringsHaveIdenticalUTF8(lhs.turnID, rhs.turnID),
                  lhs.contents.count == rhs.contents.count else {
                return false
            }
            return zip(lhs.contents, rhs.contents).allSatisfy { lhs, rhs in
                chatStringsHaveIdenticalUTF8(lhs.id, rhs.id)
                    && chatStringsHaveIdenticalUTF8(lhs.language, rhs.language)
            }

        case (.reasoning(let lhs), .reasoning(let rhs)):
            return chatStringsHaveIdenticalUTF8(lhs.id, rhs.id)
                && chatStringsHaveIdenticalUTF8(lhs.turnID, rhs.turnID)

        case (.tool(let lhs), .tool(let rhs)):
            return chatStringsHaveIdenticalUTF8(lhs.id, rhs.id)
                && chatStringsHaveIdenticalUTF8(lhs.turnID, rhs.turnID)
                && chatStringsHaveIdenticalUTF8(lhs.title, rhs.title)
                && chatStringsHaveIdenticalUTF8(lhs.input, rhs.input)
                && chatStringsHaveIdenticalUTF8(lhs.errorMessage, rhs.errorMessage)

        case (.diff(let lhs), .diff(let rhs)):
            return chatStringsHaveIdenticalUTF8(lhs.id, rhs.id)
                && chatStringsHaveIdenticalUTF8(lhs.turnID, rhs.turnID)
                && chatStringsHaveIdenticalUTF8(lhs.path, rhs.path)
                && chatStringsHaveIdenticalUTF8(lhs.unifiedDiff, rhs.unifiedDiff)

        case (.plan(let lhs), .plan(let rhs)):
            guard chatStringsHaveIdenticalUTF8(lhs.id, rhs.id),
                  chatStringsHaveIdenticalUTF8(lhs.turnID, rhs.turnID),
                  chatStringsHaveIdenticalUTF8(lhs.title, rhs.title),
                  lhs.steps.count == rhs.steps.count else {
                return false
            }
            return zip(lhs.steps, rhs.steps).allSatisfy { lhs, rhs in
                chatStringsHaveIdenticalUTF8(lhs.id, rhs.id)
                    && chatStringsHaveIdenticalUTF8(lhs.title, rhs.title)
            }

        case (.generic(let lhs), .generic(let rhs)):
            return chatStringsHaveIdenticalUTF8(lhs.id, rhs.id)
                && chatStringsHaveIdenticalUTF8(lhs.turnID, rhs.turnID)
                && chatStringsHaveIdenticalUTF8(lhs.type, rhs.type)
                && chatStringsHaveIdenticalUTF8(lhs.title, rhs.title)
                && chatStringsHaveIdenticalUTF8(lhs.detail, rhs.detail)

        default:
            return false
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
    var lastErrorMessage: String?
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
        case lastErrorMessage
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
        lastErrorMessage: String? = nil,
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
        self.lastErrorMessage = lastErrorMessage
        self.capabilities = capabilities
        self.usage = usage
        self.hasOlderHistory = hasOlderHistory
        self.oldestItemID = oldestItemID
    }
}

enum ChatAttachmentKind: String, Codable, Equatable, Sendable {
    case image
    case file
}

enum ChatAttachmentPolicy {
    static let maximumCount = 32
    static let maximumFileBytes = 25 * 1_024 * 1_024
    static let maximumTurnBytes = 100 * 1_024 * 1_024

    static func accepts(
        byteCount: Int,
        existingCount: Int,
        existingBytes: Int
    ) -> Bool {
        byteCount >= 0
            && byteCount <= maximumFileBytes
            && existingCount < maximumCount
            && existingBytes >= 0
            && existingBytes <= maximumTurnBytes - byteCount
    }
}

struct ChatAttachmentDraft: Equatable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let mediaType: String
    let kind: ChatAttachmentKind
    let fileExtension: String
    let data: Data

    init(
        id: String = UUID().uuidString.lowercased(),
        displayName: String,
        mediaType: String,
        kind: ChatAttachmentKind,
        fileExtension: String,
        data: Data
    ) {
        self.id = id
        self.displayName = displayName
        self.mediaType = mediaType
        self.kind = kind
        self.fileExtension = String(
            fileExtension.lowercased().filter {
                $0.isASCII && ($0.isLetter || $0.isNumber)
            }.prefix(10)
        )
        self.data = data
    }

    var byteCount: Int { data.count }

    func reference(path: String) -> ChatAttachmentReference {
        ChatAttachmentReference(
            id: id,
            path: path,
            displayName: displayName,
            mediaType: mediaType,
            kind: kind,
            byteCount: byteCount
        )
    }
}

struct ChatAttachmentActions {
    let upload: (
        _ attachment: ChatAttachmentDraft,
        _ requestID: String
    ) async throws -> ChatAttachmentReference
    let discard: (_ requestID: String) async -> Void
}

struct ChatAttachmentReference: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let path: String
    let displayName: String
    let mediaType: String?
    let kind: ChatAttachmentKind
    let byteCount: Int?

    init(
        id: String = UUID().uuidString.lowercased(),
        path: String,
        displayName: String,
        mediaType: String? = nil,
        kind: ChatAttachmentKind = .image,
        byteCount: Int? = nil
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.mediaType = mediaType
        self.kind = kind
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case displayName
        case mediaType
        case kind
        case byteCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
            ?? UUID().uuidString.lowercased()
        path = try container.decode(String.self, forKey: .path)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            ?? URL(fileURLWithPath: path).lastPathComponent
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        kind = try container.decodeIfPresent(ChatAttachmentKind.self, forKey: .kind)
            ?? .image
        byteCount = try container.decodeIfPresent(Int.self, forKey: .byteCount)
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
