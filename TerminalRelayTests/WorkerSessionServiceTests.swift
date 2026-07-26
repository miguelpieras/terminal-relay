import XCTest
@testable import TerminalRelay

@MainActor
final class WorkerSessionServiceTests: XCTestCase {
    func testRefreshAndStopUseTheirDedicatedSSHConfigurations() async {
        let worker = makeWorker()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        __TERMINAL_RELAY_SESSION_V1__
                        session|codex|terminal-relay|1|\(instanceToken)
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        "\(WorkerUpdateStatusProtocol.marker)\n".utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let response = await service.refresh(worker: worker)
        let stopped = await service.stop(
            kind: .codex,
            repositoryName: "terminal-relay",
            instanceToken: instanceToken,
            on: worker
        )

        XCTAssertEqual(
            response?.sessions,
            [
                WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    attachedClientCount: 1,
                    instanceToken: instanceToken
                )
            ]
        )
        XCTAssertTrue(stopped)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStatusConfiguration(for: worker),
                SSHCommandBuilder.workerUpdateStatusConfiguration(for: worker),
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    instanceToken: instanceToken
                )
            ]
        )
        XCTAssertEqual(service.response(for: worker.id)?.sessions, [])
        XCTAssertNil(service.error(for: worker.id))
    }

    func testStatusFailureKeepsTheLastSuccessfulResponseAndSurfacesAnError() async {
        let worker = makeWorker()
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        __TERMINAL_RELAY_SESSION_V1__
                        session|claude|website-api|0|11111111-2222-4333-8444-555555555555
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        "\(WorkerUpdateStatusProtocol.marker)\n".utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 127,
                    standardOutput: Data(),
                    standardError: Data("helper missing".utf8)
                ),
                WorkerSessionCommandResult(
                    exitCode: 64,
                    standardOutput: Data(),
                    standardError: Data("unsupported command".utf8)
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let firstResponse = await service.refresh(worker: worker)
        let failedResponse = await service.refresh(worker: worker)

        XCTAssertNotNil(firstResponse)
        XCTAssertNil(failedResponse)
        XCTAssertEqual(service.response(for: worker.id), firstResponse)
        XCTAssertEqual(
            service.error(for: worker.id),
            "Persistent session status is unavailable for this worker."
        )
    }

    func testStopActiveSessionsRefreshesAndStopsEveryMatchingAgent() async {
        let worker = makeWorker()
        let firstClaudeToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let secondClaudeToken = "11111111-2222-" + "4333-8444-555555555555"
        let codexToken = "aaaaaaaa-bbbb-" + "4ccc-8ddd-eeeeeeeeeeee"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        __TERMINAL_RELAY_SESSION_V1__
                        session|claude|terminal-relay|0|\(firstClaudeToken)
                        session|codex|terminal-relay|0|\(codexToken)
                        session|claude|website-api|0|\(secondClaudeToken)
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        "\(WorkerUpdateStatusProtocol.marker)\n".utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let stopped = await service.stopActiveSessions(kind: .claude, on: worker)

        XCTAssertTrue(stopped)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStatusConfiguration(for: worker),
                SSHCommandBuilder.workerUpdateStatusConfiguration(for: worker),
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: worker,
                    kind: .claude,
                    repositoryName: "terminal-relay",
                    instanceToken: firstClaudeToken
                ),
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: worker,
                    kind: .claude,
                    repositoryName: "website-api",
                    instanceToken: secondClaudeToken
                )
            ]
        )
        XCTAssertEqual(
            service.response(for: worker.id)?.sessions,
            [
                WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    attachedClientCount: 0,
                    instanceToken: codexToken
                )
            ]
        )
    }

    func testStopActiveSessionsSucceedsWhenTheAgentAlreadyExited() async {
        let worker = makeWorker()
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        __TERMINAL_RELAY_SESSION_V1__
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        "\(WorkerUpdateStatusProtocol.marker)\n".utf8
                    ),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let stopped = await service.stopActiveSessions(kind: .claude, on: worker)

        XCTAssertTrue(stopped)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStatusConfiguration(for: worker),
                SSHCommandBuilder.workerUpdateStatusConfiguration(for: worker)
            ]
        )
    }

    func testStopActiveSessionsWaitsForAnInFlightRefresh() async {
        let worker = makeWorker()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let recorder = BlockingFirstWorkerSessionCommandRecorder(
            subsequentResults: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        "\(WorkerUpdateStatusProtocol.marker)\n".utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let refreshTask = Task {
            await service.refresh(worker: worker)
        }
        while recorder.configurations.isEmpty {
            await Task.yield()
        }

        let stopTask = Task {
            await service.stopActiveSessions(kind: .claude, on: worker)
        }
        await Task.yield()

        XCTAssertEqual(
            recorder.configurations,
            [SSHCommandBuilder.workerSessionStatusConfiguration(for: worker)]
        )

        recorder.finishFirst(
            with: WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data(
                    """
                    __TERMINAL_RELAY_SESSION_V1__
                    session|claude|terminal-relay|0|\(instanceToken)
                    """.utf8
                ),
                standardError: Data()
            )
        )

        let stopped = await stopTask.value
        let refreshed = await refreshTask.value

        XCTAssertTrue(stopped)
        XCTAssertNotNil(refreshed)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStatusConfiguration(for: worker),
                SSHCommandBuilder.workerUpdateStatusConfiguration(for: worker),
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: worker,
                    kind: .claude,
                    repositoryName: "terminal-relay",
                    instanceToken: instanceToken
                )
            ]
        )
    }

    func testUpdateFailureWarningCanBeDismissedUntilANewFailureArrives() async {
        let worker = makeWorker()
        let sessionStatus = WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data("__TERMINAL_RELAY_SESSION_V1__\n".utf8),
            standardError: Data()
        )
        func updateStatus(_ timestamp: Int, _ result: String) -> WorkerSessionCommandResult {
            WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data(
                    """
                    \(WorkerUpdateStatusProtocol.marker)
                    update|\(timestamp)|\(result)|1.2.3|4.5.6

                    """.utf8
                ),
                standardError: Data()
            )
        }
        let recorder = WorkerSessionCommandRecorder(
            results: [
                sessionStatus, updateStatus(1_700_000_000, "failure"),
                sessionStatus, updateStatus(1_700_000_000, "failure"),
                sessionStatus, updateStatus(1_700_000_001, "failure"),
                sessionStatus, updateStatus(1_700_000_002, "success"),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        _ = await service.refresh(worker: worker)
        XCTAssertEqual(
            service.updateWarning(for: worker.id),
            "Automatic agent update failed. Codex 1.2.3 and Claude Code 4.5.6 remain available; the worker will retry automatically."
        )

        service.dismissUpdateWarning(for: worker.id)
        XCTAssertNil(service.updateWarning(for: worker.id))

        _ = await service.refresh(worker: worker)
        XCTAssertNil(service.updateWarning(for: worker.id))

        _ = await service.refresh(worker: worker)
        XCTAssertNotNil(service.updateWarning(for: worker.id))

        _ = await service.refresh(worker: worker)
        XCTAssertNil(service.updateWarning(for: worker.id))
    }

    func testStartReturnsAndStoresTheExactSessionSnapshot() async {
        let worker = makeWorker()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        __TERMINAL_RELAY_SESSION_V1__
                        session|codex|terminal-relay|0|\(instanceToken)
                        """.utf8
                    ),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let snapshot = await service.start(
            kind: .codex,
            repositoryName: "terminal-relay",
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertEqual(
            snapshot,
            WorkerSessionSnapshot(
                kind: .codex,
                repositoryName: "terminal-relay",
                attachedClientCount: 0,
                instanceToken: instanceToken
            )
        )
        XCTAssertEqual(service.response(for: worker.id)?.sessions.first, snapshot)
        XCTAssertEqual(service.response(for: worker.id)?.sessions.count, 1)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    launchDefaults: .standard
                )
            ]
        )
        XCTAssertFalse(service.isStarting(worker: worker, kind: .codex))
        XCTAssertNil(service.error(for: worker.id))
    }

    func testStartRejectsAResponseForAnyOtherSession() async {
        let worker = makeWorker()
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        __TERMINAL_RELAY_SESSION_V1__
                        session|codex|another-repository|0|01234567-89ab-4def-8abc-0123456789ab
                        """.utf8
                    ),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let snapshot = await service.start(
            kind: .codex,
            repositoryName: "terminal-relay",
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertNil(snapshot)
        XCTAssertNil(service.response(for: worker.id))
        XCTAssertEqual(service.error(for: worker.id), "The worker could not start this agent.")
    }

    private func makeWorker() -> ServerProfile {
        ServerProfile(
            name: "Worker 1",
            host: "worker.example.com",
            username: "relay"
        )
    }
}

