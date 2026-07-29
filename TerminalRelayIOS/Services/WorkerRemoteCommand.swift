import Foundation

enum WorkerRemoteCommandError: LocalizedError, Equatable {
    case invalidRepositoryName
    case invalidInstanceToken
    case invalidThreadName

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryName:
            "The repository name is not safe to use on the worker."
        case .invalidInstanceToken:
            "The worker session identifier is invalid."
        case .invalidThreadName:
            "The thread name is invalid."
        }
    }
}

enum WorkerRemoteCommand {
    static let listProjects = "\(WorkerSessionProtocol.helperPath) list-projects"
    static let status = "\(WorkerSessionProtocol.helperPath) status"
    static let updateStatus = "\(WorkerSessionProtocol.helperPath) update-status"
    static let resources = "\(WorkerSessionProtocol.helperPath) resources"
    static let codexAccount = "\(WorkerSessionProtocol.helperPath) codex-account"
    static let claudeAccount = "\(WorkerSessionProtocol.helperPath) claude-account"

    static let legacyResources = """
        set -eu

        exporter_address=$(/usr/bin/tailscale ip -4 | /usr/bin/awk 'NR == 1 { print; exit }')
        [ -n "$exporter_address" ]

        read_metrics() {
          /usr/bin/curl --fail --silent --show-error --max-time 3 \
            "http://$exporter_address:9100/metrics" \
            | /usr/bin/awk '
              index($1, "node_cpu_seconds_total{") == 1 \
                  && $1 !~ /mode="guest"/ \
                  && $1 !~ /mode="guest_nice"/ {
                cpu_total += $2
                if ($1 ~ /mode="idle"/ || $1 ~ /mode="iowait"/) {
                  cpu_idle += $2
                }
              }
              $1 == "node_memory_MemTotal_bytes" {
                memory_total = $2
              }
              $1 == "node_memory_MemAvailable_bytes" {
                memory_available = $2
              }
              index($1, "node_filesystem_size_bytes{") == 1 \
                  && $1 ~ /mountpoint="\\/"}/ {
                disk_total = $2
              }
              index($1, "node_filesystem_free_bytes{") == 1 \
                  && $1 ~ /mountpoint="\\/"}/ {
                disk_free = $2
              }
              END {
                if (cpu_total <= 0 || cpu_idle < 0 || cpu_idle > cpu_total \
                    || memory_total <= 0 || memory_available < 0 \
                    || memory_available > memory_total || disk_total <= 0 \
                    || disk_free < 0 || disk_free > disk_total) {
                  exit 1
                }
                printf "%.0f %.0f %.0f %.0f %.0f %.0f\\n", \
                  cpu_total * 100, cpu_idle * 100, \
                  memory_total / 1024, memory_available / 1024, \
                  disk_total / 1024, (disk_total - disk_free) / 1024
              }
            '
        }

        metrics_before=$(read_metrics)
        /bin/sleep 2
        metrics_after=$(read_metrics)

        set -- $metrics_before
        cpu_total_before=$1
        cpu_idle_before=$2
        set -- $metrics_after
        cpu_total_after=$1
        cpu_idle_after=$2
        memory_total=$3
        memory_available=$4
        disk_total=$5
        disk_used=$6
        cpu_total=$((cpu_total_after - cpu_total_before))
        cpu_idle=$((cpu_idle_after - cpu_idle_before))
        cpu_used=$((cpu_total - cpu_idle))

        [ "$cpu_total" -gt 0 ]
        [ "$cpu_idle" -ge 0 ]
        [ "$cpu_idle" -le "$cpu_total" ]

        printf '%s\\n' '__TERMINAL_RELAY_METRICS_V1__'
        printf 'cpu|%s|%s\\n' "$cpu_used" "$cpu_total"
        printf 'memory|%s|%s\\n' "$memory_total" "$memory_available"
        printf 'disk|%s|%s\\n' "$disk_total" "$disk_used"
        """
    static let legacyCodexAccount = """
        cd "$HOME" || exit 1
        { printf '%s\\n' \
        '{"method":"initialize","id":0,"params":{"clientInfo":{"name":"terminal_relay_ios","title":"Terminal Relay","version":"1.0.0"}}}' \
        '{"method":"initialized","params":{}}' \
        '{"method":"account/rateLimits/read","id":1,"params":null}' \
        '{"method":"account/read","id":2,"params":{"refreshToken":false}}'; sleep 2; } \
        | timeout 10s codex app-server 2>/dev/null
        """
    static let legacyClaudeAccount = """
        cd "$HOME" || exit 1
        printf '%s\\n' '__TERMINAL_RELAY_CLAUDE_AUTH__'
        claude auth status --json 2>/dev/null || true
        printf '%s\\n' '__TERMINAL_RELAY_CLAUDE_USAGE__'
        DISABLE_AUTOUPDATER=1 timeout 20s claude -p '/usage' --output-format text \
          --no-session-persistence --safe-mode --tools ''
        """

