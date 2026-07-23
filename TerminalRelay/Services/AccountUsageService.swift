import Combine
import Foundation

struct AccountUsageLimit: Equatable, Identifiable {
    let id: String
    let name: String
    let usedPercent: Double
    let resetsAt: Date?
    let resetText: String?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var usedPercentText: String {
        Self.percentText(usedPercent)
    }

    var remainingPercentText: String {
        Self.percentText(remainingPercent)
    }

    private static func percentText(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        if clamped.rounded() == clamped {
            return String(format: "%.0f", clamped)
        }
        return String(format: "%.1f", clamped)
    }
}

struct CodexRateLimitResetCredit: Equatable, Identifiable, Decodable {
    let id: String
    let resetType: String
    let status: String
    let grantedAt: Date
    let expiresAt: Date?
    let title: String?
    let description: String?

    var isAvailable: Bool {
        status == "available"
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType
        case status
        case grantedAt
        case expiresAt
        case title
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        resetType = try container.decode(String.self, forKey: .resetType)
        status = try container.decode(String.self, forKey: .status)
        grantedAt = Date(
            timeIntervalSince1970: TimeInterval(try container.decode(Int64.self, forKey: .grantedAt))
        )
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
            .map { Date(timeIntervalSince1970: TimeInterval($0)) }
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
    }
}

struct CodexRateLimitResetCredits: Equatable, Decodable {
    let availableCount: Int
    let credits: [CodexRateLimitResetCredit]?
}

enum CodexResetConsumeOutcome: String, Decodable, Equatable {
    case reset
    case alreadyRedeemed
    case nothingToReset
    case noCredit
}

struct CodexResetRedemptionResult: Equatable {
    let outcome: CodexResetConsumeOutcome
    let limitsRefreshed: Bool
}

struct AccountUsageSnapshot: Equatable {
    let account: String?
    let plan: String?
    let limits: [AccountUsageLimit]
    let codexResetCredits: CodexRateLimitResetCredits?
    let fetchedAt: Date
}

enum AccountUsageError: LocalizedError, Equatable {
    case commandFailed(AgentKind)
    case invalidResponse(AgentKind)
    case signInRequired(AgentKind)
    case resetRedemptionFailed

    var errorDescription: String? {
        switch self {
        case .commandFailed(let kind):
            return "Could not reach \(kind.displayName) on this worker."
        case .invalidResponse(let kind):
            return "\(kind.displayName) did not return usage limits."
        case .signInRequired(let kind):
            return "\(kind.displayName) must be signed in before starting a new session."
        case .resetRedemptionFailed:
            return "Codex could not redeem this reset."
        }
    }
}

@MainActor
final class AccountUsageService: ObservableObject {
    struct Key: Hashable {
        let workerID: UUID
        let kind: AgentKind
    }

    @Published private(set) var snapshots: [Key: AccountUsageSnapshot] = [:]
    @Published private(set) var errors: [Key: String] = [:]
    @Published private(set) var loadingKeys: Set<Key> = []
    @Published private(set) var newSessionSignInRequiredKeys: Set<Key> = []

    private let cacheDuration: TimeInterval = 60
    private var resetRedemptionKeys: [ResetRedemptionKey: UUID] = [:]
    private var workersRedeemingCodexReset: Set<UUID> = []

    func snapshot(for workerID: UUID, kind: AgentKind) -> AccountUsageSnapshot? {
        snapshots[Key(workerID: workerID, kind: kind)]
    }

    func error(for workerID: UUID, kind: AgentKind) -> String? {
        errors[Key(workerID: workerID, kind: kind)]
    }

    func isLoading(workerID: UUID, kind: AgentKind) -> Bool {
        loadingKeys.contains(Key(workerID: workerID, kind: kind))
    }

    func requiresNewSessionSignIn(workerID: UUID, kind: AgentKind) -> Bool {
        newSessionSignInRequiredKeys.contains(Key(workerID: workerID, kind: kind))
    }

