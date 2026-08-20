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

    func testIncompatibleRuntimeRequestsOneFixedUpdateCheck() async {
        let worker = makeWorker()
        let recorder = RuntimeInspectionCommandRecorder()
        let service = WorkerSessionService(
            runCommand: { configuration in
                await recorder.run(configuration)
            },
            inspectsRuntimeOnRefresh: true
        )

        _ = await service.refresh(worker: worker)
        for _ in 0..<100 where !recorder.requestedUpdate {
            await Task.yield()
        }

        XCTAssertTrue(recorder.requestedUpdate)
        XCTAssertEqual(service.runtimeInfos[worker.id]?.maximumProtocol, 1)
        XCTAssertEqual(
            service.runtimeMessages[worker.id],
            "This worker needs a runtime update for the current client. Updating automatically…"
        )
    }

    func testStartFailsClosedWhenNativeChatIsUnavailable() async {
        let worker = makeWorker()
        let recorder = WorkerSessionCommandRecorder(
            results: [
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

        let snapshot = await service.start(
            kind: .codex,
            repositoryName: "terminal-relay",
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertNil(snapshot)
        XCTAssertNil(service.response(for: worker.id))
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    threadID: nil,
                    launchDefaults: .standard
                )
            ]
        )
        XCTAssertFalse(service.isStarting(worker: worker, kind: .codex))
        XCTAssertEqual(
            service.error(for: worker.id),
            "Native chat is unavailable on this worker. Update it and try again."
        )
    }

    func testStartTreatsConnectionFailureAsRetryableStartFailure() async {
        let worker = makeWorker()
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 255,
                    standardOutput: Data(),
                    standardError: Data("connection interrupted".utf8)
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
        XCTAssertEqual(
            service.error(for: worker.id),
            "The worker could not start this agent."
        )
        XCTAssertNil(service.updateWarning(for: worker.id))
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    threadID: nil,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testStartRejectsAnInvalidNativeChatResponse() async {
        let worker = makeWorker()
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerSessionProtocol.legacyMarker)
                        session|codex|terminal-relay|0|01234567-89ab-4def-8abc-0123456789ab
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

    func testFreshThreadCatalogSkipsRedundantWorkerRoundTrips() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data("\(WorkerSessionProtocol.legacyMarker)\n".utf8),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data("\(WorkerUpdateStatusProtocol.marker)\n".utf8),
                    standardError: Data()
                ),
                threadResult(
                    """
                    {"threads":[{"provider":"codex","threadID":"\(threadID)","title":"Cached","updatedAt":10,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
                    """
                ),
                threadResult(
                    """
                    {"threads":[],"nextCursor":null}
                    """
                ),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        _ = await service.refresh(worker: worker)
        let first = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker,
            skipIfFresh: true
        )
        let commandCountAfterFirst = recorder.configurations.count

        let second = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker,
            skipIfFresh: true
        )

        XCTAssertEqual(first?.threads.map(\.threadID), [threadID])
        XCTAssertEqual(
            second,
            first,
            "A fresh catalog must be served from memory."
        )
        XCTAssertEqual(
            recorder.configurations.count,
            commandCountAfterFirst,
            "A fresh catalog must not trigger another worker round trip."
        )
    }

    func testThreadCatalogPaginatesDeduplicatesMergesLiveStateAndKeepsLastGoodValue() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let otherThreadID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let instanceID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerSessionProtocol.legacyMarker)
                        session|codex|terminal-relay|1|\(instanceID)|30|4c697665|1|\(threadID)
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data("\(WorkerUpdateStatusProtocol.marker)\n".utf8),
                    standardError: Data()
                ),
                threadResult(
                    """
                    {"threads":[{"provider":"codex","threadID":"\(threadID)","title":"Older","updatedAt":10,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":"page-2"}
                    """
                ),
                threadResult(
                    """
                    {"threads":[{"provider":"codex","threadID":"\(threadID)","title":"Newer","updatedAt":20,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}},{"provider":"codex","threadID":"\(otherThreadID)","title":"Other","updatedAt":15,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
                    """
                ),
                threadResult(
                    """
                    {"threads":[],"nextCursor":null}
                    """
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data("\(WorkerSessionProtocol.legacyMarker)\n".utf8),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data("\(WorkerUpdateStatusProtocol.marker)\n".utf8),
                    standardError: Data()
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

        _ = await service.refresh(worker: worker)
        let response = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )

        XCTAssertEqual(response?.threads.map(\.threadID), [threadID, otherThreadID])
        XCTAssertEqual(response?.threads.first?.title, "Live")
        XCTAssertEqual(response?.threads.first?.activeInstanceToken, instanceID)
        XCTAssertTrue(response?.threads.first?.reportedWorking == true)
        XCTAssertEqual(
            recorder.configurations.suffix(3),
            [
                SSHCommandBuilder.workerThreadListConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    archived: false
                ),
                SSHCommandBuilder.workerThreadListConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    archived: false,
                    cursor: "page-2"
                ),
                SSHCommandBuilder.workerThreadListConfiguration(
                    for: worker,
                    kind: .claude,
                    repositoryName: "terminal-relay",
                    archived: false
                )
            ]
        )

        _ = await service.refresh(worker: worker)
        XCTAssertNil(
            service.threads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            ).first?.activeInstanceToken
        )
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            ).first?.capabilities,
            .dormantCodex
        )
        let dormantThreads = service.threads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )

        let failed = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )
        XCTAssertNil(failed)
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            ),
            dormantThreads
        )
    }

    func testStartUsesOneCommandAndStoresNativeChatByDefault() async {
        let worker = makeWorker()
        let relayID = "01234567-89ab-4def-8abc-0123456789ab"
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let capabilities =
            #"{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerChatProtocol.legacyMarker)
                        {"relayId":"\(relayID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{"model":"gpt-example"}}

                        """.utf8
                    ),
                    standardError: Data()
                ),
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

        XCTAssertEqual(snapshot?.instanceToken, relayID)
        XCTAssertEqual(snapshot?.threadID, threadID)
        XCTAssertEqual(snapshot?.presentation, .chat)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    threadID: nil,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testResumeThreadRequiresAndStoresTheExactProviderThreadID() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let instanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let capabilities =
            #"{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerChatProtocol.legacyMarker)
                        {"relayId":"\(instanceID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{"model":"gpt-example"}}

                        """.utf8
                    ),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let snapshot = await service.resumeThread(
            kind: .codex,
            repositoryName: "terminal-relay",
            threadID: threadID,
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertEqual(snapshot?.threadID, threadID)
        XCTAssertEqual(snapshot?.instanceToken, instanceID)
        XCTAssertEqual(service.response(for: worker.id)?.sessions, [snapshot].compactMap { $0 })
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    threadID: threadID,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testResumeThreadFailsClosedWhenNativeChatIsUnavailable() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let recorder = WorkerSessionCommandRecorder(
            results: [
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

        let snapshot = await service.resumeThread(
            kind: .codex,
            repositoryName: "terminal-relay",
            threadID: threadID,
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertNil(snapshot)
        XCTAssertNil(service.response(for: worker.id))
        XCTAssertEqual(
            service.error(for: worker.id),
            "Native chat is unavailable on this worker. Update it and try again."
        )
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    threadID: threadID,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testResumeThreadTreatsConnectionFailureAsRetryableThreadFailure() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 255,
                    standardOutput: Data(),
                    standardError: Data("connection interrupted".utf8)
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let snapshot = await service.resumeThread(
            kind: .codex,
            repositoryName: "terminal-relay",
            threadID: threadID,
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertNil(snapshot)
        XCTAssertEqual(
            service.error(for: worker.id),
            "The worker could not complete that thread action."
        )
        XCTAssertNil(service.updateWarning(for: worker.id))
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    threadID: threadID,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testArchivedChatStaysHiddenWhenTheWorkerBrieflyRelistsItsStoppedSession() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let instanceID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let archivedRow = """
        {"threads":[{"provider":"claude","threadID":"\(threadID)","title":"Done","updatedAt":10,"archived":true,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":false,"rename":false,"archive":false,"unarchive":true}}],"nextCursor":null}
        """
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                ),
                threadResult(archivedRow),
                threadResult("{\"threads\":[],\"nextCursor\":null}"),
                threadResult("{\"threads\":[],\"nextCursor\":null}"),
                threadResult("{\"threads\":[],\"nextCursor\":null}"),
                threadResult(archivedRow),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerSessionProtocol.legacyMarker)
                        session|claude|terminal-relay|1|\(instanceID)|30|4c697665|1|\(threadID)|chat
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data("\(WorkerUpdateStatusProtocol.marker)\n".utf8),
                    standardError: Data()
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let stopped = await service.stop(
            kind: .claude,
            repositoryName: "terminal-relay",
            instanceToken: instanceID,
            presentation: .chat,
            on: worker
        )
        let archived = await service.setThreadArchived(
            kind: .claude,
            repositoryName: "terminal-relay",
            threadID: threadID,
            archived: true,
            on: worker
        )
        _ = await service.refresh(worker: worker)

        XCTAssertTrue(stopped)
        XCTAssertTrue(archived)
        XCTAssertEqual(
            service.response(for: worker.id)?.sessions,
            [],
            "A stop's teardown lag must not resurrect the stopped session."
        )
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            ),
            [],
            "A stale status listing must not resurrect an archived thread."
        )
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: true,
                on: worker
            ).map(\.threadID),
            [threadID]
        )
    }

    func testStaleOpenCatalogFetchCannotResurrectARecentlyArchivedThread() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let empty = "{\"threads\":[],\"nextCursor\":null}"
        let archivedRow = """
        {"threads":[{"provider":"claude","threadID":"\(threadID)","title":"Done","updatedAt":10,"archived":true,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":false,"rename":false,"archive":false,"unarchive":true}}],"nextCursor":null}
        """
        let staleOpenRow = """
        {"threads":[{"provider":"claude","threadID":"\(threadID)","title":"Done","updatedAt":10,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
        """
        let recorder = BlockingFirstWorkerSessionCommandRecorder(
            subsequentResults: [
                threadResult(archivedRow),
                threadResult(staleOpenRow),
                threadResult(empty),
                threadResult(empty),
                threadResult(empty),
                threadResult(archivedRow),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        // The open-catalog fetch starts before the archive...
        let staleLoad = Task {
            await service.loadThreads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            )
        }
        while recorder.configurations.isEmpty {
            await Task.yield()
        }

        // ...the archive lands while that fetch is still in flight...
        let archiveTask = Task {
            await service.setThreadArchived(
                kind: .claude,
                repositoryName: "terminal-relay",
                threadID: threadID,
                archived: true,
                on: worker
            )
        }
        while recorder.configurations.count < 2 {
            await Task.yield()
        }

        // ...and the stale listing lands afterwards, still naming the
        // thread open.
        recorder.finishFirst(with: threadResult(empty))
        let stale = await staleLoad.value
        let archived = await archiveTask.value

        XCTAssertTrue(archived)
        XCTAssertEqual(
            stale?.threads,
            [],
            "A listing captured before the archive must not restore the thread."
        )
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            ),
            []
        )
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: true,
                on: worker
            ).map(\.threadID),
            [threadID]
        )
    }

    func testUnarchiveFromAnotherClientShowsAsSoonAsAFreshListingReportsIt() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let empty = "{\"threads\":[],\"nextCursor\":null}"
        let archivedRow = """
        {"threads":[{"provider":"claude","threadID":"\(threadID)","title":"Done","updatedAt":10,"archived":true,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":false,"rename":false,"archive":false,"unarchive":true}}],"nextCursor":null}
        """
        let openRow = """
        {"threads":[{"provider":"claude","threadID":"\(threadID)","title":"Done","updatedAt":10,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
        """
        let recorder = WorkerSessionCommandRecorder(
            results: [
                threadResult(archivedRow),
                threadResult(empty),
                threadResult(empty),
                threadResult(empty),
                threadResult(archivedRow),
                threadResult(empty),
                threadResult(openRow),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let archived = await service.setThreadArchived(
            kind: .claude,
            repositoryName: "terminal-relay",
            threadID: threadID,
            archived: true,
            on: worker
        )
        XCTAssertTrue(archived)
        XCTAssertEqual(
            service.threads(repositoryName: "terminal-relay", archived: false, on: worker),
            []
        )

        // Another client unarchives; a fetch that starts after the archive
        // is authoritative, so the thread reappears immediately instead of
        // staying hidden for the tombstone lifetime.
        let refreshed = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )
        XCTAssertEqual(
            refreshed?.threads.map(\.threadID),
            [threadID],
            "An unarchive from another client must not be vetoed by the local archive tombstone."
        )
    }

    func testConcurrentCatalogLoadsCoalesceAndForcedReloadsSerialize() async {
        let worker = makeWorker()
        let firstThreadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let secondThreadID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let empty = "{\"threads\":[],\"nextCursor\":null}"
        func codexRow(_ threadID: String) -> String {
            """
            {"threads":[{"provider":"codex","threadID":"\(threadID)","title":"T","updatedAt":10,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
            """
        }
        let recorder = BlockingFirstWorkerSessionCommandRecorder(
            subsequentResults: [
                threadResult(empty),
                threadResult(codexRow(secondThreadID)),
                threadResult(empty),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let first = Task {
            await service.loadThreads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            )
        }
        while recorder.configurations.isEmpty {
            await Task.yield()
        }
        let coalesced = Task {
            await service.loadThreads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker,
                skipIfFresh: true
            )
        }
        let forced = Task {
            await service.loadThreads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            )
        }
        await Task.yield()
        recorder.finishFirst(with: threadResult(codexRow(firstThreadID)))

        let firstValue = await first.value
        let coalescedValue = await coalesced.value
        let forcedValue = await forced.value

        XCTAssertEqual(firstValue?.threads.map(\.threadID), [firstThreadID])
        XCTAssertEqual(
            coalescedValue,
            firstValue,
            "A freshness-tolerant caller shares the in-flight fetch."
        )
        XCTAssertEqual(
            forcedValue?.threads.map(\.threadID),
            [secondThreadID],
            "A forced reload runs after the in-flight fetch, so its listing is newer."
        )
        XCTAssertEqual(
            service.threads(repositoryName: "terminal-relay", archived: false, on: worker)
                .map(\.threadID),
            [secondThreadID],
            "The later fetch's listing is what remains; an older fetch can never overwrite it."
        )
        XCTAssertEqual(
            recorder.configurations.count,
            4,
            "Two fetches of two pages each; the coalesced caller issues no commands."
        )
    }

    func testStaleRefreshListingKeepsAJustResumedChatSessionUntilStopped() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let instanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let capabilities =
            #"{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
        let emptyStatus = WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data("\(WorkerSessionProtocol.legacyMarker)\n".utf8),
            standardError: Data()
        )
        let updateStatus = WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data("\(WorkerUpdateStatusProtocol.marker)\n".utf8),
            standardError: Data()
        )
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerChatProtocol.legacyMarker)
                        {"relayId":"\(instanceID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{}}

                        """.utf8
                    ),
                    standardError: Data()
                ),
                emptyStatus,
                updateStatus,
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                ),
                emptyStatus,
                updateStatus,
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let snapshot = await service.resumeThread(
            kind: .codex,
            repositoryName: "terminal-relay",
            threadID: threadID,
            launchDefaults: .standard,
            on: worker
        )
        XCTAssertEqual(snapshot?.instanceToken, instanceID)

        // A listing captured on the worker before the chat-start completed
        // must not erase the session this client just started.
        let staleRefresh = await service.refresh(worker: worker)
        XCTAssertEqual(
            staleRefresh?.sessions.map(\.instanceToken),
            [instanceID],
            "The just-started relay survives a listing that predates it."
        )
        XCTAssertEqual(service.response(for: worker.id)?.sessions.first?.threadID, threadID)

        let stopped = await service.stop(
            kind: .codex,
            repositoryName: "terminal-relay",
            instanceToken: instanceID,
            presentation: .chat,
            on: worker
        )
        XCTAssertTrue(stopped)

        let afterStop = await service.refresh(worker: worker)
        XCTAssertEqual(
            afterStop?.sessions,
            [],
            "The stop clears the started-session guard; the relay must not resurrect."
        )
    }

    func testStoppingAChatDemotesItsThreadCatalogRowImmediately() async {
        let worker = makeWorker()
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let instanceID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let capabilities =
            #"{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
        let recorder = WorkerSessionCommandRecorder(
            results: [
                threadResult(
                    """
                    {"threads":[{"provider":"codex","threadID":"\(threadID)","title":"Demote me","updatedAt":100,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
                    """
                ),
                threadResult(
                    """
                    {"threads":[],"nextCursor":null}
                    """
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerChatProtocol.legacyMarker)
                        {"relayId":"\(instanceID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{}}

                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(),
                    standardError: Data()
                ),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        _ = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )
        XCTAssertEqual(
            service.threads(repositoryName: "terminal-relay", archived: false, on: worker)
                .map(\.activityState),
            [.inactive]
        )

        _ = await service.resumeThread(
            kind: .codex,
            repositoryName: "terminal-relay",
            threadID: threadID,
            launchDefaults: .standard,
            on: worker
        )
        let promoted = service.threads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )
        XCTAssertEqual(promoted.map(\.activityState), [.relayActive])
        XCTAssertEqual(promoted.first?.activeInstanceToken, instanceID)

        _ = await service.stop(
            kind: .codex,
            repositoryName: "terminal-relay",
            instanceToken: instanceID,
            presentation: .chat,
            on: worker
        )
        let demoted = service.threads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker
        )
        XCTAssertEqual(
            demoted.map(\.activityState),
            [.inactive],
            "The dormant thread row must return the moment its chat stops, not a refresh cycle later."
        )
    }

    func testSameProviderAccountsStartAndRemainDistinctWithSameThreadID() async {
        let worker = makeWorker()
        let first = makeAccount(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            label: "Personal"
        )
        let second = makeAccount(
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            label: "Work"
        )
        let threadID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let firstRelay = "11111111-1111-4111-8111-111111111111"
        let secondRelay = "22222222-2222-4222-8222-222222222222"
        let capabilities =
            #"{"protocolVersion":2,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
        func result(account: ProviderAccountProfile, relayID: String) -> WorkerSessionCommandResult {
            WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data(
                    """
                    \(WorkerChatProtocol.marker)
                    {"relayId":"\(relayID)","provider":"codex","accountID":"\(account.accountID.rawValue)","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{}}
                    """.utf8
                ),
                standardError: Data()
            )
        }
        let recorder = WorkerSessionCommandRecorder(
            results: [
                result(account: first, relayID: firstRelay),
                result(account: second, relayID: secondRelay),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let firstSnapshot = await service.start(
            kind: .codex,
            account: first,
            repositoryName: "terminal-relay",
            launchDefaults: .standard,
            on: worker
        )
        let secondSnapshot = await service.start(
            kind: .codex,
            account: second,
            repositoryName: "terminal-relay",
            launchDefaults: .standard,
            on: worker
        )

        XCTAssertEqual(firstSnapshot?.accountID, first.accountID)
        XCTAssertEqual(secondSnapshot?.accountID, second.accountID)
        XCTAssertEqual(firstSnapshot?.threadID, secondSnapshot?.threadID)
        XCTAssertEqual(service.response(for: worker.id)?.sessions.count, 2)
        XCTAssertTrue(
            recorder.configurations[0].arguments.last?.contains(first.accountID.rawValue) == true
        )
        XCTAssertTrue(
            recorder.configurations[1].arguments.last?.contains(second.accountID.rawValue) == true
        )
    }

    func testAggregateCatalogPreservesSuccessfulAccountWhenAnotherFails() async {
        let worker = makeWorker()
        let first = makeAccount(
            id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            label: "Personal"
        )
        let second = makeAccount(
            id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            label: "Work"
        )
        let threadID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                WorkerSessionCommandResult(
                    exitCode: 0,
                    standardOutput: Data(
                        """
                        \(WorkerThreadProtocol.marker)
                        {"threads":[{"provider":"codex","accountID":"\(first.accountID.rawValue)","threadID":"\(threadID)","title":"Available","updatedAt":1,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":null}
                        """.utf8
                    ),
                    standardError: Data()
                ),
                WorkerSessionCommandResult(
                    exitCode: 1,
                    standardOutput: Data(),
                    standardError: Data("auth required".utf8)
                ),
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let response = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker,
            accounts: [first, second]
        )

        XCTAssertEqual(response?.threads.map(\.accountID), [first.accountID])
        XCTAssertEqual(
            service.threads(
                repositoryName: "terminal-relay",
                archived: false,
                on: worker
            ).map(\.accountID),
            [first.accountID]
        )
        XCTAssertNotNil(service.threadError(workerID: worker.id, account: second))
        XCTAssertNil(
            service.error(for: worker.id),
            "An account-scoped catalog failure must not mask healthy account results."
        )
    }

    func testAggregateCatalogSurfacesSignedOutAccountWithoutLaunchingIt() async {
        let worker = makeWorker()
        let signedOut = ProviderAccountProfile(
            accountID: ProviderAccountID(
                UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!
            ),
            provider: .codex,
            label: "Signed out",
            storageKind: .isolated,
            status: .authRequired
        )
        let recorder = WorkerSessionCommandRecorder(results: [])
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let response = await service.loadThreads(
            repositoryName: "terminal-relay",
            archived: false,
            on: worker,
            accounts: [signedOut]
        )

        XCTAssertEqual(response, WorkerThreadResponse(threads: [], nextCursor: nil))
        XCTAssertEqual(
            service.threadError(workerID: worker.id, account: signedOut),
            "Sign in to load this account's tasks."
        )
        XCTAssertTrue(recorder.configurations.isEmpty)

        service.dismissThreadError(workerID: worker.id, account: signedOut)
        XCTAssertNil(service.threadError(workerID: worker.id, account: signedOut))
    }

    private func threadResult(_ json: String) -> WorkerSessionCommandResult {
        WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data(
                "\(WorkerThreadProtocol.previousMarker)\n\(json)\n".utf8
            ),
            standardError: Data()
        )
    }

    private func makeWorker() -> ServerProfile {
        ServerProfile(
            name: "Worker 1",
            host: "worker.example.com",
            username: "relay"
        )
    }

    private func makeAccount(id: String, label: String) -> ProviderAccountProfile {
        ProviderAccountProfile(
            accountID: ProviderAccountID(UUID(uuidString: id)!),
            provider: .codex,
            label: label,
            storageKind: .isolated,
            status: .active
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
        if configuration.arguments.last?.contains(
            "'/usr/local/bin/terminal-relay-session' 'runtime-info'"
        ) == true {
            return WorkerSessionCommandResult(
                exitCode: 64,
                standardOutput: Data(),
                standardError: Data("unsupported command".utf8)
            )
        }
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
        if configuration.arguments.last?.contains(
            "'/usr/local/bin/terminal-relay-session' 'runtime-info'"
        ) == true {
            return WorkerSessionCommandResult(
                exitCode: 64,
                standardOutput: Data(),
                standardError: Data("unsupported command".utf8)
            )
        }
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

@MainActor
private final class RuntimeInspectionCommandRecorder {
    private(set) var requestedUpdate = false

    func run(_ configuration: SSHLaunchConfiguration) async -> WorkerSessionCommandResult {
        let command = configuration.arguments.last ?? ""
        if command.contains("'runtime-info'") {
            return WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data(
                    """
                    \(WorkerRuntimeInfoProtocol.marker)
                    runtime|2000000000|1|1|agent-sessions,runtime-updates-v1,threads-v1
                    """.utf8
                ),
                standardError: Data()
            )
        }
        if command.contains("'runtime-update-status'") {
            return WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data("\(WorkerRuntimeUpdateStatusProtocol.marker)\n".utf8),
                standardError: Data()
            )
        }
        if command.contains("'runtime-update-request'") {
            requestedUpdate = true
            return WorkerSessionCommandResult(
                exitCode: 64,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        if command.contains("'update-status'") {
            return WorkerSessionCommandResult(
                exitCode: 0,
                standardOutput: Data("\(WorkerUpdateStatusProtocol.marker)\n".utf8),
                standardError: Data()
            )
        }
        return WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data("\(WorkerSessionProtocol.legacyMarker)\n".utf8),
            standardError: Data()
        )
    }
}
