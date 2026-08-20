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
        accountID: ProviderAccountID? = nil,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "-tt",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3"
        ]
        arguments += multiplexingOptions

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
                accountID: accountID,
                instanceToken: instanceToken
            )
        )

        return SSHLaunchConfiguration(executable: "/usr/bin/ssh", arguments: arguments)
    }

    static func remoteCommand(
        for _: ServerProfile,
        project: ProjectProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        instanceToken: String
    ) -> String {
        let routeArguments: [String]
        if let accountID {
            routeArguments = [
                "reattach-v2",
                kind.rawValue,
                accountID.rawValue,
                project.displayName,
                instanceToken,
            ]
        } else {
            routeArguments = [
                "reattach",
                kind.rawValue,
                project.displayName,
                instanceToken,
            ]
        }
        let sessionCommand = ([WorkerSessionProtocol.helperPath] + routeArguments)
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
            arguments: ["status-v2"]
        )
    }

    static func providerAccountListConfiguration(
        for server: ServerProfile,
        provider: AgentKind? = nil
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["provider-accounts-v1"] + (provider.map { [$0.rawValue] } ?? [])
        )
    }

    static func providerAccountCreateConfiguration(
        for server: ServerProfile,
        provider: AgentKind,
        label: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["provider-account-create-v1", provider.rawValue, label]
        )
    }

    static func providerAccountImportDefaultConfiguration(
        for server: ServerProfile,
        provider: AgentKind,
        label: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: ["provider-account-import-default-v1", provider.rawValue, label]
        )
    }

    static func providerAccountRenameConfiguration(
        for server: ServerProfile,
        account: ProviderAccountProfile,
        label: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                "provider-account-rename-v1",
                account.provider.rawValue,
                account.accountID.rawValue,
                label,
            ]
        )
    }

    static func providerAccountStatusConfiguration(
        for server: ServerProfile,
        account: ProviderAccountProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                "provider-account-status-v1",
                account.provider.rawValue,
                account.accountID.rawValue,
            ]
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
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        let routeArguments = accountID.map {
            ["start-v2", kind.rawValue, $0.rawValue, repositoryName]
        } ?? ["start", kind.rawValue, repositoryName]
        return workerSessionConfiguration(
            for: server,
            arguments: routeArguments + launchDefaults.arguments(for: kind),
            environment: kind == .claude ? ["ConEmuANSI=1"] : []
        )
    }

    static func workerSessionStopConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                ["stop-v2", kind.rawValue, $0.rawValue, repositoryName, instanceToken]
            } ?? ["stop", kind.rawValue, repositoryName, instanceToken]
        )
    }

    static func workerChatCapabilitiesConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                ["chat-capabilities-v2", kind.rawValue, $0.rawValue, repositoryName]
            } ?? ["chat-capabilities-v1", kind.rawValue, repositoryName]
        )
    }

    static func workerChatStartConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String?,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        var arguments = accountID.map {
            ["chat-start-v2", kind.rawValue, $0.rawValue, repositoryName]
        } ?? ["chat-start-v1", kind.rawValue, repositoryName]
        if let threadID {
            arguments.append(threadID)
        }
        arguments += launchDefaults.chatArguments(for: kind)
        return workerSessionConfiguration(for: server, arguments: arguments)
    }

    static func workerChatAttachConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        workerSessionStreamConfiguration(
            for: server,
            arguments: accountID.map {
                [
                    "chat-attach-v2",
                    kind.rawValue,
                    $0.rawValue,
                    repositoryName,
                    instanceToken,
                ]
            } ?? [
                "chat-attach-v1", kind.rawValue, repositoryName, instanceToken,
            ]
        )
    }

    static func workerChatStopConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        instanceToken: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                ["chat-stop-v2", kind.rawValue, $0.rawValue, repositoryName, instanceToken]
            } ?? ["chat-stop-v1", kind.rawValue, repositoryName, instanceToken]
        )
    }

    static func workerThreadListConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        archived: Bool,
        cursor: String? = nil
    ) -> SSHLaunchConfiguration {
        var arguments = accountID.map {
            [
                "threads-v3",
                kind.rawValue,
                $0.rawValue,
                repositoryName,
                archived ? "archived" : "open",
            ]
        } ?? [
            "threads-v2", kind.rawValue, repositoryName,
            archived ? "archived" : "open",
        ]
        if let cursor {
            arguments.append(cursor)
        }
        return workerSessionConfiguration(for: server, arguments: arguments)
    }

    static func workerThreadCreateConfiguration(
        for server: ServerProfile,
        accountID: ProviderAccountID? = nil,
        repositoryName: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                ["thread-create-v2", $0.rawValue, repositoryName]
            } ?? ["thread-create", repositoryName]
        )
    }

    static func workerThreadResumeConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        launchDefaults: AgentLaunchDefaults
    ) -> SSHLaunchConfiguration {
        let routeArguments = accountID.map {
            ["thread-resume-v3", kind.rawValue, $0.rawValue, repositoryName, threadID]
        } ?? ["thread-resume-v2", kind.rawValue, repositoryName, threadID]
        return workerSessionConfiguration(
            for: server,
            arguments: routeArguments + launchDefaults.arguments(for: kind)
        )
    }

    static func workerThreadRenameConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        name: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                [
                    "thread-rename-v3", kind.rawValue, $0.rawValue,
                    repositoryName, threadID, name,
                ]
            } ?? [
                "thread-rename-v2", kind.rawValue, repositoryName, threadID, name,
            ]
        )
    }

    static func workerThreadArchiveConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        unarchive: Bool
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                [
                    unarchive ? "thread-unarchive-v3" : "thread-archive-v3",
                    kind.rawValue, $0.rawValue, repositoryName, threadID,
                ]
            } ?? [
                unarchive ? "thread-unarchive-v2" : "thread-archive-v2",
                kind.rawValue, repositoryName, threadID,
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
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        relayID: String,
        requestID: String,
        attachmentID: String,
        fileExtension: String,
        byteCount: Int
    ) -> SSHLaunchConfiguration {
        workerSessionStreamConfiguration(
            for: server,
            arguments: accountID.map {
                [
                    "chat-attachment-upload-v2", kind.rawValue, $0.rawValue,
                    repositoryName, relayID, requestID, attachmentID,
                    fileExtension, String(byteCount),
                ]
            } ?? [
                "chat-attachment-upload-v1", kind.rawValue, repositoryName,
                relayID, requestID, attachmentID, fileExtension, String(byteCount),
            ]
        )
    }

    static func workerChatAttachmentDeleteConfiguration(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        relayID: String,
        requestID: String
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: accountID.map {
                [
                    "chat-attachment-delete-v2", kind.rawValue, $0.rawValue,
                    repositoryName, relayID, requestID,
                ]
            } ?? [
                "chat-attachment-delete-v1", kind.rawValue, repositoryName,
                relayID, requestID,
            ]
        )
    }

    static func providerAccountUsageConfiguration(
        for server: ServerProfile,
        account: ProviderAccountProfile
    ) -> SSHLaunchConfiguration {
        workerSessionConfiguration(
            for: server,
            arguments: [
                account.provider == .codex ? "codex-account-v2" : "claude-account-v2",
                account.accountID.rawValue,
            ]
        )
    }

    static func codexResetConfiguration(
        for server: ServerProfile,
        accountID: ProviderAccountID,
        idempotencyKey: UUID,
        creditID: String?
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "codex-reset-v2", accountID.rawValue,
            idempotencyKey.uuidString.lowercased(),
        ]
        if let creditID { arguments.append(creditID) }
        return workerSessionConfiguration(for: server, arguments: arguments)
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

    /// Shares one SSH connection across commands to the same worker: a fresh
    /// TCP+auth handshake costs ~0.5s per command while a multiplexed channel
    /// costs ~0.1s, and every sidebar refresh and conversation open pays it.
    /// ControlMaster=auto degrades to a direct connection whenever the master
    /// socket is unavailable, so multiplexing is never a correctness risk.
    /// The path stays short (~/.ssh + hash) because the kernel caps unix
    /// socket paths at 104 bytes.
    private static var multiplexingOptions: [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=~/.ssh/tr-mux-%C",
            "-o", "ControlPersist=60"
        ]
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
        arguments += multiplexingOptions
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
