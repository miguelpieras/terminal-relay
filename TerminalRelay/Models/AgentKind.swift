import Foundation

enum AgentKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var defaultCommand: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }
}

enum ProviderAccountStorageKind: String, Codable, Equatable, Hashable, Sendable {
    case legacyDefault
    case isolated
}

enum ProviderAccountStatus: String, Codable, Equatable, Hashable, Sendable {
    case active
    case authRequired
    case disabled

    var isUsable: Bool { self == .active }
}

/// Public metadata for one worker-owned provider login. Credentials and
/// provider storage paths never cross this boundary.
struct ProviderAccountProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    let accountID: ProviderAccountID
    let provider: AgentKind
    let label: String
    let storageKind: ProviderAccountStorageKind
    let status: ProviderAccountStatus

    var id: ProviderAccountID { accountID }

    var displayName: String {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Unnamed account" : value
    }

    var routeKey: String { "\(provider.rawValue):\(accountID.rawValue)" }
}

struct ProviderAccountKey: Hashable, Sendable {
    let workerID: UUID
    let provider: AgentKind
    let accountID: ProviderAccountID
}

enum ProviderAccountProtocolError: LocalizedError, Equatable {
    case missingMarker
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "This worker does not support multiple provider accounts yet."
        case .invalidResponse:
            "The worker returned invalid provider account metadata."
        }
    }
}

enum ProviderAccountProtocol {
    static let marker = "__TERMINAL_RELAY_PROVIDER_ACCOUNTS_V1__"

    private struct WireResponse: Decodable {
        let accounts: [ProviderAccountProfile]
    }

    static func parse(
        _ data: Data,
        expectedProvider: AgentKind? = nil,
        expectedAccountID: ProviderAccountID? = nil
    ) throws -> [ProviderAccountProfile] {
        guard let output = String(data: data, encoding: .utf8) else {
            throw ProviderAccountProtocolError.invalidResponse
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let markerIndex = lines.firstIndex(of: marker) else {
            throw ProviderAccountProtocolError.missingMarker
        }
        guard lines.count == markerIndex + 2,
              let payload = lines[markerIndex + 1].data(using: .utf8),
              payload.count <= ChatNDJSONDecoder.maximumRecordBytes,
              let response = try? JSONDecoder().decode(WireResponse.self, from: payload),
              response.accounts.count <= 100 else {
            throw ProviderAccountProtocolError.invalidResponse
        }

        var seen: Set<String> = []
        for account in response.accounts {
            guard account.label.utf8.count <= 100,
                  !account.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !account.label.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  expectedProvider.map({ account.provider == $0 }) != false,
                  expectedAccountID.map({ account.accountID == $0 }) != false,
                  seen.insert(account.routeKey).inserted else {
                throw ProviderAccountProtocolError.invalidResponse
            }
        }
        return response.accounts.sorted {
            if $0.provider != $1.provider {
                return $0.provider.rawValue < $1.provider.rawValue
            }
            let labelOrder = $0.label.localizedStandardCompare($1.label)
            if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
            return $0.accountID.rawValue < $1.accountID.rawValue
        }
    }
}
