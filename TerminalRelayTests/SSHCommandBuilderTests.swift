import XCTest
@testable import TerminalRelay

final class SSHCommandBuilderTests: XCTestCase {
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
            launchDefaults: .standard
        )
        let remoteCommand = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .codex,
            launchDefaults: .standard
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
            launchDefaults: .standard
        )

        XCTAssertFalse(configuration.arguments.contains("-i"))
        XCTAssertEqual(configuration.arguments.suffix(2), [
            "miguel@example.com",
            SSHCommandBuilder.remoteCommand(
                for: server,
                project: project,
                kind: .claude,
                launchDefaults: .standard
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
            launchDefaults: .standard
        )

        XCTAssertFalse(configuration.arguments.contains("-p"))
    }

    func testClaudeRemoteCommandEnablesTerminalProgressCapability() {
        let server = makeServer()
        let project = makeProject(server: server)

        let command = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .claude,
            launchDefaults: .standard
        )

        XCTAssertTrue(command.contains("exec env ConEmuANSI=1 claude"))
    }

    func testRemoteCommandUsesTheProjectsFixedWorkspaceDirectory() {
        let server = makeServer(
            codexCommand: "  codex --resume  "
        )
        let project = makeProject(server: server, repositoryName: "terminal-relay")

        let command = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .codex,
            launchDefaults: .standard
        )
        let quotedDirectory = SSHCommandBuilder.shellQuote("/workspace/terminal-relay")
        let arguments = AgentLaunchDefaults.standard.arguments(for: .codex)
            .map(SSHCommandBuilder.shellQuote)
            .joined(separator: " ")
        let payload = "cd -- \(quotedDirectory) && exec codex --resume \(arguments)"

        XCTAssertEqual(
            command,
            "exec \"${SHELL:-/bin/sh}\" -lic \(SSHCommandBuilder.shellQuote(payload))"
        )
    }

    func testShellQuoteProtectsSingleQuotes() {
        XCTAssertEqual(SSHCommandBuilder.shellQuote("plain text"), "'plain text'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("it's safe"), "'it'\"'\"'s safe'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote(""), "''")
    }

    func testCustomDefaultsAreQuotedAndAppliedPerAgent() {
        let server = makeServer()
        let project = makeProject(server: server)
        let defaults = AgentLaunchDefaults(
            codexModel: "custom codex",
            codexReasoningEffort: .high,
            claudeModel: "custom'claude",
            claudeReasoningEffort: .xhigh,
            fullAccessEnabled: true
        )

        let codexCommand = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .codex,
            launchDefaults: defaults
        )
        let claudeCommand = SSHCommandBuilder.remoteCommand(
            for: server,
            project: project,
            kind: .claude,
            launchDefaults: defaults
        )

        XCTAssertEqual(
            codexCommand,
            expectedRemoteCommand(
                server: server,
                project: project,
                kind: .codex,
                defaults: defaults
            )
        )
        XCTAssertEqual(
            claudeCommand,
            expectedRemoteCommand(
                server: server,
                project: project,
                kind: .claude,
                defaults: defaults
            )
        )
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

    private func expectedRemoteCommand(
        server: ServerProfile,
        project: ProjectProfile,
        kind: AgentKind,
        defaults: AgentLaunchDefaults
    ) -> String {
        let arguments = defaults.arguments(for: kind)
            .map(SSHCommandBuilder.shellQuote)
            .joined(separator: " ")
        let environmentPrefix = kind == .claude ? "env ConEmuANSI=1 " : ""
        let payload = "cd -- \(SSHCommandBuilder.shellQuote(project.workingDirectory)) && exec \(environmentPrefix)\(server.command(for: kind)) \(arguments)"
        return "exec \"${SHELL:-/bin/sh}\" -lic \(SSHCommandBuilder.shellQuote(payload))"
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
