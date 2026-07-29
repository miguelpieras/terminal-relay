import XCTest
@testable import TerminalRelayIOS

final class WorkerRemoteCommandTests: XCTestCase {
    private let instanceToken = "88b888aa-4d15-" + "4e2b-aacc-4932f440b9ee"

    func testProjectCatalogExcludesRelayCheckoutFromDiscoveryAndSessions() {
        let sessions = [
            WorkerSessionSnapshot(
                kind: .codex,
                repositoryName: "terminal-relay",
                attachedClientCount: 0,
                instanceToken: instanceToken
            ),
            WorkerSessionSnapshot(
                kind: .claude,
                repositoryName: "zeta",
                attachedClientCount: 0,
                instanceToken: instanceToken
            ),
        ]

        XCTAssertEqual(
            WorkerProjectCatalog.visibleProjectNames(
                discoveredProjects: ["Terminal-Relay", "alpha", "zeta"],
                sessions: sessions
            ),
            ["alpha", "zeta"]
        )
    }

    func testFixedCommandsUsePinnedHelperPath() {
        XCTAssertEqual(
            WorkerRemoteCommand.listProjects,
            "/usr/local/bin/terminal-relay-session list-projects"
        )
        XCTAssertEqual(
            WorkerRemoteCommand.status,
            "/usr/local/bin/terminal-relay-session status"
        )
        XCTAssertEqual(
            WorkerRemoteCommand.updateStatus,
            "/usr/local/bin/terminal-relay-session update-status"
        )
        XCTAssertEqual(
            WorkerRemoteCommand.resources,
            "/usr/local/bin/terminal-relay-session resources"
        )
        XCTAssertEqual(
            WorkerRemoteCommand.codexAccount,
            "/usr/local/bin/terminal-relay-session codex-account"
        )
        XCTAssertEqual(
            WorkerRemoteCommand.claudeAccount,
            "/usr/local/bin/terminal-relay-session claude-account"
        )
        XCTAssertTrue(
            WorkerRemoteCommand.legacyCodexAccount.contains("account/rateLimits/read")
        )
        XCTAssertTrue(
            WorkerRemoteCommand.legacyClaudeAccount.contains(
                "__TERMINAL_RELAY_CLAUDE_USAGE__"
            )
        )
    }

    func testWorkerUpdateStatusUsesTheSharedSanitizedProtocol() throws {
        let status = try WorkerUpdateStatusProtocol.parse(
            """
            login banner
            \(WorkerUpdateStatusProtocol.marker)
            update|1700000000|failure|1.2.3|4.5.6
            """
        )

        XCTAssertEqual(status?.timestamp, 1_700_000_000)
        XCTAssertEqual(status?.result, .failure)
        XCTAssertEqual(status?.codexVersion, "1.2.3")
        XCTAssertEqual(status?.claudeVersion, "4.5.6")
        XCTAssertNotNil(status?.warningMessage)
    }

    func testStopIsRepositoryAndInstanceScoped() throws {
        let uppercaseID = instanceToken.uppercased()
        XCTAssertEqual(
            try WorkerRemoteCommand.stop(
                kind: .claude,
                repositoryName: "terminal-relay",
                instanceToken: instanceToken
            ),
            "/usr/local/bin/terminal-relay-session stop 'claude' 'terminal-relay' '88b888aa-4d15-4e2b-aacc-4932f440b9ee'"
        )

        XCTAssertThrowsError(
            try WorkerRemoteCommand.stop(
                kind: .claude,
                repositoryName: "../other",
                instanceToken: instanceToken
            )
        ) { error in
            XCTAssertEqual(error as? WorkerRemoteCommandError, .invalidRepositoryName)
        }
        XCTAssertThrowsError(
            try WorkerRemoteCommand.stop(
                kind: .claude,
                repositoryName: "terminal-relay",
                instanceToken: uppercaseID
            )
        ) { error in
            XCTAssertEqual(error as? WorkerRemoteCommandError, .invalidInstanceToken)
        }
    }

    func testStartValidatesRepositoryAndQuotesEveryDynamicArgument() throws {
        let command = try WorkerRemoteCommand.start(
            kind: .codex,
            repositoryName: "terminal-relay",
            launchArguments: ["--model", "model; touch /tmp/unsafe", "it's-safe"]
        )

        XCTAssertEqual(
            command,
            "cd -- '/workspace/terminal-relay' && exec '/usr/local/bin/terminal-relay-session' 'start' 'codex' 'terminal-relay' '--model' 'model; touch /tmp/unsafe' 'it'\\''s-safe'"
        )
        XCTAssertThrowsError(
            try WorkerRemoteCommand.start(
                kind: .codex,
                repositoryName: "../escape",
                launchArguments: []
            )
        )
    }

