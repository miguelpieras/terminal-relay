import Foundation

struct ServerProfile: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var identityFile: String
    var workingDirectory: String
    var codexAccountLabel: String
    var claudeAccountLabel: String
    var codexCommand: String
    var claudeCommand: String

    init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 22,
        username: String = "",
        identityFile: String = "",
        workingDirectory: String = "",
        codexAccountLabel: String = "",
        claudeAccountLabel: String = "",
        codexCommand: String = AgentKind.codex.defaultCommand,
        claudeCommand: String = AgentKind.claude.defaultCommand
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.workingDirectory = workingDirectory
        self.codexAccountLabel = codexAccountLabel
        self.claudeAccountLabel = claudeAccountLabel
        self.codexCommand = codexCommand
        self.claudeCommand = claudeCommand
    }

    var displayName: String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? host : value
    }

    var destination: String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        return username.isEmpty ? host : "\(username)@\(host)"
    }

    var concurrencyKey: String {
        let normalizedUsername = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        while normalizedHost.hasSuffix(".") {
            normalizedHost.removeLast()
        }

        if normalizedHost.hasSuffix(".ts.net"), let shortName = normalizedHost.split(separator: ".").first {
            normalizedHost = String(shortName)
        }

        return "\(normalizedUsername)@\(normalizedHost):\(port)"
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (1...65_535).contains(port)
            && !codexCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !claudeCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func accountLabel(for kind: AgentKind) -> String {
        let label: String
        switch kind {
        case .codex: label = codexAccountLabel
        case .claude: label = claudeAccountLabel
        }

        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Default account" : trimmed
    }

    func command(for kind: AgentKind) -> String {
        switch kind {
        case .codex: codexCommand
        case .claude: claudeCommand
        }
    }
}
