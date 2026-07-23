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
            .replaced
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
