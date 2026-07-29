import Foundation

struct WorkerResourceSnapshot: Equatable {
    let cpuUsedPercent: Double
    let memoryUsedPercent: Double
    let diskUsedPercent: Double
}

struct WorkerAccountLimitSnapshot: Equatable {
    let name: String
    let usedPercent: Double

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct WorkerAccountSnapshot: Equatable {
    let account: String?
    let plan: String?
    let limits: [WorkerAccountLimitSnapshot]
}

struct WorkerOverviewSnapshot: Equatable {
    let projects: [String]
    let sessions: [WorkerSessionSnapshot]
    let resources: WorkerResourceSnapshot?
    let accounts: [AgentKind: WorkerAccountSnapshot]
    let accountErrors: Set<AgentKind>
    let connectionError: String?
    let updateStatus: WorkerUpdateStatus?
    var runtimeInfo: WorkerRuntimeInfo? = nil
    var runtimeUpdateStatus: WorkerRuntimeUpdateStatus? = nil

    var isOnline: Bool {
        connectionError == nil
    }
}

enum WorkerOverviewParsingError: LocalizedError, Equatable {
    case invalidResources
    case invalidAccountUsage(AgentKind)

    var errorDescription: String? {
        switch self {
        case .invalidResources:
            "The worker returned invalid system usage."
        case .invalidAccountUsage(let kind):
            "\(kind.displayName) did not return account usage."
        }
    }
}

enum WorkerOverviewParser {
    static func resources(_ data: Data) throws -> WorkerResourceSnapshot {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let markerIndex = lines.firstIndex(of: "__TERMINAL_RELAY_METRICS_V1__") else {
            throw WorkerOverviewParsingError.invalidResources
        }

        var cpuPercent: Double?
        var memoryPercent: Double?
        var diskPercent: Double?

        for line in lines.dropFirst(markerIndex + 1) {
            let fields = line
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count == 3,
                  let first = Double(fields[1]),
                  let second = Double(fields[2]) else {
                throw WorkerOverviewParsingError.invalidResources
            }

            switch fields[0] {
            case "cpu":
                guard cpuPercent == nil, second > 0, first >= 0, first <= second else {
                    throw WorkerOverviewParsingError.invalidResources
                }
                cpuPercent = first / second * 100
            case "memory":
                guard memoryPercent == nil, first > 0, second >= 0, second <= first else {
                    throw WorkerOverviewParsingError.invalidResources
                }
                memoryPercent = (first - second) / first * 100
            case "disk":
                guard diskPercent == nil, first > 0, second >= 0, second <= first else {
                    throw WorkerOverviewParsingError.invalidResources
                }
                diskPercent = second / first * 100
            default:
                throw WorkerOverviewParsingError.invalidResources
            }
        }

        guard let cpuPercent, let memoryPercent, let diskPercent else {
            throw WorkerOverviewParsingError.invalidResources
        }
        return WorkerResourceSnapshot(
            cpuUsedPercent: cpuPercent,
            memoryUsedPercent: memoryPercent,
            diskUsedPercent: diskPercent
        )
    }

    static func codexAccount(_ data: Data) throws -> WorkerAccountSnapshot {
        var rateLimits: CodexRateLimits?
        var account: CodexAccount?

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: lineData) else {
                continue
            }
            if envelope.id == 1 {
                rateLimits = envelope.result?.rateLimits
            } else if envelope.id == 2 {
                account = envelope.result?.account
            }
        }

        guard let rateLimits else {
            throw WorkerOverviewParsingError.invalidAccountUsage(.codex)
        }
        let windows = [rateLimits.primary, rateLimits.secondary].compactMap { $0 }
        guard !windows.isEmpty else {
            throw WorkerOverviewParsingError.invalidAccountUsage(.codex)
        }

        return WorkerAccountSnapshot(
            account: account?.email?.nilIfEmpty,
            plan: account?.planType?.nilIfEmpty ?? rateLimits.planType?.nilIfEmpty,
            limits: windows.enumerated().map { index, window in
                WorkerAccountLimitSnapshot(
                    name: codexWindowName(minutes: window.windowDurationMins, index: index),
                    usedPercent: min(max(window.usedPercent, 0), 100)
                )
            }
        )
    }

    static func claudeAccount(_ data: Data) throws -> WorkerAccountSnapshot {
        let output = String(decoding: data, as: UTF8.self)
        let authMarker = "__TERMINAL_RELAY_CLAUDE_AUTH__"
        let usageMarker = "__TERMINAL_RELAY_CLAUDE_USAGE__"
        var auth: ClaudeAuth?
        var usageText = output

        if let authRange = output.range(of: authMarker),
           let usageRange = output.range(of: usageMarker),
           authRange.upperBound <= usageRange.lowerBound {
            let authText = output[authRange.upperBound..<usageRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let authData = authText.data(using: .utf8) {
                auth = try? JSONDecoder().decode(ClaudeAuth.self, from: authData)
            }
            usageText = String(output[usageRange.upperBound...])
        }

        let limits = usageText
            .split(whereSeparator: \.isNewline)
            .compactMap { claudeLimit(String($0)) }
        guard !limits.isEmpty else {
            throw WorkerOverviewParsingError.invalidAccountUsage(.claude)
        }
        return WorkerAccountSnapshot(
            account: auth?.email?.nilIfEmpty,
            plan: auth?.subscriptionType?.nilIfEmpty,
            limits: limits
        )
    }

    private static func codexWindowName(minutes: Int?, index: Int) -> String {
        guard let minutes, minutes > 0 else {
            return index == 0 ? "Primary" : "Secondary"
        }
        if minutes == 10_080 { return "Weekly" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }

    private static func claudeLimit(_ line: String) -> WorkerAccountLimitSnapshot? {
        let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let header = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if header == "Current session" {
            name = "Session"
        } else if header.hasPrefix("Current week ("), header.hasSuffix(")") {
            name = "Weekly"
        } else {
            return nil
        }

        let details = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let usedRange = details.range(of: "% used"),
              let usedPercent = Double(details[..<usedRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return WorkerAccountLimitSnapshot(
            name: name,
            usedPercent: min(max(usedPercent, 0), 100)
        )
    }
}

enum WorkerOverviewFilter {
    static func matches(
        profile: WorkerProfile,
        snapshot: WorkerOverviewSnapshot?,
        query: String
    ) -> Bool {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else { return true }

        var values = [
            profile.displayName,
            profile.host,
            profile.username,
        ]
        if let snapshot {
            values.append(contentsOf: snapshot.projects)
            for account in snapshot.accounts.values {
                values.append(contentsOf: [account.account, account.plan].compactMap { $0 })
            }
        }
        return values.contains {
            $0.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}

private struct CodexEnvelope: Decodable {
    let id: Int?
    let result: CodexResult?
}

private struct CodexResult: Decodable {
    let rateLimits: CodexRateLimits?
    let account: CodexAccount?
}

private struct CodexRateLimits: Decodable {
    let primary: CodexWindow?
    let secondary: CodexWindow?
    let planType: String?
}

private struct CodexWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
}

private struct CodexAccount: Decodable {
    let email: String?
    let planType: String?
}

private struct ClaudeAuth: Decodable {
    let email: String?
    let subscriptionType: String?
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