    func refresh(worker: ServerProfile, force: Bool = false) async {
        let now = Date()
        let kinds = AgentKind.allCases.filter { kind in
            let key = Key(workerID: worker.id, kind: kind)
            guard kind != .codex || !workersRedeemingCodexReset.contains(worker.id) else {
                return false
            }
            guard !loadingKeys.contains(key) else { return false }
            guard !force, let snapshot = snapshots[key] else { return true }
            return now.timeIntervalSince(snapshot.fetchedAt) >= cacheDuration
        }

        guard !kinds.isEmpty else { return }

        for kind in kinds {
            let key = Key(workerID: worker.id, kind: kind)
            loadingKeys.insert(key)
            errors[key] = nil
        }

        await withTaskGroup(of: (AgentKind, Result<AccountUsageSnapshot, Error>).self) { group in
            for kind in kinds {
                group.addTask {
                    do {
                        return (kind, .success(try await Self.fetch(kind: kind, worker: worker)))
                    } catch {
                        return (kind, .failure(error))
                    }
                }
            }

            for await (kind, result) in group {
                let key = Key(workerID: worker.id, kind: kind)
                loadingKeys.remove(key)
                switch result {
                case .success(let snapshot):
                    snapshots[key] = snapshot
                    errors[key] = nil
                    newSessionSignInRequiredKeys.remove(key)
                case .failure(let error):
                    if error as? AccountUsageError == .signInRequired(kind) {
                        snapshots[key] = nil
                        newSessionSignInRequiredKeys.insert(key)
                    } else {
                        newSessionSignInRequiredKeys.remove(key)
                    }
                    errors[key] = (error as? LocalizedError)?.errorDescription
                        ?? AccountUsageError.commandFailed(kind).localizedDescription
                }
            }
        }
    }

    func redeemCodexReset(
        worker: ServerProfile,
        creditID: String?
    ) async throws -> CodexResetRedemptionResult {
        let usageKey = Key(workerID: worker.id, kind: .codex)
        while loadingKeys.contains(usageKey) {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard workersRedeemingCodexReset.insert(worker.id).inserted else {
            throw AccountUsageError.resetRedemptionFailed
        }
        defer { workersRedeemingCodexReset.remove(worker.id) }

        let creditID = creditID?.nilIfEmpty
        let key = ResetRedemptionKey(workerID: worker.id, creditID: creditID)
        let idempotencyKey = resetRedemptionKeys[key] ?? UUID()
        resetRedemptionKeys[key] = idempotencyKey

        let outcome = try await Self.consumeCodexReset(
            worker: worker,
            creditID: creditID,
            idempotencyKey: idempotencyKey
        )
        resetRedemptionKeys[key] = nil
        let limitsRefreshed = await refreshCodexAfterRedemption(worker: worker)
        return CodexResetRedemptionResult(
            outcome: outcome,
            limitsRefreshed: limitsRefreshed
        )
    }

    private func refreshCodexAfterRedemption(worker: ServerProfile) async -> Bool {
        let key = Key(workerID: worker.id, kind: .codex)
        loadingKeys.insert(key)
        errors[key] = nil

        do {
            snapshots[key] = try await Self.fetch(kind: .codex, worker: worker)
            loadingKeys.remove(key)
            return true
        } catch {
            snapshots[key] = nil
            errors[key] = (error as? LocalizedError)?.errorDescription
                ?? AccountUsageError.commandFailed(.codex).localizedDescription
            loadingKeys.remove(key)
            return false
        }
    }

    static func parseCodex(
        _ data: Data,
        fallbackAccount: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> AccountUsageSnapshot {
        var rateLimitResult: CodexResult?
        var accountResult: CodexResult?

        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: lineData) else {
                continue
            }

            switch envelope.id {
            case codexRateLimitRequestID:
                rateLimitResult = envelope.result
            case codexAccountRequestID:
                accountResult = envelope.result
            default:
                continue
            }
        }

        guard let snapshot = rateLimitResult?.rateLimits else {
            if accountResult?.account == nil,
               accountResult?.requiresOpenaiAuth == true {
                throw AccountUsageError.signInRequired(.codex)
            }
            throw AccountUsageError.invalidResponse(.codex)
        }

        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        guard !windows.isEmpty else {
            throw AccountUsageError.invalidResponse(.codex)
        }

        let limits = windows.enumerated().map { index, window in
            AccountUsageLimit(
                id: "codex-\(index)-\(window.windowDurationMins ?? 0)",
                name: codexWindowName(minutes: window.windowDurationMins, index: index),
                usedPercent: min(max(window.usedPercent, 0), 100),
                resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
                resetText: nil
            )
        }

        let account = accountResult?.account?.email?.nilIfEmpty ?? fallbackAccount?.nilIfEmpty
        let plan = accountResult?.account?.planType?.nilIfEmpty ?? snapshot.planType?.nilIfEmpty
        return AccountUsageSnapshot(
            account: account,
            plan: plan,
            limits: limits,
            codexResetCredits: rateLimitResult?.rateLimitResetCredits,
            fetchedAt: fetchedAt
        )
    }