    func testReattachIsExactAndNeverCarriesLaunchArguments() throws {
        XCTAssertEqual(
            try WorkerRemoteCommand.reattach(
                kind: .codex,
                repositoryName: "terminal-relay",
                instanceToken: instanceToken
            ),
            "exec '/usr/local/bin/terminal-relay-session' 'reattach' 'codex' 'terminal-relay' '88b888aa-4d15-4e2b-aacc-4932f440b9ee'"
        )

        XCTAssertThrowsError(
            try WorkerRemoteCommand.reattach(
                kind: .codex,
                repositoryName: "../other",
                instanceToken: instanceToken
            )
        ) { error in
            XCTAssertEqual(error as? WorkerRemoteCommandError, .invalidRepositoryName)
        }
        XCTAssertThrowsError(
            try WorkerRemoteCommand.reattach(
                kind: .codex,
                repositoryName: "terminal-relay",
                instanceToken: "not-an-instance"
            )
        ) { error in
            XCTAssertEqual(error as? WorkerRemoteCommandError, .invalidInstanceToken)
        }
    }

    func testThreadCommandsValidateIdentityAndQuoteNames() throws {
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

        XCTAssertEqual(
            try WorkerRemoteCommand.threads(
                kind: .claude,
                repositoryName: "terminal-relay",
                archived: true,
                cursor: "next page"
            ),
            "'/usr/local/bin/terminal-relay-session' 'threads-v2' 'claude' 'terminal-relay' 'archived' 'next page'"
        )
        XCTAssertEqual(
            try WorkerRemoteCommand.resumeThread(
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                launchArguments: ["--model", "gpt-5.6-sol"]
            ),
            "'/usr/local/bin/terminal-relay-session' 'thread-resume-v2' 'claude' 'terminal-relay' '\(threadID)' '--model' 'gpt-5.6-sol'"
        )
        XCTAssertEqual(
            try WorkerRemoteCommand.renameThread(
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                name: "It's renamed"
            ),
            "'/usr/local/bin/terminal-relay-session' 'thread-rename-v2' 'claude' 'terminal-relay' '\(threadID)' 'It'\\''s renamed'"
        )
        XCTAssertEqual(
            try WorkerRemoteCommand.archiveThread(
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                unarchive: true
            ),
            "'/usr/local/bin/terminal-relay-session' 'thread-unarchive-v2' 'claude' 'terminal-relay' '\(threadID)'"
        )
        XCTAssertThrowsError(
            try WorkerRemoteCommand.resumeThread(
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID.uppercased(),
                launchArguments: []
            )
        ) { error in
            XCTAssertEqual(error as? WorkerRemoteCommandError, .invalidInstanceToken)
        }
        XCTAssertThrowsError(
            try WorkerRemoteCommand.renameThread(
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                name: "line one\nline two"
            )
        ) { error in
            XCTAssertEqual(error as? WorkerRemoteCommandError, .invalidThreadName)
        }
    }

    func testIOSParsesAndMergesThreadCatalogUsingThreadIdentity() throws {
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let instanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let catalog = try WorkerThreadProtocol.parse(
            """
            \(WorkerThreadProtocol.marker)
            {"threads":[{"provider":"claude","threadID":"\(threadID)","title":"Dormant","updatedAt":10,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
            """,
            repositoryName: "terminal-relay"
        )
        let merged = catalog.merging(
            liveSessions: [
                WorkerSessionSnapshot(
                    kind: .claude,
                    repositoryName: "terminal-relay",
                    attachedClientCount: 1,
                    instanceToken: instanceID,
                    title: "Working",
                    lastActivityAt: 20,
                    reportedWorking: true,
                    threadID: threadID
                )
            ]
        )

        XCTAssertEqual(merged.threads.count, 1)
        XCTAssertEqual(merged.threads[0].threadID, threadID)
        XCTAssertEqual(merged.threads[0].activeInstanceToken, instanceID)
        XCTAssertEqual(merged.threads[0].title, "Working")
        XCTAssertEqual(merged.threads[0].capabilities, WorkerThreadCapabilities.active)
    }

    func testConnectionPolicyStartsForIdentityThenUsesOnlyReattachForPTY() throws {
        XCTAssertEqual(
            TerminalSessionCommandPolicy.initialAction(instanceToken: nil),
            .start
        )
        XCTAssertEqual(
            TerminalSessionCommandPolicy.initialAction(instanceToken: instanceToken),
            .reattach(instanceToken: instanceToken)
        )

        let terminalCommand = try TerminalSessionCommandPolicy.terminalCommand(
            kind: .codex,
            repositoryName: "terminal-relay",
            instanceToken: instanceToken
        )

        XCTAssertEqual(
            terminalCommand,
            "exec '/usr/local/bin/terminal-relay-session' 'reattach' 'codex' 'terminal-relay' '88b888aa-4d15-4e2b-aacc-4932f440b9ee'"
        )
    }

