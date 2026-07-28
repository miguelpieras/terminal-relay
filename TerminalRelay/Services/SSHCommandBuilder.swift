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
        instanceToken: String
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
                instanceToken: instanceToken
            )
        )

        return SSHLaunchConfiguration(executable: "/usr/bin/ssh", arguments: arguments)
    }

    static func remoteCommand(
        for _: ServerProfile,
        project: ProjectProfile,
        kind: AgentKind,
        instanceToken: String
    ) -> String {
        let sessionCommand = [
            WorkerSessionProtocol.helperPath,
            "reattach",
            kind.rawValue,
            project.displayName,
            instanceToken
        ]
            .map(shellQuote)
            .joined(separator: " ")
        let payload = "exec \(sessionCommand)"

        return "exec \"${SHELL:-/bin/sh}\" -lic \(shellQuote(payload))"
    }

    static func workerSessionStatusConfiguration(
        for server: ServerProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["status"]
        )
    }

    static func workerUpdateStatusConfiguration(
        for server: ServerProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["update-status"]
        )
    }

    static func workerSessionStartConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        let arguments = ["start", kind.rawValue, repositoryName]
            + launchDefaults.arguments(for: kind)
        return workerSessionConfiguration(
            for: server,
            arguments: arguments,
            environment: kind == .claude ? ["ConEmuANSI=1"] : []
        )
    }

    static func workerSessionStopConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["stop", kind.rawValue, repositoryName, instanceToken]
        )
    }

    static func workerThreadListConfiguration(
        for server: ServerProfile,
        repositoryName: String,
        archived: Bool,
        cursor: String? = nil
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "threads",
            repositoryName,
            archived ? "archived" : "active",
        ]
        if let cursor {
            arguments.append(cursor)
        }
        return workerSessionConfiguration(for: server, arguments: arguments)
    }

    static func workerThreadCreateConfiguration(
        for server: ServerProfile,
        repositoryName: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["thread-create", repositoryName]
        )
    }

    static func workerThreadResumeConfiguration(
        for server: ServerProfile,
        repositoryName: String,
        threadID: String,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["thread-resume", repositoryName, threadID]
                + launchDefaults.arguments(for: .codex)
        )
    }

    static func workerThreadRenameConfiguration(
        for server: ServerProfile,
        repositoryName: String,
        threadID: String,
        name: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["thread-rename", repositoryName, threadID, name]
        )
    }

    static func workerThreadArchiveConfiguration(
        for server: ServerProfile,
        repositoryName: String,
        threadID: String,
        unarchive: Bool
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                unarchive ? "thread-unarchive" : "thread-archive",
                repositoryName,
                threadID,
            ]
        )
    }

    static func attachmentUploadConfiguration(
        for server: ServerProfile,
        instanceToken: String,
        fileName: String
    ) -> SSHLaunchConfiguration {
        let script = """
        set -eu
        umask 077
        attachment_directory="${HOME:?}/.terminal-relay/attachments/\(instanceToken)"
        attachment_path="$attachment_directory/\(fileName)"
        mkdir -p -- "$attachment_directory"
        cat > "$attachment_path"
        printf '%s' "$attachment_path"
        """
        let remoteCommand = ["/bin/sh", "-c", script]
            .map(shellQuote)
            .joined(separator: " ")
        return batchConfiguration(for: server, remoteCommand: remoteCommand)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func workerSessionConfiguration(
        for server: ServerProfile,
        arguments remoteArguments: [String],
        environment: [String] = []
    ) -> SSHLaunchConfiguration {
        let remoteCommand = (
            (environment.isEmpty ? [] : ["/usr/bin/env"] + environment)
                + [WorkerSessionProtocol.helperPath]
                + remoteArguments
        )
            .map(shellQuote)
            .joined(separator: " ")
        return batchConfiguration(for: server, remoteCommand: remoteCommand)
    }

    private static func batchConfiguration(
        for server: ServerProfile,
        remoteCommand: String
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]

        if server.port != 22 {
            arguments += ["-p", String(server.port)]
        }

        let identityFile = server.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identityFile.isEmpty {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        arguments.append("--")
        arguments.append(server.destination)
        arguments.append(remoteCommand)

        return SSHLaunchConfiguration(executable: "/usr/bin/ssh", arguments: arguments)
    }
}
