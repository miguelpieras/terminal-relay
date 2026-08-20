import Foundation

struct ChatProtocolContext: Equatable, Sendable {
    let requestID: String?
    let eventID: String?
    let sequence: Int64?
}

enum ChatProtocolError: LocalizedError, Equatable, Sendable {
    case recordTooLarge(ChatProtocolContext)
    case nestingTooDeep(ChatProtocolContext)
    case invalidUTF8(ChatProtocolContext)
    case invalidJSON(ChatProtocolContext)
    case unsupportedVersion(Int, ChatProtocolContext)
    case invalidEnvelope(ChatProtocolContext)
    case unterminatedRecord

    var errorDescription: String? {
        switch self {
        case .recordTooLarge:
            "The worker sent a chat record larger than the supported limit."
        case .nestingTooDeep:
            "The worker sent a chat record with unsupported nesting."
        case .invalidUTF8:
            "The worker sent invalid chat text."
        case .invalidJSON:
            "The worker sent malformed chat data."
        case .unsupportedVersion:
            "The worker uses an unsupported chat protocol version."
        case .invalidEnvelope:
            "The worker sent an invalid chat envelope."
        case .unterminatedRecord:
            "The chat stream ended in the middle of a record."
        }
    }
}

struct ChatNDJSONDecoder: Sendable {
    static let maximumRecordBytes = 1_048_576
    static let maximumNestingDepth = 32

    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> [ChatEnvelope] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)

        var records: [ChatEnvelope] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            var record = buffer[..<newlineIndex]
            buffer.removeSubrange(...newlineIndex)

            if record.last == 0x0D {
                record = record.dropLast()
            }
            guard !record.isEmpty else {
                buffer.removeAll(keepingCapacity: true)
                throw ChatProtocolError.invalidJSON(ChatProtocolContext(requestID: nil, eventID: nil, sequence: nil))
            }

            let data = Data(record)
            do {
                records.append(try decodeRecord(data))
            } catch {
                buffer.removeAll(keepingCapacity: false)
                throw error
            }
        }

        if buffer.count > Self.maximumRecordBytes {
            buffer.removeAll(keepingCapacity: false)
            throw ChatProtocolError.recordTooLarge(
                ChatProtocolContext(requestID: nil, eventID: nil, sequence: nil)
            )
        }

        return records
    }

    mutating func finish() throws -> [ChatEnvelope] {
        guard buffer.isEmpty else {
            buffer.removeAll(keepingCapacity: false)
            throw ChatProtocolError.unterminatedRecord
        }
        return []
    }

    private func decodeRecord(_ data: Data) throws -> ChatEnvelope {
        let context = Self.context(from: data)
        guard data.count <= Self.maximumRecordBytes else {
            throw ChatProtocolError.recordTooLarge(context)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw ChatProtocolError.invalidUTF8(context)
        }
        guard Self.maximumDepth(in: data) <= Self.maximumNestingDepth else {
            throw ChatProtocolError.nestingTooDeep(context)
        }

        let envelope: ChatEnvelope
        do {
            envelope = try JSONDecoder.chat.decode(ChatEnvelope.self, from: data)
        } catch {
            throw ChatProtocolError.invalidJSON(context)
        }

        let decodedContext = ChatProtocolContext(
            requestID: envelope.requestID,
            eventID: envelope.eventID,
            sequence: envelope.sequence
        )
        guard envelope.v == ChatEnvelope.legacyProtocolVersion
                || envelope.v == ChatEnvelope.protocolVersion else {
            throw ChatProtocolError.unsupportedVersion(envelope.v, decodedContext)
        }
        guard Self.isValid(envelope) else {
            throw ChatProtocolError.invalidEnvelope(decodedContext)
        }
        return envelope
    }

    private static func isValid(_ envelope: ChatEnvelope) -> Bool {
        let hasValidRouteIdentity = switch envelope.v {
        case ChatEnvelope.legacyProtocolVersion:
            envelope.accountID == nil
        case ChatEnvelope.protocolVersion:
            envelope.accountID != nil
        default:
            false
        }
        guard hasValidRouteIdentity,
              ChatWireValidation.isCanonicalUUID(envelope.relayID),
              !envelope.type.isEmpty,
              envelope.type.utf8.count <= 100,
              envelope.type.range(of: #"^[A-Za-z][A-Za-z0-9.]*$"#, options: .regularExpression) != nil,
              !envelope.provider.rawValue.isEmpty,
              envelope.provider.rawValue.utf8.count <= 32,
              envelope.providerThreadID.map(ChatWireValidation.isCanonicalUUID) != false,
              envelope.snapshotGeneration.map(ChatWireValidation.isCanonicalUUID) != false,
              envelope.requestID.map(ChatWireValidation.isCanonicalUUID) != false,
              envelope.eventID.map(ChatWireValidation.isCanonicalUUID) != false,
              envelope.sequence.map({ $0 >= 0 }) != false,
              envelope.sentAt.map({ $0 >= 0 }) != false,
              envelope.occurredAt.map({ $0 >= 0 }) != false else {
            return false
        }
        if envelope.sequence == 0,
           envelope.type != ChatEventKind.sessionHello.rawValue,
           envelope.type != ChatEventKind.error.rawValue {
            return false
        }
        return envelope.requestID != nil || envelope.eventID != nil
    }

    private static func context(from data: Data) -> ChatProtocolContext {
        struct Context: Decodable {
            let requestID: String?
            let eventID: String?
            let sequence: Int64?

            enum CodingKeys: String, CodingKey {
                case requestID = "requestId"
                case eventID = "eventId"
                case sequence = "seq"
            }
        }

        guard let value = try? JSONDecoder.chat.decode(Context.self, from: data) else {
            return ChatProtocolContext(requestID: nil, eventID: nil, sequence: nil)
        }
        return ChatProtocolContext(
            requestID: value.requestID,
            eventID: value.eventID,
            sequence: value.sequence
        )
    }

    private static func maximumDepth(in data: Data) -> Int {
        var depth = 0
        var maximum = 0
        var isInsideString = false
        var isEscaped = false

        for byte in data {
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == 0x5C {
                    isEscaped = true
                } else if byte == 0x22 {
                    isInsideString = false
                }
                continue
            }

            switch byte {
            case 0x22:
                isInsideString = true
            case 0x7B, 0x5B:
                depth += 1
                maximum = max(maximum, depth)
            case 0x7D, 0x5D:
                depth = max(0, depth - 1)
            default:
                break
            }
        }
        return maximum
    }
}

enum ChatNDJSONEncoder {
    static func encode(_ envelope: ChatEnvelope) throws -> Data {
        let data = try JSONEncoder.chat.encode(envelope)
        guard data.count <= ChatNDJSONDecoder.maximumRecordBytes else {
            throw ChatProtocolError.recordTooLarge(
                ChatProtocolContext(
                    requestID: envelope.requestID,
                    eventID: envelope.eventID,
                    sequence: envelope.sequence
                )
            )
        }
        var line = data
        line.append(0x0A)
        return line
    }
}

actor ChatCommandWriter {
    typealias Write = @Sendable (Data) async throws -> Void

    private let write: Write

    init(write: @escaping Write) {
        self.write = write
    }

    func send(_ envelope: ChatEnvelope) async throws {
        try await write(ChatNDJSONEncoder.encode(envelope))
    }
}
