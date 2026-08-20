import Foundation

struct WorkerChatCapabilityResponse: Equatable {
    let kind: AgentKind
    let accountID: ProviderAccountID?
    let isAvailable: Bool
    let capabilities: ChatCapabilities?
    let reason: String?
}

struct WorkerChatStartResponse: Equatable {
    let relayID: String
    let kind: AgentKind
    let accountID: ProviderAccountID?
    let providerThreadID: String
    let capabilities: ChatCapabilities
    let launchOptions: [String: JSONValue]
}

enum WorkerChatProtocolError: LocalizedError, Equatable {
    case missingMarker
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "This worker does not support native chat yet."
        case .invalidResponse:
            "The worker returned an invalid native-chat response."
        }
    }
}

enum WorkerChatProtocol {
    static let marker = "__TERMINAL_RELAY_CHAT_V2__"
    static let legacyMarker = "__TERMINAL_RELAY_CHAT_V1__"

    private struct CapabilityWireResponse: Decodable {
        let provider: String
        let accountID: ProviderAccountID?
        let available: Bool
        let capabilities: ChatCapabilities?
        let reason: String?
    }

    private struct StartWireResponse: Decodable {
        let relayID: String
        let provider: String
        let accountID: ProviderAccountID?
        let providerThreadID: String
        let capabilities: ChatCapabilities
        let launchOptions: [String: JSONValue]

        enum CodingKeys: String, CodingKey {
            case relayID = "relayId"
            case provider
            case accountID
            case providerThreadID = "providerThreadId"
            case capabilities
            case launchOptions
        }
    }

    static func parseCapabilities(
        _ data: Data,
        expectedKind: AgentKind,
        expectedAccountID: ProviderAccountID? = nil
    ) throws -> WorkerChatCapabilityResponse {
        let wire: CapabilityWireResponse = try decodePayload(
            data,
            requiresAccount: expectedAccountID != nil
        )
        guard wire.provider == expectedKind.rawValue,
              wire.accountID == expectedAccountID,
              wire.reason.map(isSafeReason) != false else {
            throw WorkerChatProtocolError.invalidResponse
        }

        if wire.available {
            guard let capabilities = wire.capabilities,
                  wire.reason == nil,
                  isValid(
                      capabilities,
                      protocolVersion: expectedAccountID == nil
                          ? 1
                          : ChatEnvelope.protocolVersion
                  ) else {
                throw WorkerChatProtocolError.invalidResponse
            }
        } else {
            guard wire.capabilities == nil, wire.reason != nil else {
                throw WorkerChatProtocolError.invalidResponse
            }
        }

        return WorkerChatCapabilityResponse(
            kind: expectedKind,
            accountID: wire.accountID,
            isAvailable: wire.available,
            capabilities: wire.capabilities,
            reason: wire.reason
        )
    }

    static func parseStart(
        _ data: Data,
        expectedKind: AgentKind,
        expectedAccountID: ProviderAccountID? = nil
    ) throws -> WorkerChatStartResponse {
        let wire: StartWireResponse = try decodePayload(
            data,
            requiresAccount: expectedAccountID != nil
        )
        guard wire.provider == expectedKind.rawValue,
              wire.accountID == expectedAccountID,
              ChatWireValidation.isCanonicalUUID(wire.relayID),
              ChatWireValidation.isCanonicalUUID(wire.providerThreadID),
              isValid(
                  wire.capabilities,
                  protocolVersion: expectedAccountID == nil
                      ? 1
                      : ChatEnvelope.protocolVersion
              ),
              wire.launchOptions.count <= 16,
              wire.launchOptions.keys.allSatisfy(isSafeLaunchOptionName),
              wire.launchOptions.values.allSatisfy(isSafeLaunchOptionValue) else {
            throw WorkerChatProtocolError.invalidResponse
        }
        return WorkerChatStartResponse(
            relayID: wire.relayID,
            kind: expectedKind,
            accountID: wire.accountID,
            providerThreadID: wire.providerThreadID,
            capabilities: wire.capabilities,
            launchOptions: wire.launchOptions
        )
    }

    private static func decodePayload<Value: Decodable>(
        _ data: Data,
        requiresAccount: Bool
    ) throws -> Value {
        guard let output = String(data: data, encoding: .utf8) else {
            throw WorkerChatProtocolError.invalidResponse
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let selectedMarker = requiresAccount ? marker : legacyMarker
        guard let markerIndex = lines.firstIndex(of: selectedMarker) else {
            throw WorkerChatProtocolError.missingMarker
        }
        guard lines.count == markerIndex + 2,
              let payload = lines[markerIndex + 1].data(using: .utf8),
              payload.count <= ChatNDJSONDecoder.maximumRecordBytes,
              let value = try? JSONDecoder.chat.decode(Value.self, from: payload) else {
            throw WorkerChatProtocolError.invalidResponse
        }
        return value
    }

    private static func isValid(
        _ capabilities: ChatCapabilities,
        protocolVersion: Int
    ) -> Bool {
        capabilities.protocolVersion == protocolVersion
            && capabilities.features.count <= 64
            && capabilities.features == Array(Set(capabilities.features)).sorted()
            && capabilities.features.allSatisfy {
                !$0.isEmpty
                    && $0.utf8.count <= 64
                    && $0.range(
                        of: #"^[a-z][a-z0-9.-]*$"#,
                        options: .regularExpression
                    ) != nil
            }
    }

    private static func isSafeReason(_ reason: String) -> Bool {
        !reason.isEmpty
            && reason.utf8.count <= 100
            && reason.range(
                of: #"^[a-z][a-z0-9.-]*$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isSafeLaunchOptionName(_ name: String) -> Bool {
        !name.isEmpty
            && name.utf8.count <= 64
            && name.range(
                of: #"^[A-Za-z][A-Za-z0-9]*$"#,
                options: .regularExpression
            ) != nil
    }

    private static func isSafeLaunchOptionValue(_ value: JSONValue) -> Bool {
        switch value {
        case .null, .bool:
            true
        case .string(let value):
            value.utf8.count <= 256 && !value.contains("\n")
        case .number(let value):
            value.isFinite
        case .array, .object:
            false
        }
    }
}