    static func parseClaude(
        _ data: Data,
        fallbackAccount: String? = nil,
        fetchedAt: Date = Date()
    ) throws -> AccountUsageSnapshot {
        let output = String(decoding: data, as: UTF8.self)
        let authMarker = "__TERMINAL_RELAY_CLAUDE_AUTH__"
        let usageMarker = "__TERMINAL_RELAY_CLAUDE_USAGE__"

        var auth: ClaudeAuthStatus?
        var usageText = output
        if let authRange = output.range(of: authMarker),
           let usageRange = output.range(of: usageMarker),
           authRange.upperBound <= usageRange.lowerBound {
            let authText = output[authRange.upperBound..<usageRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let authData = authText.data(using: .utf8) {
                auth = try? JSONDecoder().decode(ClaudeAuthStatus.self, from: authData)
            }
            usageText = String(output[usageRange.upperBound...])
        }

        let limits = usageText
            .split(whereSeparator: \.isNewline)
            .compactMap { claudeLimit(from: String($0)) }
        guard !limits.isEmpty else {
            throw AccountUsageError.invalidResponse(.claude)
        }

        return AccountUsageSnapshot(
            account: auth?.email?.nilIfEmpty ?? fallbackAccount?.nilIfEmpty,
            plan: auth?.subscriptionType?.nilIfEmpty,
            limits: limits,
            codexResetCredits: nil,
            fetchedAt: fetchedAt
        )
    }

    static func parseCodexResetConsume(_ data: Data) throws -> CodexResetConsumeOutcome {
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let envelope = try? JSONDecoder().decode(CodexEnvelope.self, from: lineData),
                  envelope.id == codexResetRequestID,
                  let outcome = envelope.result?.outcome else {
                continue
            }
            return outcome
        }
        throw AccountUsageError.resetRedemptionFailed
    }

    static func codexWindowName(minutes: Int?, index: Int) -> String {
        guard let minutes, minutes > 0 else {
            return index == 0 ? "Primary limit" : "Secondary limit"
        }
        if minutes == 10_080 { return "Weekly limit" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)-day limit" }
        if minutes % 60 == 0 { return "\(minutes / 60)-hour limit" }
        return "\(minutes)-minute limit"
    }

    static func claudeLimit(from line: String) -> AccountUsageLimit? {
        let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }

        let rawHeader = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        let id: String
        if rawHeader == "Current session" {
            name = "Current session"
            id = "claude-session"
        } else if rawHeader.hasPrefix("Current week ("), rawHeader.hasSuffix(")") {
            let scope = rawHeader
                .dropFirst("Current week (".count)
                .dropLast()
            name = "Weekly · \(scope)"
            id = "claude-weekly-\(scope.lowercased())"
        } else {
            return nil
        }

        let details = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let usedRange = details.range(of: "% used"),
              let usedPercent = Double(details[..<usedRange.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }

        let suffix = details[usedRange.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resetPrefix = "· resets "
        let resetText = suffix.hasPrefix(resetPrefix)
            ? String(suffix.dropFirst(resetPrefix.count)).nilIfEmpty
            : nil

        return AccountUsageLimit(
            id: id,
            name: name,
            usedPercent: min(max(usedPercent, 0), 100),
            resetsAt: nil,
            resetText: resetText
        )
    }

    private static let codexRateLimitRequestID = 1
    private static let codexAccountRequestID = 2
    private static let codexResetRequestID = 2

    private static func fetch(kind: AgentKind, worker: ServerProfile) async throws -> AccountUsageSnapshot {
        let script: String
        switch kind {
        case .codex:
            script = codexProbeScript
        case .claude:
            script = claudeProbeScript
        }

        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: GitHubProjectService.sshArguments(for: worker, script: script)
        )
        guard result.exitCode == 0 else {
            throw AccountUsageError.commandFailed(kind)
        }

        switch kind {
        case .codex:
            return try parseCodex(
                result.standardOutput,
                fallbackAccount: worker.accountLabel(for: kind)
            )
        case .claude:
            return try parseClaude(
                result.standardOutput,
                fallbackAccount: worker.accountLabel(for: kind)
            )
        }
    }

