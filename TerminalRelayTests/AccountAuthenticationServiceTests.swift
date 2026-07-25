import XCTest
@testable import TerminalRelay

final class AccountAuthenticationServiceTests: XCTestCase {
    func testOnlyClaudeRequiresStoppingAnActiveAgentBeforeAccountChange() {
        XCTAssertFalse(
            AccountChangePolicy.requiresStoppingActiveAgent(
                kind: .codex,
                hasActiveAgent: true
            )
        )
        XCTAssertTrue(
            AccountChangePolicy.requiresStoppingActiveAgent(
                kind: .claude,
                hasActiveAgent: true
            )
        )
        XCTAssertFalse(
            AccountChangePolicy.requiresStoppingActiveAgent(
                kind: .claude,
                hasActiveAgent: false
            )
        )
    }

    func testParsesCodexDeviceAuthorizationFromStyledOutput() throws {
        let output = """
        Follow these steps to sign in:
        \u{001B}[94mhttps://auth.openai.com/codex/device\u{001B}[0m
        Enter this one-time code:
        \u{001B}[94mAB12-CD345\u{001B}[0m
        """

        let result = AccountAuthenticationOutputParser.parse(output, for: .codex)

        XCTAssertEqual(
            try XCTUnwrap(result.authorizationURL).absoluteString,
            "https://auth.openai.com/codex/device"
        )
        XCTAssertEqual(result.deviceCode, "AB12-CD345")
    }

    func testParsesClaudeAuthorizationURLFromTerminalHyperlink() throws {
        let url = "https://claude.com/cai/oauth/authorize?code=true&state=unique-state"
        let output = """
        Opening browser to sign in…
        If the browser didn't open, visit: \u{001B}]8;;\(url)\u{0007}\(url)\u{001B}]8;;\u{0007}
        Paste code here if prompted >
        """

        let result = AccountAuthenticationOutputParser.parse(output, for: .claude)

        XCTAssertEqual(try XCTUnwrap(result.authorizationURL).absoluteString, url)
        XCTAssertNil(result.deviceCode)
    }

    func testAuthenticationCommandUsesInteractiveSSHAndFixedProviderLogin() throws {
        let worker = ServerProfile(
            name: "Worker 4",
            host: "worker.example.com",
            port: 2_222,
            username: "terminal-relay",
            identityFile: "~/Keys/worker key",
            codexCommand: "printf should-not-run",
            claudeCommand: "printf should-not-run"
        )

        let codex = AccountAuthenticationCommand.configuration(
            for: worker,
            kind: .codex
        )
        let claude = AccountAuthenticationCommand.configuration(
            for: worker,
            kind: .claude
        )

        XCTAssertEqual(codex.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            Array(codex.arguments.prefix(12)),
            [
                "-tt",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=accept-new",
                "-p"
            ]
        )
        XCTAssertTrue(codex.arguments.contains("2222"))
        XCTAssertTrue(
            codex.arguments.contains(
                ("~/Keys/worker key" as NSString).expandingTildeInPath
            )
        )
        XCTAssertEqual(codex.arguments.suffix(2).first, worker.destination)

        let codexRemoteCommand = try XCTUnwrap(codex.arguments.last)
        XCTAssertTrue(
            codexRemoteCommand.contains(
                "\(WorkerSessionProtocol.helperPath) codex-login"
            )
        )
        XCTAssertTrue(codexRemoteCommand.contains("stty -echo"))
        XCTAssertFalse(codexRemoteCommand.contains("printf should-not-run"))

        let claudeRemoteCommand = try XCTUnwrap(claude.arguments.last)
        XCTAssertTrue(claudeRemoteCommand.contains("claude auth login --claudeai"))
        XCTAssertFalse(claudeRemoteCommand.contains("printf should-not-run"))
    }

    func testAuthenticationCommandLeavesSSHConfigPortUntouchedByDefault() {
        let worker = ServerProfile(
            name: "Worker 1",
            host: "terminal-relay-worker-1",
            port: 22,
            username: "terminal-relay"
        )

        let configuration = AccountAuthenticationCommand.configuration(
            for: worker,
            kind: .codex
        )

        XCTAssertFalse(configuration.arguments.contains("-p"))
        XCTAssertEqual(configuration.arguments.suffix(2).first, worker.destination)
    }
}
