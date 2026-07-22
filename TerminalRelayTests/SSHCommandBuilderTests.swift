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
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "miguel@example.com",
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
            "miguel@example.com",
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
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "--",
                "miguel@example.com",
                "'/usr/local/bin/terminal-relay-session' 'status'"
            ]
        )
        XCTAssertFalse(configuration.arguments.contains("-tt"))
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
                "miguel@example.com",
                "'/usr/local/bin/terminal-relay-session' 'stop' 'claude' 'terminal-relay' '\(instanceToken)'"
            ]
        )
        XCTAssertFalse(configuration.arguments.contains("-tt"))
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
                .contains("{\"mcpServers\":{}}")
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
            username: "miguel",
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