    private static func consumeCodexReset(
        worker: ServerProfile,
        creditID: String?,
        idempotencyKey: UUID
    ) async throws -> CodexResetConsumeOutcome {
        let script = try codexResetScript(
            creditID: creditID,
            idempotencyKey: idempotencyKey
        )
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: GitHubProjectService.sshArguments(for: worker, script: script)
        )
        guard result.exitCode == 0 else {
            throw AccountUsageError.commandFailed(.codex)
        }
        return try parseCodexResetConsume(result.standardOutput)
    }

    private static var codexProbeScript: String {
        let requests = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"terminal_relay","title":"Terminal Relay","version":"1.0.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            #"{"method":"account/rateLimits/read","id":1,"params":null}"#,
            #"{"method":"account/read","id":2,"params":{"refreshToken":false}}"#
        ]
        let quotedRequests = requests
            .map(GitHubProjectService.shellQuote)
            .joined(separator: " ")
        return """
        cd "$HOME" || exit 1
        { printf '%s\\n' \(quotedRequests); sleep 2; } | timeout 10s codex app-server 2>/dev/null
        """
    }

    private static func codexResetScript(
        creditID: String?,
        idempotencyKey: UUID
    ) throws -> String {
        var params: [String: String] = ["idempotencyKey": idempotencyKey.uuidString]
        if let creditID {
            params["creditId"] = creditID
        }
        let requestObject: [String: Any] = [
            "method": "account/rateLimitResetCredit/consume",
            "id": codexResetRequestID,
            "params": params
        ]
        let requestData = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
        guard let consumeRequest = String(data: requestData, encoding: .utf8) else {
            throw AccountUsageError.resetRedemptionFailed
        }

        let requests = [
            #"{"method":"initialize","id":0,"params":{"clientInfo":{"name":"terminal_relay","title":"Terminal Relay","version":"1.0.0"}}}"#,
            #"{"method":"initialized","params":{}}"#,
            consumeRequest
        ]
        let quotedRequests = requests
            .map(GitHubProjectService.shellQuote)
            .joined(separator: " ")
        return """
        cd "$HOME" || exit 1
        { printf '%s\\n' \(quotedRequests); sleep 2; } | timeout 10s codex app-server 2>/dev/null
        """
    }

    private static let claudeProbeScript = """
    cd "$HOME" || exit 1
    printf '%s\\n' '__TERMINAL_RELAY_CLAUDE_AUTH__'
    claude auth status --json 2>/dev/null || true
    printf '%s\\n' '__TERMINAL_RELAY_CLAUDE_USAGE__'
    DISABLE_AUTOUPDATER=1 timeout 20s claude -p '/usage' --output-format text --no-session-persistence --safe-mode --tools ''
    """
}

private struct ResetRedemptionKey: Hashable {
    let workerID: UUID
    let creditID: String?
}

private struct CodexEnvelope: Decodable {
    let id: Int?
    let result: CodexResult?
}

private struct CodexResult: Decodable {
    let rateLimits: CodexRateLimitSnapshot?
    let rateLimitResetCredits: CodexRateLimitResetCredits?
    let account: CodexAccount?
    let requiresOpenaiAuth: Bool?
    let outcome: CodexResetConsumeOutcome?
}

private struct CodexRateLimitSnapshot: Decodable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?
    let planType: String?
}

private struct CodexRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
}

private struct CodexAccount: Decodable {
    let email: String?
    let planType: String?
}

private struct ClaudeAuthStatus: Decodable {
    let email: String?
    let subscriptionType: String?
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
