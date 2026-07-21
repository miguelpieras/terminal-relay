import Foundation

struct SSHLaunchConfiguration: Equatable {
    let executable: String
    let arguments: [String]
}

enum SSHCommandBuilder {
    static func configuration(
        for server: ServerProfile,
        project: ProjectProfile,
        kind: AgentKind,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "-tt",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]

        if server.port != 22 {
            arguments += ["-p", String(server.port)]
        }

        let identityFile = server.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identityFile.isEmpty {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        arguments.append(server.destination)
        arguments.append(
            remoteCommand(
                for: server,
                project: project,
                kind: kind,
                launchDefaults: launchDefaults
            )
        )

        return SSHLaunchConfiguration(executable: "/usr/bin/ssh", arguments: arguments)
    }

    static func remoteCommand(
        for server: ServerProfile,
        project: ProjectProfile,
        kind: AgentKind,
        launchDefaults: AgentLaunchDefaults
    ) -> String {
        let command = server.command(for: kind).trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = project.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchArguments = launchDefaults.arguments(for: kind)
            .map(shellQuote)
            .joined(separator: " ")
        let launchCommand = "\(command) \(launchArguments)"

        let payload: String
        if directory.isEmpty {
            payload = "exec \(launchCommand)"
        } else {
            payload = "cd -- \(shellQuote(directory)) && exec \(launchCommand)"
        }

        return "exec \"${SHELL:-/bin/sh}\" -lic \(shellQuote(payload))"
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