    static func start(
        kind: AgentKind,
        repositoryName: String,
        launchArguments: [String]
    ) throws -> String {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerRemoteCommandError.invalidRepositoryName
        }

        let workingDirectory = "/workspace/\(repositoryName)"
        let command = [
            WorkerSessionProtocol.helperPath,
            "start",
            kind.rawValue,
            repositoryName,
        ] + launchArguments

        return "cd -- \(shellQuote(workingDirectory)) && exec \(command.map(shellQuote).joined(separator: " "))"
    }

    static func reattach(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) throws -> String {
        try validateSessionIdentity(
            repositoryName: repositoryName,
            instanceToken: instanceToken
        )

        let command = [
            WorkerSessionProtocol.helperPath,
            "reattach",
            kind.rawValue,
            repositoryName,
            instanceToken,
        ]
        return "exec \(command.map(shellQuote).joined(separator: " "))"
    }

    static func stop(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) throws -> String {
        try validateSessionIdentity(
            repositoryName: repositoryName,
            instanceToken: instanceToken
        )

        let arguments = [kind.rawValue, repositoryName, instanceToken]
            .map(shellQuote)
            .joined(separator: " ")
        return "\(WorkerSessionProtocol.helperPath) stop \(arguments)"
    }

    static func threads(
        kind: AgentKind,
        repositoryName: String,
        archived: Bool,
        cursor: String? = nil
    ) throws -> String {
        try validateRepository(repositoryName)
        var arguments = [
            WorkerSessionProtocol.helperPath,
            "threads-v2",
            kind.rawValue,
            repositoryName,
            archived ? "archived" : "open",
        ]
        if let cursor {
            arguments.append(cursor)
        }
        return arguments.map(shellQuote).joined(separator: " ")
    }

    static func createThread(repositoryName: String) throws -> String {
        try validateRepository(repositoryName)
        return [
            WorkerSessionProtocol.helperPath,
            "thread-create",
            repositoryName,
        ].map(shellQuote).joined(separator: " ")
    }

    static func resumeThread(
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        launchArguments: [String]
    ) throws -> String {
        try validateThread(repositoryName: repositoryName, threadID: threadID)
        return ([
            WorkerSessionProtocol.helperPath,
            "thread-resume-v2",
            kind.rawValue,
            repositoryName,
            threadID,
        ] + launchArguments).map(shellQuote).joined(separator: " ")
    }

    static func renameThread(
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        name: String
    ) throws -> String {
        try validateThread(repositoryName: repositoryName, threadID: threadID)
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains("\n"),
              normalized.utf8.count <= 200 else {
            throw WorkerRemoteCommandError.invalidThreadName
        }
        return [
            WorkerSessionProtocol.helperPath,
            "thread-rename-v2",
            kind.rawValue,
            repositoryName,
            threadID,
            normalized,
        ].map(shellQuote).joined(separator: " ")
    }

    static func archiveThread(
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        unarchive: Bool
    ) throws -> String {
        try validateThread(repositoryName: repositoryName, threadID: threadID)
        return [
            WorkerSessionProtocol.helperPath,
            unarchive ? "thread-unarchive-v2" : "thread-archive-v2",
            kind.rawValue,
            repositoryName,
            threadID,
        ].map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func validateSessionIdentity(
        repositoryName: String,
        instanceToken: String
    ) throws {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerRemoteCommandError.invalidRepositoryName
        }
        guard UUID(uuidString: instanceToken)?.uuidString.lowercased() == instanceToken else {
            throw WorkerRemoteCommandError.invalidInstanceToken
        }
    }

    private static func validateRepository(_ repositoryName: String) throws {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerRemoteCommandError.invalidRepositoryName
        }
    }

    private static func validateThread(
        repositoryName: String,
        threadID: String
    ) throws {
        try validateRepository(repositoryName)
        guard UUID(uuidString: threadID)?.uuidString.lowercased() == threadID else {
            throw WorkerRemoteCommandError.invalidInstanceToken
        }
    }
}
