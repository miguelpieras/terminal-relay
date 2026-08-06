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

    static func workerRuntimeInfoConfiguration(
        for server: ServerProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(for: server, arguments: ["runtime-info"])
    }

    static func workerRuntimeUpdateStatusConfiguration(
        for server: ServerProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(for: server, arguments: ["runtime-update-status"])
    }

    static func workerRuntimeUpdateRequestConfiguration(
        for server: ServerProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(for: server, arguments: ["runtime-update-request"])
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

    static func workerChatCapabilitiesConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["chat-capabilities-v1", kind.rawValue, repositoryName]
        )
    }

    static func workerChatStartConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        threadID: String?,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        var arguments = ["chat-start-v1", kind.rawValue, repositoryName]
        if let threadID {
            arguments.append(threadID)
        }
        arguments += launchDefaults.chatArguments(for: kind)
        return workerSessionConfiguration(for: server, arguments: arguments)
    }

    static func workerChatAttachConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        workerSessionStreamConfiguration(
            for: server,
            arguments: [
                "chat-attach-v1",
                kind.rawValue,
                repositoryName,
                instanceToken,
            ]
        )
    }

    static func workerChatStopConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["chat-stop-v1", kind.rawValue, repositoryName, instanceToken]
        )
    }

    static func workerThreadListConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        archived: Bool,
        cursor: String? = nil
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "threads-v2",
            kind.rawValue,
            repositoryName,
            archived ? "archived" : "open",
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
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["thread-resume-v2", kind.rawValue, repositoryName, threadID]
                + launchDefaults.arguments(for: kind)
        )
    }

    static func workerThreadRenameConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        name: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                "thread-rename-v2",
                kind.rawValue,
                repositoryName,
                threadID,
                name,
            ]
        )
    }

    static func workerThreadArchiveConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        unarchive: Bool
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                unarchive ? "thread-unarchive-v2" : "thread-archive-v2",
                kind.rawValue,
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

    static func workerChatAttachmentUploadConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        relayID: String,
        requestID: String,
        attachmentID: String,
        fileExtension: String,
        byteCount: Int
    ) -> SSHLaunchConfiguration {
        workerSessionStreamConfiguration(
            for: server,
            arguments: [
                "chat-attachment-upload-v1",
                kind.rawValue,
                repositoryName,
                relayID,
                requestID,
                attachmentID,
                fileExtension,
                String(byteCount),
            ]
        )
    }

    static func workerChatAttachmentDeleteConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        repositoryName: String,
        relayID: String,
        requestID: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                "chat-attachment-delete-v1",
                kind.rawValue,
                repositoryName,
                relayID,
                requestID,
            ]
        )
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

    private static func workerSessionStreamConfiguration(
        for server: ServerProfile,
        arguments remoteArguments: [String]
    ) -> SSHLaunchConfiguration {
        let remoteCommand = ([WorkerSessionProtocol.helperPath] + remoteArguments)
            .map(shellQuote)
            .joined(separator: " ")
        return batchConfiguration(
            for: server,
            remoteCommand: remoteCommand,
            disablesPTY: true
        )
    }

    private static func batchConfiguration(
        for server: ServerProfile,
        remoteCommand: String,
        disablesPTY: Bool = false
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]
        if disablesPTY {
            arguments.append("-T")
        }

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
