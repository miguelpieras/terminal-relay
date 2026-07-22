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
                    exitCode: 127,
                    standardOutput: Data(),
                    standardError: Data("helper missing".utf8)
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