    func testReconnectConfirmationRequiresSameSession() {
        let replacementID = "4ebea645-deaa-" + "4d07-8151-8180ceec77c3"
        let response = WorkerSessionResponse(
            projects: [],
            sessions: [
                WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    attachedClientCount: 1,
                    instanceToken: instanceToken
                )
            ]
        )

        XCTAssertEqual(
            TerminalSessionController.confirmation(
                in: response,
                kind: .codex,
                repositoryName: "terminal-relay",
                expectedInstanceToken: instanceToken
            ),
            .active(instanceToken: instanceToken)
        )
        XCTAssertEqual(
            TerminalSessionController.confirmation(
                in: response,
                kind: .codex,
                repositoryName: "another-project",
                expectedInstanceToken: instanceToken
            ),
            .moved(repositoryName: "terminal-relay")
        )
        XCTAssertEqual(
            TerminalSessionController.confirmation(
                in: response,
                kind: .codex,
                repositoryName: "terminal-relay",
                expectedInstanceToken: replacementID
            ),
            .ended
        )
        XCTAssertEqual(
            TerminalSessionController.confirmation(
                in: response,
                kind: .claude,
                repositoryName: "terminal-relay",
                expectedInstanceToken: instanceToken
            ),
            .ended
        )
    }

    func testStartedSessionRequiresOneExactSessionRecord() throws {
        let session = WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: "terminal-relay",
            attachedClientCount: 0,
            instanceToken: instanceToken
        )
        let exactResponse = try WorkerSessionProtocol.parse(
            """
            \(WorkerSessionProtocol.marker)
            session|codex|terminal-relay|0|\(instanceToken)
            """
        )

        XCTAssertEqual(
            try TerminalSessionController.startedSession(
                in: exactResponse,
                kind: .codex,
                repositoryName: "terminal-relay"
            ),
            session
        )
        XCTAssertThrowsError(
            try WorkerSessionProtocol.parse(
                "\(WorkerSessionProtocol.marker)\nsession|codex|terminal-relay|0"
            )
        ) { error in
            XCTAssertEqual(error as? WorkerSessionProtocolError, .invalidRecord)
        }

        for invalidResponse in [
            WorkerSessionResponse(projects: ["terminal-relay"], sessions: [session]),
            WorkerSessionResponse(projects: [], sessions: []),
            WorkerSessionResponse(
                projects: [],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: "another-project",
                        attachedClientCount: 0,
                        instanceToken: instanceToken
                    )
                ]
            ),
        ] {
            XCTAssertThrowsError(
                try TerminalSessionController.startedSession(
                    in: invalidResponse,
                    kind: .codex,
                    repositoryName: "terminal-relay"
                )
            ) { error in
                XCTAssertEqual(
                    error as? TerminalSessionRecoveryError,
                    .invalidStartResponse(kind: .codex, repositoryName: "terminal-relay")
                )
            }
        }
    }

    func testExecResultWaitsForEOFAndIncludesOutputAfterExitStatus() throws {
        var accumulator = SSHExecResultAccumulator()
        accumulator.append(Data("before-".utf8), to: .standardOutput)
        accumulator.recordExitStatus(23)
        accumulator.append(Data("after".utf8), to: .standardOutput)
        accumulator.append(Data("trailing error".utf8), to: .standardError)
        XCTAssertNil(accumulator.resultIfComplete())
        accumulator.recordEOF()

        let result = try XCTUnwrap(accumulator.resultIfComplete()).get()
        XCTAssertEqual(result.status, 23)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "before-after")
        XCTAssertEqual(String(decoding: result.standardError, as: UTF8.self), "trailing error")
    }

    func testExecResultAcceptsEOFBeforeExitStatus() throws {
        var accumulator = SSHExecResultAccumulator()
        accumulator.append(Data("complete output".utf8), to: .standardOutput)
        accumulator.recordEOF()
        XCTAssertNil(accumulator.resultIfComplete())

        accumulator.recordExitStatus(0)

        let result = try XCTUnwrap(accumulator.resultIfComplete()).get()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "complete output")
    }

    func testExecResultRequiresExitStatusAtEOF() {
        var accumulator = SSHExecResultAccumulator()
        accumulator.append(Data("partial output".utf8), to: .standardOutput)
        accumulator.recordEOF()

        XCTAssertThrowsError(try accumulator.resultAtChannelClose().get()) { error in
            guard case SSHTransportError.missingExitStatus = error else {
                return XCTFail("Expected missingExitStatus, received \(error)")
            }
        }
    }

    func testExecResultUsesExitStatusWhenChannelClosesWithoutEOF() throws {
        var accumulator = SSHExecResultAccumulator()
        accumulator.append(Data("complete output".utf8), to: .standardOutput)
        accumulator.recordExitStatus(0)

        let result = try accumulator.resultAtChannelClose().get()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "complete output")
    }
}