@MainActor
private final class WorkerSessionCommandRecorder {
    private(set) var configurations: [SSHLaunchConfiguration] = []
    private var results: [WorkerSessionCommandResult]

    init(results: [WorkerSessionCommandResult]) {
        self.results = results
    }

    func run(_ configuration: SSHLaunchConfiguration) async -> WorkerSessionCommandResult {
        configurations.append(configuration)
        return results.removeFirst()
    }
}

@MainActor
private final class BlockingFirstWorkerSessionCommandRecorder {
    private(set) var configurations: [SSHLaunchConfiguration] = []
    private var firstContinuation: CheckedContinuation<WorkerSessionCommandResult, Never>?
    private var subsequentResults: [WorkerSessionCommandResult]

    init(subsequentResults: [WorkerSessionCommandResult]) {
        self.subsequentResults = subsequentResults
    }

    func run(_ configuration: SSHLaunchConfiguration) async -> WorkerSessionCommandResult {
        configurations.append(configuration)
        if configurations.count == 1 {
            return await withCheckedContinuation { continuation in
                firstContinuation = continuation
            }
        }
        return subsequentResults.removeFirst()
    }

    func finishFirst(with result: WorkerSessionCommandResult) {
        firstContinuation?.resume(returning: result)
        firstContinuation = nil
    }
}
