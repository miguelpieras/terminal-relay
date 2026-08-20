import XCTest
@testable import TerminalRelay

final class AccountAuthenticationServiceTests: XCTestCase {
    func testAccountSignInNeverRequiresStoppingConcurrentAgents() {
        XCTAssertFalse(
            AccountChangePolicy.requiresStoppingActiveAgent(
                kind: .codex,
                hasActiveAgent: true
            )
        )
        XCTAssertFalse(
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


    func testAuthenticationCommandScopesLoginToExactAccount() throws {
        let worker = ServerProfile(
            name: "Worker 1",
            host: "worker.example.com",
            username: "terminal-relay"
        )
        let accountID = ProviderAccountID(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )

        let configuration = AccountAuthenticationCommand.configuration(
            for: worker,
            kind: .claude,
            accountID: accountID
        )
        let command = try XCTUnwrap(configuration.arguments.last)

        XCTAssertTrue(command.contains("'provider-account-login-v1'"))
        XCTAssertTrue(command.contains("'claude'"))
        XCTAssertTrue(command.contains("'\(accountID.rawValue)'"))
        XCTAssertFalse(command.contains("claude auth login --claudeai"))
    }

    func testProviderAccountProtocolRejectsWrongExpectedRoute() throws {
        let accountID = ProviderAccountID(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        let data = Data(
            """
            \(ProviderAccountProtocol.marker)
            {"accounts":[{"accountID":"\(accountID.rawValue)","provider":"codex","label":"Personal","status":"active","storageKind":"isolated"}]}
            """.utf8
        )

        let accounts = try ProviderAccountProtocol.parse(
            data,
            expectedProvider: .codex,
            expectedAccountID: accountID
        )
        XCTAssertEqual(accounts.first?.displayName, "Personal")
        XCTAssertThrowsError(
            try ProviderAccountProtocol.parse(data, expectedProvider: .claude)
        )
    }

    @MainActor
    func testProviderAccountServiceKeepsTwoSameProviderProfilesDistinct() async {
        let firstID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let secondID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let service = ProviderAccountService { _ in
            WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data(
                    """
                    \(ProviderAccountProtocol.marker)
                    {"accounts":[{"accountID":"\(firstID)","provider":"codex","label":"Personal","status":"active","storageKind":"isolated"},{"accountID":"\(secondID)","provider":"codex","label":"Work","status":"authRequired","storageKind":"isolated"}]}
                    """.utf8
                ),
                standardError: Data()
            )
        }
        let worker = ServerProfile(
            name: "Worker",
            host: "worker.example.com",
            username: "relay"
        )

        _ = await service.refresh(worker: worker, provider: .codex)

        XCTAssertEqual(service.accounts(workerID: worker.id, provider: .codex).count, 2)
        XCTAssertEqual(
            Set(service.accounts(workerID: worker.id).map(\.accountID.rawValue)),
            Set([firstID, secondID])
        )
    }

    @MainActor
    func testProviderAccountStatusRefreshRequiresAndAppliesExactRoute() async throws {
        let accountID = ProviderAccountID(
            UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
        )
        var configurations: [SSHLaunchConfiguration] = []
        let service = ProviderAccountService { configuration in
            configurations.append(configuration)
            return WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data(
                    """
                    \(ProviderAccountProtocol.marker)
                    {"accounts":[{"accountID":"\(accountID.rawValue)","provider":"claude","label":"Personal","status":"authRequired","storageKind":"isolated"}]}
                    """.utf8
                ),
                standardError: Data()
            )
        }
        let worker = ServerProfile(
            name: "Worker",
            host: "worker.example.com",
            username: "relay"
        )
        let account = ProviderAccountProfile(
            accountID: accountID,
            provider: .claude,
            label: "Personal",
            storageKind: .isolated,
            status: .active
        )

        let updated = try await service.refreshStatus(worker: worker, account: account)

        XCTAssertEqual(updated.status, .authRequired)
        XCTAssertEqual(
            service.account(
                workerID: worker.id,
                provider: .claude,
                accountID: accountID
            )?.status,
            .authRequired
        )
        XCTAssertTrue(
            try XCTUnwrap(configurations.last?.arguments.last)
                .contains("'provider-account-status-v1' 'claude' '\(accountID.rawValue)'")
        )
    }

    @MainActor
    func testProviderAccountCreateExplainsLegacyTaskActivationBlock() async {
        let service = ProviderAccountService { _ in
            WorkerSessionCommandResult(
                exitCode: 75,
                standardOutput: Data(),
                standardError: Data(
                    "Stop every legacy codex task before adding a second account.\n".utf8
                )
            )
        }
        let worker = ServerProfile(
            name: "Worker",
            host: "worker.example.com",
            username: "relay"
        )

        do {
            _ = try await service.create(
                worker: worker,
                provider: .codex,
                label: "Work"
            )
            XCTFail("Expected account creation to fail while a legacy task is live.")
        } catch {
            XCTAssertEqual(
                error as? ProviderAccountServiceError,
                .legacyTasksRunning(.codex)
            )
        }
    }
}
