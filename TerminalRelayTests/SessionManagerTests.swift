import XCTest
@testable import TerminalRelay

@MainActor
final class SessionManagerTests: XCTestCase {
    func testOpeningTheSameProjectAndAgentSelectsItsExistingSession() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()

        let firstResult = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        )
        guard case .opened(let firstSession) = firstResult else {
            return XCTFail("Expected a new session")
        }

        let secondResult = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        )
        guard case .selectedExisting(let selectedSession) = secondResult else {
            return XCTFail("Expected the existing project session")
        }

        XCTAssertTrue(selectedSession === firstSession)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.selectedSessionID, firstSession.id)
    }

    func testOpeningMultipleSessionsAcrossProjectsAndAgentKinds() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let firstProject = makeProject(name: "Terminal Relay", server: server)
        let secondProject = makeProject(name: "Website API", server: server)
        let manager = SessionManager()

        let codexResult = manager.open(
            project: firstProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard,
            instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
        )
        guard case .opened = codexResult else {
            return XCTFail("Expected the first Codex session to open")
        }

        let claudeResult = manager.open(
            project: secondProject,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: "11111111-2222-" + "4333-8444-555555555555"
        )
        guard case .opened = claudeResult else {
            return XCTFail("Codex and Claude should be able to share a worker")
        }

        let secondCodexResult = manager.open(
            project: secondProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard,
            instanceToken: "22222222-3333-" + "4444-8555-666666666666"
        )
        guard case .opened(let secondCodexSession) = secondCodexResult else {
            return XCTFail("Expected another Codex session to open")
        }

        XCTAssertEqual(manager.selectedSessionID, secondCodexSession.id)
        XCTAssertEqual(manager.sessions.count, 3)
    }

    func testProjectSessionQueriesAndIdentityUseProjectValues() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "terminal-relay", server: server)
        let manager = SessionManager()

        let result = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        )
        guard case .opened(let session) = result else {
            return XCTFail("Expected a new session")
        }

        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(session.projectName, "terminal-relay")
        XCTAssertEqual(session.workingDirectory, "/workspace/terminal-relay")
        XCTAssertEqual(session.title, "terminal-relay · Claude")
        XCTAssertEqual(session.displayTitle, "Claude 1")
        XCTAssertEqual(session.sequenceNumber, 1)
        XCTAssertTrue(manager.session(projectID: project.id, kind: .claude) === session)
        XCTAssertTrue(manager.activeSession(projectID: project.id, kind: .claude) === session)
        XCTAssertTrue(manager.activeSession(for: server, kind: .claude) === session)
        XCTAssertEqual(manager.sessions(forProjectID: project.id).map(\.id), [session.id])
        XCTAssertEqual(manager.sessions(for: server).map(\.id), [session.id])
    }

    func testExitedSessionRemainsInProjectHistoryAndOpeningAgainAppendsANewSession() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()

        let firstResult = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        )
        guard case .opened(let firstSession) = firstResult else {
            return XCTFail("Expected the first session to open")
        }

        firstSession.processTerminated(source: firstSession.terminalView, exitCode: 0)
        await Task.yield()

        XCTAssertEqual(firstSession.status, .disconnected(0))
        XCTAssertTrue(manager.activeSession(projectID: project.id, kind: .codex) === firstSession)

        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(projects: [project.displayName], sessions: []),
            launchDefaults: .standard
        )

        XCTAssertEqual(firstSession.status, .exited(0))
        XCTAssertEqual(manager.sessions(forProjectID: project.id).map(\.id), [firstSession.id])
        XCTAssertNil(manager.activeSession(projectID: project.id, kind: .codex))

        let secondResult = manager.openConfirmedRemote(
            project: project,
            on: server,
            snapshot: WorkerSessionSnapshot(
                kind: .codex,
                repositoryName: project.displayName,
                attachedClientCount: 0,
                instanceToken: "11111111-2222-" + "4333-8444-555555555555"
            )
        )!
        guard case .opened(let secondSession) = secondResult else {
            return XCTFail("Expected a distinct second session")
        }

        XCTAssertFalse(secondSession === firstSession)
        XCTAssertEqual(secondSession.sequenceNumber, 2)
        XCTAssertEqual(secondSession.displayTitle, "Codex 2")
        XCTAssertEqual(
            manager.sessions(forProjectID: project.id).map(\.id),
            [firstSession.id, secondSession.id]
        )
        XCTAssertTrue(manager.activeSession(projectID: project.id, kind: .codex) === secondSession)
        XCTAssertTrue(manager.session(projectID: project.id, kind: .codex) === secondSession)
    }

    func testDisplayTitlePrefersNormalizedTerminalTitle() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let result = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        )
        guard case .opened(let session) = result else {
            return XCTFail("Expected a new session")
        }

        session.setTerminalTitle(
            source: session.terminalView,
            title: "  Review   release\n topology  "
        )
        await Task.yield()

        XCTAssertEqual(session.displayTitle, "Review release topology")

        session.setTerminalTitle(
            source: session.terminalView,
            title: "019f89a7-f067-7e41-a7ec-76d0ed91e684"
        )
        await Task.yield()

        XCTAssertEqual(session.displayTitle, "Review release topology")
    }

    func testCodexTerminalTitleTracksWorkingStateWithoutChangingTheChatTitle() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!

        session.setTerminalTitle(
            source: session.terminalView,
            title: "Build native macOS terminal hub | Working"
        )
        await Task.yield()

        XCTAssertTrue(session.isWorking)
        XCTAssertEqual(session.displayTitle, "Build native macOS terminal hub")

        session.setTerminalTitle(
            source: session.terminalView,
            title: "Build native macOS terminal hub | Ready"
        )
        await Task.yield()

        XCTAssertFalse(session.isWorking)
        XCTAssertEqual(session.displayTitle, "Build native macOS terminal hub")
    }

    func testUnnamedCodexThreadUsesReadableFallbackInsteadOfItsIdentifier() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!

        session.setTerminalTitle(
            source: session.terminalView,
            title: "019f89a7-f067-7e41-a7ec-76d0ed91e684 | Ready"
        )
        await Task.yield()

        XCTAssertNil(session.terminalTitle)
        XCTAssertEqual(session.displayTitle, "Codex 1")
        XCTAssertFalse(session.isWorking)

        session.setTerminalTitle(
            source: session.terminalView,
            title: "Name the active thread | Ready"
        )
        await Task.yield()
        session.setTerminalTitle(
            source: session.terminalView,
            title: "019f89a7-f067-7e41-a7ec-76d0ed91e684 | Working"
        )
        await Task.yield()

        XCTAssertEqual(session.displayTitle, "Name the active thread")
        XCTAssertTrue(session.isWorking)
    }

    func testClaudeProgressReportsTrackWorkingStateAcrossSplitTerminalInput() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        ).localSession!
        let terminal = session.terminalView.getTerminal()

        terminal.feed(text: "ordinary terminal output")
        await Task.yield()
        XCTAssertFalse(session.isWorking)

        let workingSequence = Array("\u{1B}]9;4;3;\u{7}".utf8)
        terminal.feed(byteArray: Array(workingSequence.prefix(5)))
        terminal.feed(byteArray: Array(workingSequence.dropFirst(5)))
        await Task.yield()
        XCTAssertTrue(session.isWorking)

        terminal.feed(text: "\u{1B}]9;4;0;\u{7}")
        await Task.yield()
        XCTAssertFalse(session.isWorking)
    }

    func testSequenceNumberDoesNotResetWhenHistoryIsExplicitlyClosed() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let firstSession = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!

        firstSession.processTerminated(source: firstSession.terminalView, exitCode: 0)
        await Task.yield()
        manager.close(sessionID: firstSession.id)
        XCTAssertTrue(manager.sessions(forProjectID: project.id).isEmpty)

        let secondSession = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!

        XCTAssertEqual(secondSession.sequenceNumber, 2)
        XCTAssertEqual(secondSession.displayTitle, "Codex 2")
    }

    func testClosingProjectSessionsLeavesOtherProjectsAlone() {
        let firstServer = makeServer(name: "Worker 1", host: "worker-1")
        let secondServer = makeServer(name: "Worker 2", host: "worker-2")
        let firstProject = makeProject(name: "Terminal Relay", server: firstServer)
        let secondProject = makeProject(name: "Website API", server: secondServer)
        let manager = SessionManager()

        manager.open(
            project: firstProject,
            on: firstServer,
            kind: .codex,
            launchDefaults: .standard
        )
        manager.open(
            project: firstProject,
            on: firstServer,
            kind: .claude,
            launchDefaults: .standard
        )
        let otherResult = manager.open(
            project: secondProject,
            on: secondServer,
            kind: .codex,
            launchDefaults: .standard
        )

        manager.closeSessions(forProjectID: firstProject.id)

        XCTAssertTrue(manager.sessions(forProjectID: firstProject.id).isEmpty)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertTrue(manager.sessions.first === otherResult.localSession)
    }

    func testReconcileRestoresDetachedRemoteSessionUnderMatchingProject() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let snapshot = WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: project.displayName,
            attachedClientCount: 2,
            instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
        )

        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [snapshot]
            ),
            launchDefaults: .standard
        )

        let session = manager.session(projectID: project.id, kind: .codex)
        XCTAssertEqual(session?.status, .remoteRunning)
        XCTAssertEqual(session?.remoteAttachedClientCount, 2)
        XCTAssertEqual(session?.sequenceNumber, 1)
        XCTAssertTrue(session?.status.occupiesSlot == true)
        XCTAssertEqual(
            manager.occupant(for: server, kind: .codex)?.repositoryName,
            project.displayName
        )
    }

    func testReconcileSameRepositoryReplacementEndsOldInstanceAndCreatesNewSession() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let oldToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let replacementToken = "11111111-2222-" + "4333-8444-555555555555"

        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: project.displayName,
                        attachedClientCount: 1,
                        instanceToken: oldToken
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let oldSession = manager.session(projectID: project.id, kind: .codex)!

        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: project.displayName,
                        attachedClientCount: 2,
                        instanceToken: replacementToken
                    )
                ]
            ),
            launchDefaults: .standard
        )

        let replacement = manager.activeSession(projectID: project.id, kind: .codex)
        XCTAssertEqual(oldSession.instanceToken, oldToken)
        XCTAssertEqual(oldSession.status, .exited(nil))
        XCTAssertNotEqual(replacement?.id, oldSession.id)
        XCTAssertEqual(replacement?.instanceToken, replacementToken)
        XCTAssertEqual(replacement?.status, .remoteRunning)
        XCTAssertEqual(replacement?.remoteAttachedClientCount, 2)
        XCTAssertEqual(replacement?.sequenceNumber, 2)
        XCTAssertEqual(manager.sessions(forProjectID: project.id).count, 2)
        XCTAssertTrue(manager.occupant(for: server, kind: .codex)?.localSession === replacement)
    }

    func testRemoteSessionDoesNotBlockOpeningAnotherProject() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()

        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .claude,
                        repositoryName: "unconfigured-project",
                        attachedClientCount: 0,
                        instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
                    )
                ]
            ),
            launchDefaults: .standard
        )

        let result = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: "11111111-2222-" + "4333-8444-555555555555"
        )
        guard case .opened(let session) = result else {
            return XCTFail("Expected a separate Claude session to open")
        }
        XCTAssertEqual(session.projectID, project.id)
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testExplicitStartUsesStatusThenStartAndKeepsReturnedInstanceToken() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                Self.emptyStatusResult(),
                Self.statusResult(
                    kind: .codex,
                    repositoryName: project.displayName,
                    instanceToken: instanceToken
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let result = await manager.openAfterRefresh(
            project: project,
            on: server,
            kind: .codex,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        guard case .opened(let session) = result else {
            return XCTFail("Expected the exact started session to open")
        }
        XCTAssertEqual(session.instanceToken, instanceToken)
        XCTAssertEqual(session.status, .connecting)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStatusConfiguration(for: server),
                SSHCommandBuilder.workerSessionStartConfiguration(
                    for: server,
                    kind: .codex,
                    repositoryName: project.displayName,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testExplicitStartForKnownSameRepositoryStillUsesReturnedExactSnapshot() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let statusToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let startedToken = "11111111-2222-" + "4333-8444-555555555555"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                Self.statusResult(
                    kind: .claude,
                    repositoryName: project.displayName,
                    instanceToken: statusToken
                ),
                Self.statusResult(
                    kind: .claude,
                    repositoryName: project.displayName,
                    instanceToken: startedToken
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let result = await manager.openAfterRefresh(
            project: project,
            on: server,
            kind: .claude,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        guard case .opened(let session) = result else {
            return XCTFail("Expected the returned instance to get a distinct session")
        }
        XCTAssertEqual(session.instanceToken, startedToken)
        XCTAssertEqual(session.status, .connecting)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertEqual(
            manager.sessions.first(where: { $0.instanceToken == statusToken })?.status,
            .remoteRunning
        )
        XCTAssertEqual(recorder.configurations.count, 2)
        XCTAssertEqual(
            recorder.configurations.last,
            SSHCommandBuilder.workerSessionStartConfiguration(
                for: server,
                kind: .claude,
                repositoryName: project.displayName,
                launchDefaults: .standard
            )
        )
    }

    func testExplicitStartRunsWhenStatusReportsAnotherRepository() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let startedToken = "11111111-2222-" + "4333-8444-555555555555"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                Self.statusResult(
                    kind: .codex,
                    repositoryName: "another-repository",
                    instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
                ),
                Self.statusResult(
                    kind: .codex,
                    repositoryName: project.displayName,
                    instanceToken: startedToken
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let result = await manager.openAfterRefresh(
            project: project,
            on: server,
            kind: .codex,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        guard case .opened(let session) = result else {
            return XCTFail("Expected a new Codex session")
        }
        XCTAssertEqual(session.instanceToken, startedToken)
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStatusConfiguration(for: server),
                SSHCommandBuilder.workerSessionStartConfiguration(
                    for: server,
                    kind: .codex,
                    repositoryName: project.displayName,
                    launchDefaults: .standard
                )
            ]
        )
        XCTAssertEqual(manager.sessions.count, 1)
    }

    func testReconnectReplacesTheTerminalViewWithoutChangingSidebarIdentity() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let original = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        XCTAssertEqual(
            original.instanceToken,
            "aaaaaaaa-bbbb-" + "4ccc-8ddd-eeeeeeeeeeee"
        )

        original.processTerminated(source: original.terminalView, exitCode: nil)
        await Task.yield()
        XCTAssertEqual(original.status, .disconnected(nil))

        let service = WorkerSessionService { _ in
            Self.statusResult(
                kind: .codex,
                repositoryName: project.displayName,
                instanceToken: original.instanceToken
            )
        }
        let replacement = await manager.reconnectAfterRefresh(
            sessionID: original.id,
            project: project,
            on: server,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        XCTAssertNotNil(replacement)
        XCTAssertFalse(replacement === original)
        XCTAssertEqual(replacement?.id, original.id)
        XCTAssertEqual(replacement?.sequenceNumber, original.sequenceNumber)
        XCTAssertNotEqual(replacement?.terminalViewIdentity, original.terminalViewIdentity)
        XCTAssertEqual(replacement?.status, .connecting)
        XCTAssertEqual(
            replacement?.instanceToken,
            original.instanceToken
        )
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(manager.selectedSessionID, original.id)
    }

    func testReconnectRejectsSameRepositoryReplacementInstance() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let oldSession = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        oldSession.processTerminated(source: oldSession.terminalView, exitCode: 255)
        await Task.yield()
        let replacementToken = "11111111-2222-" + "4333-8444-555555555555"
        let recorder = WorkerSessionCommandRecorder(
            results: [
                Self.statusResult(
                    kind: .codex,
                    repositoryName: project.displayName,
                    instanceToken: replacementToken
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let replacement = await manager.reconnectAfterRefresh(
            sessionID: oldSession.id,
            project: project,
            on: server,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        XCTAssertNil(replacement)
        XCTAssertEqual(oldSession.status, .exited(255))
        XCTAssertEqual(oldSession.instanceToken, "aaaaaaaa-bbbb-" + "4ccc-8ddd-eeeeeeeeeeee")
        let remoteReplacement = manager.activeSession(projectID: project.id, kind: .codex)
        XCTAssertNotEqual(remoteReplacement?.id, oldSession.id)
        XCTAssertEqual(remoteReplacement?.instanceToken, replacementToken)
        XCTAssertEqual(remoteReplacement?.status, .remoteRunning)
        XCTAssertEqual(
            recorder.configurations,
            [SSHCommandBuilder.workerSessionStatusConfiguration(for: server)]
        )
    }

    func testFailedStatusRefreshDoesNotReconnectOrStartANewAgent() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        session.processTerminated(source: session.terminalView, exitCode: 255)
        await Task.yield()
        let originalTerminalIdentity = session.terminalViewIdentity
        let service = WorkerSessionService { _ in
            WorkerSessionCommandResult(
                exitCode: 127,
                standardOutput: Data(),
                standardError: Data()
            )
        }

        let result = await manager.openAfterRefresh(
            project: project,
            on: server,
            kind: .codex,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        XCTAssertNil(result)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(session.status, .disconnected(255))
        XCTAssertTrue(session.status.occupiesSlot)
        XCTAssertTrue(session.status.canReconnect)
        XCTAssertEqual(session.status.label, "Disconnected (255)")
        XCTAssertEqual(session.terminalViewIdentity, originalTerminalIdentity)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertNotNil(service.error(for: server.id))
    }

    func testOverlappingStatusRefreshDoesNotReconnectOrStartANewAgent() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        session.processTerminated(source: session.terminalView, exitCode: 255)
        await Task.yield()

        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let inFlightRefresh = Task {
            await manager.refresh(
                worker: server,
                projects: [project],
                launchDefaults: .standard,
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }

        let result = await manager.openAfterRefresh(
            project: project,
            on: server,
            kind: .codex,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        XCTAssertNil(result)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(session.status, .disconnected(255))
        XCTAssertEqual(manager.sessions.count, 1)

        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: project.displayName,
                instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
            )
        )
        let refreshSucceeded = await inFlightRefresh.value
        XCTAssertTrue(refreshSucceeded)
    }

    func testReconnectRequiresMatchingKindAndRepositoryConfirmation() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        session.processTerminated(source: session.terminalView, exitCode: 75)
        await Task.yield()

        let service = WorkerSessionService { _ in
            Self.statusResult(
                kind: .codex,
                repositoryName: "another-repository",
                instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
            )
        }
        let replacement = await manager.reconnectAfterRefresh(
            sessionID: session.id,
            project: project,
            on: server,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        XCTAssertNil(replacement)
        XCTAssertTrue(manager.sessions.first === session)
        XCTAssertEqual(session.status, .exited(75))
    }

    func testExplicitStopTransitionsThePersistentSessionToExited() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let staleInstanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let latestInstanceToken = "11111111-2222-" + "4333-8444-555555555555"
        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: staleInstanceToken
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let staleSession = manager.session(projectID: project.id, kind: .codex)!
        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: latestInstanceToken
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let session = manager.activeSession(projectID: project.id, kind: .codex)!
        XCTAssertFalse(session === staleSession)
        XCTAssertEqual(staleSession.status, .exited(nil))
        XCTAssertEqual(session.instanceToken, latestInstanceToken)
        let recorder = WorkerSessionCommandRecorder(
            results: [
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

        let stopped = await manager.stopAgent(
            sessionID: session.id,
            on: server,
            using: service
        )

        XCTAssertTrue(stopped)
        XCTAssertEqual(session.status, .exited(nil))
        XCTAssertFalse(session.status.occupiesSlot)
        XCTAssertNil(manager.occupant(for: server, kind: .codex))
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: server,
                    kind: .codex,
                    repositoryName: project.displayName,
                    instanceToken: latestInstanceToken
                )
            ]
        )
    }

    func testStopRejectsStaleSameRepositoryInstanceAfterRefresh() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let oldToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let replacementToken = "11111111-2222-" + "4333-8444-555555555555"
        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .claude,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: oldToken
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let staleSession = manager.session(projectID: project.id, kind: .claude)!
        let recorder = WorkerSessionCommandRecorder(
            results: [
                Self.statusResult(
                    kind: .claude,
                    repositoryName: project.displayName,
                    instanceToken: replacementToken
                )
            ]
        )
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let stopped = await manager.stopAgentAfterRefresh(
            sessionID: staleSession.id,
            on: server,
            projects: [project],
            launchDefaults: .standard,
            using: service
        )

        XCTAssertFalse(stopped)
        XCTAssertEqual(staleSession.status, .exited(nil))
        XCTAssertEqual(staleSession.instanceToken, oldToken)
        let replacement = manager.activeSession(projectID: project.id, kind: .claude)
        XCTAssertEqual(replacement?.instanceToken, replacementToken)
        XCTAssertEqual(replacement?.status, .remoteRunning)
        XCTAssertEqual(
            recorder.configurations,
            [SSHCommandBuilder.workerSessionStatusConfiguration(for: server)]
        )
    }

    func testStopRejectsAMismatchedWorkerBeforeChangingSessionState() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let otherServer = makeServer(name: "Worker 2", host: "worker-2")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .claude,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let session = manager.session(projectID: project.id, kind: .claude)!
        let recorder = WorkerSessionCommandRecorder(results: [])
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let stopped = await manager.stopAgent(
            sessionID: session.id,
            on: otherServer,
            using: service
        )

        XCTAssertFalse(stopped)
        XCTAssertEqual(session.status, .remoteRunning)
        XCTAssertTrue(recorder.configurations.isEmpty)
    }

    func testStopRejectsAMismatchedRepositoryBeforeChangingSessionState() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName, "another-repository"],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: "another-repository",
                        attachedClientCount: 0,
                        instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let recorder = WorkerSessionCommandRecorder(results: [])
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }

        let stopped = await manager.stopAgent(
            sessionID: session.id,
            on: server,
            using: service
        )

        XCTAssertFalse(stopped)
        XCTAssertEqual(session.status, .connecting)
        XCTAssertTrue(recorder.configurations.isEmpty)
    }

    private static func statusResult(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) -> WorkerSessionCommandResult {
        WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data(
                """
                __TERMINAL_RELAY_SESSION_V1__
                session|\(kind.rawValue)|\(repositoryName)|0|\(instanceToken)
                """.utf8
            ),
            standardError: Data()
        )
    }

    private static func emptyStatusResult() -> WorkerSessionCommandResult {
        WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data("__TERMINAL_RELAY_SESSION_V1__\n".utf8),
            standardError: Data()
        )
    }

    private func makeServer(name: String, host: String) -> ServerProfile {
        ServerProfile(
            name: name,
            host: host,
            username: "relay",
            workingDirectory: "/legacy/server/workspace"
        )
    }

    private func makeProject(name: String, server: ServerProfile) -> ProjectProfile {
        ProjectProfile(
            serverID: server.id,
            repositoryOwner: "owner",
            repositoryName: name.lowercased().replacingOccurrences(of: " ", with: "-")
        )
    }
}

@MainActor
private extension SessionManager {
    func open(
        project: ProjectProfile,
        on server: ServerProfile,
        kind: AgentKind,
        launchDefaults _: AgentLaunchDefaults,
        instanceToken: String = "aaaaaaaa-bbbb-" + "4ccc-8ddd-eeeeeeeeeeee"
    ) -> SessionOpenResult {
        guard let result = openConfirmedRemote(
            project: project,
            on: server,
            snapshot: WorkerSessionSnapshot(
                kind: kind,
                repositoryName: project.displayName,
                attachedClientCount: 0,
                instanceToken: instanceToken
            )
        ) else {
            preconditionFailure("Test snapshot should be valid")
        }
        return result
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
private final class BlockingWorkerSessionCommandRecorder {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<WorkerSessionCommandResult, Never>?

    func run(_ configuration: SSHLaunchConfiguration) async -> WorkerSessionCommandResult {
        callCount += 1
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func finish(with result: WorkerSessionCommandResult) {
        continuation?.resume(returning: result)
        continuation = nil
    }
}
