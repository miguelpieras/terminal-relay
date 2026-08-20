import XCTest
@testable import TerminalRelay

final class SSHCommandBuilderTests: XCTestCase {
    private let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"

    func testConfigurationBuildsSSHArgumentsInRequiredOrder() {
        let server = makeServer(
            port: 2_222,
            identityFile: "~/Keys/agent key"
        )
        let project = makeProject(server: server, repositoryName: "terminal-relay")

        let configuration = SSHCommandBuilder.configuration(
            for: server,
            project: project,
            kind: .codex,
            instanceToken: instanceToken
        )
        let remoteCommand = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .codex,
            instanceToken: instanceToken
        )

        XCTAssertEqual(configuration.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            configuration.arguments,
            [
                "-tt",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/tr-mux-%C",
                "-o", "ControlPersist=60",
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "developer@example.com",
                remoteCommand
            ]
        )
    }

    func testConfigurationOmitsBlankIdentityFile() {
        let server = makeServer(identityFile: "  \n ")
        let project = makeProject(server: server)

        let configuration = SSHCommandBuilder.configuration(
            for: server,
            project: project,
            kind: .claude,
            instanceToken: instanceToken
        )

        XCTAssertFalse(configuration.arguments.contains("-i"))
        XCTAssertEqual(configuration.arguments.suffix(2), [
            "developer@example.com",
            SSHCommandBuilder.remoteCommand(
                for: server,
                project: project,
                kind: .claude,
                instanceToken: instanceToken
            )
        ])
    }

    func testDefaultPortDoesNotOverrideSSHConfig() {
        let server = makeServer(port: 22)
        let project = makeProject(server: server)

        let configuration = SSHCommandBuilder.configuration(
            for: server,
            project: project,
            kind: .codex,
            instanceToken: instanceToken
        )

        XCTAssertFalse(configuration.arguments.contains("-p"))
    }

    func testPTYRemoteCommandAlwaysReattachesTheExactConfirmedInstance() {
        let server = makeServer(codexCommand: "printf should-not-run")
        let project = makeProject(server: server, repositoryName: "relay's repo")

        for kind in AgentKind.allCases {
            let command = SSHCommandBuilder.remoteCommand(
                for: server,
                project: project,
                kind: kind,
                instanceToken: instanceToken
            )
            let configuration = SSHCommandBuilder.configuration(
                for: server,
                project: project,
                kind: kind,
                instanceToken: instanceToken
            )

            XCTAssertEqual(
                command,
                expectedReattachRemoteCommand(
                    project: project,
                    kind: kind,
                    instanceToken: instanceToken
                )
            )
            XCTAssertEqual(configuration.arguments.suffix(2), [server.destination, command])
            XCTAssertTrue(command.contains("'reattach'"))
            XCTAssertTrue(command.contains(SSHCommandBuilder.shellQuote(instanceToken)))
            XCTAssertFalse(command.contains("'attach'"))
            XCTAssertFalse(command.contains("printf should-not-run"))
            XCTAssertFalse(command.contains("ConEmuANSI=1"))
            for argument in AgentLaunchDefaults.standard.arguments(for: kind) {
                XCTAssertFalse(command.contains(SSHCommandBuilder.shellQuote(argument)))
            }
        }
    }

    func testWorkerSessionStatusUsesNoninteractiveSSHAndFixedHelper() {
        let server = makeServer(port: 2_222, identityFile: "~/Keys/agent key")

        let configuration = SSHCommandBuilder.workerSessionStatusConfiguration(for: server)

        XCTAssertEqual(configuration.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            configuration.arguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/tr-mux-%C",
                "-o", "ControlPersist=60",
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "--",
                "developer@example.com",
                "'/usr/local/bin/terminal-relay-session' 'status-v2'"
            ]
        )
        XCTAssertFalse(configuration.arguments.contains("-tt"))
    }

    func testWorkerUpdateStatusUsesNoninteractiveSSHAndFixedHelper() {
        let server = makeServer(port: 2_222, identityFile: "~/Keys/agent key")

        let configuration = SSHCommandBuilder.workerUpdateStatusConfiguration(for: server)

        XCTAssertEqual(configuration.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            configuration.arguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/tr-mux-%C",
                "-o", "ControlPersist=60",
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "--",
                "developer@example.com",
                "'/usr/local/bin/terminal-relay-session' 'update-status'"
            ]
        )
        XCTAssertFalse(configuration.arguments.contains("-tt"))
    }

    func testWorkerRuntimeCommandsUseFixedTypedHelperOperations() {
        let server = makeServer(port: 2_222, identityFile: "~/Keys/agent key")
        let info = SSHCommandBuilder.workerRuntimeInfoConfiguration(for: server)
        let status = SSHCommandBuilder.workerRuntimeUpdateStatusConfiguration(for: server)
        let request = SSHCommandBuilder.workerRuntimeUpdateRequestConfiguration(for: server)

        XCTAssertEqual(info.arguments.last, "'/usr/local/bin/terminal-relay-session' 'runtime-info'")
        XCTAssertEqual(
            status.arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'runtime-update-status'"
        )
        XCTAssertEqual(
            request.arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'runtime-update-request'"
        )
    }

    func testWorkerSessionStartPassesCodexDefaultsToFixedHelper() {
        let server = makeServer(codexCommand: "printf should-not-run")
        let defaults = AgentLaunchDefaults(
            codexModel: "custom codex",
            codexReasoningEffort: .high,
            claudeModel: "unused",
            claudeReasoningEffort: .low,
            fullAccessEnabled: true
        )

        let configuration = SSHCommandBuilder.workerSessionStartConfiguration(
            for: server,
            kind: .codex,
            repositoryName: "relay's repo",
            launchDefaults: defaults
        )

        XCTAssertEqual(
            configuration.arguments.suffix(3),
            [
                "--",
                server.destination,
                expectedStartRemoteCommand(
                    kind: .codex,
                    repositoryName: "relay's repo",
                    defaults: defaults
                )
            ]
        )
        XCTAssertFalse(configuration.arguments.contains("-tt"))
        XCTAssertFalse(configuration.arguments.last?.contains("printf should-not-run") == true)
        XCTAssertFalse(configuration.arguments.last?.contains("'/usr/bin/env'") == true)
    }

    func testWorkerSessionStartSetsClaudeEnvironmentAndQuotesArguments() throws {
        let server = makeServer()
        let defaults = AgentLaunchDefaults(
            codexModel: "unused",
            codexReasoningEffort: .low,
            claudeModel: "custom'claude",
            claudeReasoningEffort: .xhigh,
            fullAccessEnabled: true
        )

        let configuration = SSHCommandBuilder.workerSessionStartConfiguration(
            for: server,
            kind: .claude,
            repositoryName: "relay's repo",
            launchDefaults: defaults
        )
        let remoteCommand = try XCTUnwrap(configuration.arguments.last)

        XCTAssertEqual(
            remoteCommand,
            expectedStartRemoteCommand(
                kind: .claude,
                repositoryName: "relay's repo",
                defaults: defaults
            )
        )
        XCTAssertTrue(
            remoteCommand.hasPrefix(
                "'/usr/bin/env' 'ConEmuANSI=1' '/usr/local/bin/terminal-relay-session' "
            )
        )
        XCTAssertTrue(remoteCommand.contains("'start' 'claude' 'relay'\"'\"'s repo'"))
        XCTAssertTrue(remoteCommand.contains("'custom'\"'\"'claude'"))
        XCTAssertFalse(configuration.arguments.contains("-tt"))
    }

    func testWorkerSessionStopPassesKindRepositoryAndInstanceToken() {
        let server = makeServer()

        let configuration = SSHCommandBuilder.workerSessionStopConfiguration(
            for: server,
            kind: .claude,
            repositoryName: "terminal-relay",
            instanceToken: instanceToken
        )

        XCTAssertEqual(
            configuration.arguments.suffix(3),
            [
                "--",
                "developer@example.com",
                "'/usr/local/bin/terminal-relay-session' 'stop' 'claude' 'terminal-relay' '\(instanceToken)'"
            ]
        )
        XCTAssertFalse(configuration.arguments.contains("-tt"))
    }

    func testChatCommandsUseFixedHelperExactIdentityAndNonPTYStreaming() throws {
        let server = makeServer(port: 2_222, identityFile: "~/Keys/agent key")
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let defaults = AgentLaunchDefaults(
            codexModel: "custom model",
            codexReasoningEffort: .high,
            claudeModel: "unused",
            claudeReasoningEffort: .low,
            fullAccessEnabled: false
        )

        XCTAssertEqual(
            SSHCommandBuilder.workerChatCapabilitiesConfiguration(
                for: server,
                kind: .codex,
                repositoryName: "relay's repo"
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-capabilities-v1' 'codex' 'relay'\"'\"'s repo'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerChatStartConfiguration(
                for: server,
                kind: .codex,
                repositoryName: "terminal-relay",
                threadID: threadID,
                launchDefaults: defaults
            ).arguments.last,
            (
                [
                    WorkerSessionProtocol.helperPath,
                    "chat-start-v1",
                    "codex",
                    "terminal-relay",
                    threadID,
                ] + defaults.chatArguments(for: .codex)
            ).map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        )
        let attach = SSHCommandBuilder.workerChatAttachConfiguration(
            for: server,
            kind: .codex,
            repositoryName: "terminal-relay",
            instanceToken: instanceToken
        )
        XCTAssertTrue(attach.arguments.contains("-T"))
        XCTAssertFalse(attach.arguments.contains("-tt"))
        XCTAssertEqual(
            attach.arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-attach-v1' 'codex' 'terminal-relay' '\(instanceToken)'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerChatStopConfiguration(
                for: server,
                kind: .codex,
                repositoryName: "terminal-relay",
                instanceToken: instanceToken
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-stop-v1' 'codex' 'terminal-relay' '\(instanceToken)'"
        )
        let requestID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let attachmentID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let upload = SSHCommandBuilder.workerChatAttachmentUploadConfiguration(
            for: server,
            kind: .codex,
            repositoryName: "terminal-relay",
            relayID: instanceToken,
            requestID: requestID,
            attachmentID: attachmentID,
            fileExtension: "pdf",
            byteCount: 4_096
        )
        XCTAssertTrue(upload.arguments.contains("-T"))
        XCTAssertFalse(upload.arguments.contains("-tt"))
        XCTAssertEqual(
            upload.arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-attachment-upload-v1' 'codex' 'terminal-relay' '\(instanceToken)' '\(requestID)' '\(attachmentID)' 'pdf' '4096'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerChatAttachmentDeleteConfiguration(
                for: server,
                kind: .codex,
                repositoryName: "terminal-relay",
                relayID: instanceToken,
                requestID: requestID
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-attachment-delete-v1' 'codex' 'terminal-relay' '\(instanceToken)' '\(requestID)'"
        )
    }

    func testNewChatStartOmitsProviderThreadIdentity() {
        let server = makeServer()

        let command = SSHCommandBuilder.workerChatStartConfiguration(
            for: server,
            kind: .claude,
            repositoryName: "terminal-relay",
            threadID: nil,
            launchDefaults: .standard
        ).arguments.last

        XCTAssertEqual(
            command,
            (
                [
                    WorkerSessionProtocol.helperPath,
                    "chat-start-v1",
                    "claude",
                    "terminal-relay",
                ] + AgentLaunchDefaults.standard.chatArguments(for: .claude)
            ).map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        )
    }

    func testAccountAwareCommandsUseOnlyExplicitVersionedRoutes() {
        let server = makeServer()
        let project = makeProject(server: server)
        let accountID = ProviderAccountID(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )

        let reattach = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .claude,
            accountID: accountID,
            instanceToken: instanceToken
        )
        let routedReattach = [
            WorkerSessionProtocol.helperPath,
            "reattach-v2",
            "claude",
            accountID.rawValue,
            "terminal-relay",
            instanceToken,
        ].map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        XCTAssertEqual(
            reattach,
            "exec \"${SHELL:-/bin/sh}\" -lic "
                + SSHCommandBuilder.shellQuote("exec \(routedReattach)")
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerChatCapabilitiesConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay"
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-capabilities-v2' 'claude' '\(accountID.rawValue)' 'terminal-relay'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerChatAttachConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay",
                instanceToken: instanceToken
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-attach-v2' 'claude' '\(accountID.rawValue)' 'terminal-relay' '\(instanceToken)'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadListConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay",
                archived: false
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'threads-v3' 'claude' '\(accountID.rawValue)' 'terminal-relay' 'open'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadCreateConfiguration(
                for: server,
                accountID: accountID,
                repositoryName: "terminal-relay"
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'thread-create-v2' '\(accountID.rawValue)' 'terminal-relay'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerSessionStartConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay",
                launchDefaults: .standard
            ).arguments.last,
            ([
                "/usr/bin/env",
                "ConEmuANSI=1",
                WorkerSessionProtocol.helperPath,
                "start-v2",
                "claude",
                accountID.rawValue,
                "terminal-relay",
            ] + AgentLaunchDefaults.standard.arguments(for: .claude))
                .map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadResumeConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay",
                threadID: instanceToken,
                launchDefaults: .standard
            ).arguments.last,
            ([
                WorkerSessionProtocol.helperPath,
                "thread-resume-v3",
                "claude",
                accountID.rawValue,
                "terminal-relay",
                instanceToken,
            ] + AgentLaunchDefaults.standard.arguments(for: .claude))
                .map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadRenameConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay",
                threadID: instanceToken,
                name: "Renamed"
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'thread-rename-v3' 'claude' '\(accountID.rawValue)' 'terminal-relay' '\(instanceToken)' 'Renamed'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadArchiveConfiguration(
                for: server,
                kind: .claude,
                accountID: accountID,
                repositoryName: "terminal-relay",
                threadID: instanceToken,
                unarchive: false
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'thread-archive-v3' 'claude' '\(accountID.rawValue)' 'terminal-relay' '\(instanceToken)'"
        )
    }

    func testAttachmentUploadUsesPrivateSessionDirectoryAndStandardSSHOptions() throws {
        let server = makeServer(port: 2_222, identityFile: "~/Keys/agent key")
        let configuration = SSHCommandBuilder.attachmentUploadConfiguration(
            for: server,
            instanceToken: instanceToken,
            fileName: "clipboard.png"
        )
        let remoteCommand = try XCTUnwrap(configuration.arguments.last)

        XCTAssertEqual(configuration.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            configuration.arguments.dropLast(),
            [
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=5",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=accept-new",
                "-o", "ControlMaster=auto",
                "-o", "ControlPath=~/.ssh/tr-mux-%C",
                "-o", "ControlPersist=60",
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "--",
                server.destination
            ]
        )
        XCTAssertTrue(remoteCommand.hasPrefix("'/bin/sh' '-c' "))
        XCTAssertTrue(remoteCommand.contains(".terminal-relay/attachments/\(instanceToken)"))
        XCTAssertTrue(remoteCommand.contains("clipboard.png"))
        XCTAssertTrue(remoteCommand.contains("umask 077"))
        XCTAssertFalse(configuration.arguments.contains("-tt"))
    }

    func testSubprocessCanStreamStandardInput() async throws {
        let input = Data("clipboard image bytes".utf8)

        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            standardInput: input
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.standardOutput, input)
        XCTAssertTrue(result.standardError.isEmpty)
    }

    func testShellQuoteProtectsSingleQuotes() {
        XCTAssertEqual(SSHCommandBuilder.shellQuote("plain text"), "'plain text'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("it's safe"), "'it'\"'\"'s safe'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote(""), "''")
    }

    func testBlankModelNamesUseProductionDefaults() {
        let defaults = AgentLaunchDefaults(
            codexModel: " \n ",
            codexReasoningEffort: .max,
            claudeModel: "\t",
            claudeReasoningEffort: .max,
            fullAccessEnabled: true
        )

        XCTAssertEqual(defaults.codexModel, "gpt-5.6-sol")
        XCTAssertEqual(defaults.claudeModel, "fable")
    }

    func testStandardDefaultsEnableFullAccessForBothAgents() {
        XCTAssertTrue(
            AgentLaunchDefaults.standard.arguments(for: .codex)
                .contains("--dangerously-bypass-approvals-and-sandbox")
        )
        XCTAssertTrue(
            AgentLaunchDefaults.standard.arguments(for: .claude)
                .contains("--dangerously-skip-permissions")
        )
    }

    func testNativeChatDefaultsUseOnlyNegotiatedOptions() {
        XCTAssertEqual(
            AgentLaunchDefaults.standard.chatArguments(for: .codex),
            ["--model", "gpt-5.6-sol", "--effort", "max", "--full-access"]
        )
        XCTAssertEqual(
            AgentLaunchDefaults.standard.chatArguments(for: .claude),
            ["--model", "fable", "--effort", "max", "--full-access"]
        )
    }

    func testStandardDefaultsRequestNativeActivitySignals() {
        XCTAssertTrue(
            AgentLaunchDefaults.standard.arguments(for: .codex)
                .contains("tui.terminal_title=[\"thread-title\",\"run-state\"]")
        )
        XCTAssertTrue(
            AgentLaunchDefaults.standard.arguments(for: .claude)
                .contains("{\"terminalProgressBarEnabled\":true}")
        )
        XCTAssertTrue(
            AgentLaunchDefaults.standard.arguments(for: .claude)
                .contains("--strict-mcp-config")
        )
        XCTAssertTrue(
            AgentLaunchDefaults.standard.arguments(for: .claude)
                .contains(
                    "{\"mcpServers\":{\"terminal_relay\":{\"command\":\"/usr/local/bin/terminal-relay-mcp\"}}}"
                )
        )
    }

    func testThreadCommandsUseTheFixedHelperAndQuoteDynamicValues() {
        let server = makeServer()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        XCTAssertEqual(
            SSHCommandBuilder.workerThreadListConfiguration(
                for: server,
                kind: .claude,
                repositoryName: "relay's repo",
                archived: true,
                cursor: "next page"
            ).arguments.suffix(3),
            [
                "--",
                server.destination,
                "'/usr/local/bin/terminal-relay-session' 'threads-v2' 'claude' 'relay'\"'\"'s repo' 'archived' 'next page'"
            ]
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadResumeConfiguration(
                for: server,
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                launchDefaults: .standard
            ).arguments.last,
            (
                [WorkerSessionProtocol.helperPath, "thread-resume-v2", "claude", "terminal-relay", threadID]
                    + AgentLaunchDefaults.standard.arguments(for: .claude)
            ).map(SSHCommandBuilder.shellQuote).joined(separator: " ")
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadRenameConfiguration(
                for: server,
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                name: "It's renamed"
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'thread-rename-v2' 'claude' 'terminal-relay' '\(threadID)' 'It'\"'\"'s renamed'"
        )
        XCTAssertEqual(
            SSHCommandBuilder.workerThreadArchiveConfiguration(
                for: server,
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                unarchive: true
            ).arguments.last,
            "'/usr/local/bin/terminal-relay-session' 'thread-unarchive-v2' 'claude' 'terminal-relay' '\(threadID)'"
        )
    }

    func testFullAccessCanBeDisabledForBothAgents() {
        let defaults = AgentLaunchDefaults(
            codexModel: "gpt-5.6-sol",
            codexReasoningEffort: .max,
            claudeModel: "fable",
            claudeReasoningEffort: .max,
            fullAccessEnabled: false
        )

        XCTAssertFalse(
            defaults.arguments(for: .codex)
                .contains("--dangerously-bypass-approvals-and-sandbox")
        )
        XCTAssertFalse(
            defaults.arguments(for: .claude)
                .contains("--dangerously-skip-permissions")
        )
    }

    private func expectedReattachRemoteCommand(
        project: ProjectProfile,
        kind: AgentKind,
        instanceToken: String
    ) -> String {
        let reattachCommand = [
            WorkerSessionProtocol.helperPath,
            "reattach",
            kind.rawValue,
            project.displayName,
            instanceToken
        ]
            .map(SSHCommandBuilder.shellQuote)
            .joined(separator: " ")
        let payload = "exec \(reattachCommand)"
        return "exec \"${SHELL:-/bin/sh}\" -lic \(SSHCommandBuilder.shellQuote(payload))"
    }

    private func expectedStartRemoteCommand(
        kind: AgentKind,
        repositoryName: String,
        defaults: AgentLaunchDefaults
    ) -> String {
        let environment = kind == .claude ? ["/usr/bin/env", "ConEmuANSI=1"] : []
        return (
            environment
                + [WorkerSessionProtocol.helperPath, "start", kind.rawValue, repositoryName]
                + defaults.arguments(for: kind)
        )
            .map(SSHCommandBuilder.shellQuote)
            .joined(separator: " ")
    }

    private func makeServer(
        port: Int = 22,
        identityFile: String = "",
        codexCommand: String = "codex --resume"
    ) -> ServerProfile {
        ServerProfile(
            name: "Production",
            host: "example.com",
            port: port,
            username: "developer",
            identityFile: identityFile,
            workingDirectory: "/legacy/server/workspace",
            codexCommand: codexCommand,
            claudeCommand: "claude"
        )
    }

    private func makeProject(
        server: ServerProfile,
        repositoryName: String = "terminal-relay"
    ) -> ProjectProfile {
        ProjectProfile(
            serverID: server.id,
            repositoryOwner: "owner",
            repositoryName: repositoryName
        )
    }
}
