import Foundation

enum WorkerRemoteCommandError: LocalizedError, Equatable {
    case invalidRepositoryName
    case invalidInstanceToken

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryName:
            "The repository name is not safe to use on the worker."
        case .invalidInstanceToken:
            "The worker session identifier is invalid."
        }
    }
}

enum WorkerRemoteCommand {
    static let listProjects = "\(WorkerSessionProtocol.helperPath) list-projects"
    static let status = "\(WorkerSessionProtocol.helperPath) status"
    static let resources = """
        set -eu
        read_cpu() {
          awk '/^cpu / {
            total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
            idle = $5 + $6
            printf "%.0f %.0f\\n", total, idle
            exit
          }' /proc/stat
        }
        cpu_before=$(read_cpu)
        sleep 1
        cpu_after=$(read_cpu)
        set -- $cpu_before
        cpu_total_before=$1
        cpu_idle_before=$2
        set -- $cpu_after
        cpu_total_after=$1
        cpu_idle_after=$2
        cpu_total=$((cpu_total_after - cpu_total_before))
        cpu_idle=$((cpu_idle_after - cpu_idle_before))
        cpu_used=$((cpu_total - cpu_idle))
        set -- $(awk '
          /^MemTotal:/ { total = $2 }
          /^MemAvailable:/ { available = $2 }
          END { print total, available }
        ' /proc/meminfo)
        memory_total=$1
        memory_available=$2
        disk_path=/workspace
        [ -d "$disk_path" ] || disk_path=/
        set -- $(df -Pk "$disk_path" | awk 'NR == 2 { print $2, $3 }')
        printf '%s\\n' '__TERMINAL_RELAY_METRICS_V1__'
        printf 'cpu|%s|%s\\n' "$cpu_used" "$cpu_total"
        printf 'memory|%s|%s\\n' "$memory_total" "$memory_available"
        printf 'disk|%s|%s\\n' "$1" "$2"
        """
    static let codexAccount = """
        cd "$HOME" || exit 1
        { printf '%s\\n' \
        '{"method":"initialize","id":0,"params":{"clientInfo":{"name":"terminal_relay_ios","title":"Terminal Relay","version":"1.0.0"}}}' \
        '{"method":"initialized","params":{}}' \
        '{"method":"account/rateLimits/read","id":1,"params":null}' \
        '{"method":"account/read","id":2,"params":{"refreshToken":false}}'; sleep 2; } \
        | timeout 10s codex app-server 2>/dev/null
        """
    static let claudeAccount = """
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
}
