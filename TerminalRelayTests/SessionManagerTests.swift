import Combine
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

    func testClaudeDisplayTitleRemovesActivityGlyph() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let session = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        ).localSession!

        session.setTerminalTitle(
            source: session.terminalView,
            title: "✳ Claude Code"
        )
        await Task.yield()

        XCTAssertEqual(session.displayTitle, "Claude Code")
        XCTAssertFalse(session.isWorking)
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

    func testCompletedBackgroundSessionStaysUnreadUntilSelected() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let sessionIdentifier = "01234567-89ab-4def-8abc-0123456789ab"
        let manager = SessionManager(taskCompletionHandler: { _ in })

        func reconcile(reportedWorking: Bool) {
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
                            instanceToken: sessionIdentifier,
                            title: "Investigate open incident",
                            reportedWorking: reportedWorking
                        )
                    ]
                ),
                launchDefaults: .standard
            )
        }

        reconcile(reportedWorking: true)
        let session = manager.session(projectID: project.id, kind: .codex)!
        reconcile(reportedWorking: false)

        XCTAssertTrue(manager.unreadSessionIDs.contains(session.id))

        manager.selectSession(session.id)

        XCTAssertFalse(manager.unreadSessionIDs.contains(session.id))

        reconcile(reportedWorking: true)
        reconcile(reportedWorking: false)

        XCTAssertFalse(manager.unreadSessionIDs.contains(session.id))
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
        XCTAssertEqual(session.threadID, "019f89a7-f067-7e41-a7ec-76d0ed91e684")
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

    func testStableWorkingStateDoesNotPublishAndCompletionEdgeCountsOnce() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let session = TerminalSession(
            project: project,
            server: server,
            kind: .claude,
            sequenceNumber: 1,
            instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab",
            initialStatus: .running
        )
        let terminal = session.terminalView.getTerminal()
        var publicationCount = 0
        let observation = session.objectWillChange.sink {
            publicationCount += 1
        }
        defer { observation.cancel() }

        terminal.feed(text: "\u{1B}]9;4;3;\u{7}")
        await Task.yield()
        XCTAssertTrue(session.isWorking)
        XCTAssertEqual(session.taskCompletionCount, 0)

        let publicationsAfterStarting = publicationCount
        terminal.feed(text: "\u{1B}]9;4;3;\u{7}")
        await Task.yield()

        XCTAssertTrue(session.isWorking)
        XCTAssertEqual(session.taskCompletionCount, 0)
        XCTAssertEqual(publicationCount, publicationsAfterStarting)

        terminal.feed(text: "\u{1B}]9;4;0;\u{7}")
        await Task.yield()
        XCTAssertFalse(session.isWorking)
        XCTAssertEqual(session.taskCompletionCount, 1)

        let publicationsAfterCompleting = publicationCount
        terminal.feed(text: "\u{1B}]9;4;0;\u{7}")
        await Task.yield()

        XCTAssertFalse(session.isWorking)
        XCTAssertEqual(session.taskCompletionCount, 1)
        XCTAssertEqual(publicationCount, publicationsAfterCompleting)
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

    func testClosingTheLastSelectedProjectSessionDoesNotSelectAnotherProject() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let firstProject = makeProject(name: "Terminal Relay", server: server)
        let secondProject = makeProject(name: "Website API", server: server)
        let manager = SessionManager()
        let firstSession = manager.open(
            project: firstProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        let secondSession = manager.open(
            project: secondProject,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: "11111111-2222-" + "4333-8444-555555555555"
        ).localSession!
        firstSession.processTerminated(source: firstSession.terminalView, exitCode: 0)
        await Task.yield()
        manager.reconcile(
            worker: server,
            projects: [firstProject, secondProject],
            response: WorkerSessionResponse(projects: [], sessions: []),
            launchDefaults: .standard
        )
        manager.selectSession(firstSession.id)

        manager.close(sessionID: firstSession.id)

        XCTAssertNil(manager.selectedSessionID)
        XCTAssertTrue(manager.sessions.contains { $0.id == secondSession.id })
    }

    func testRestoredCachedSessionVanishesWhenTheWorkerNoLongerListsIt() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()

        manager.restoreCachedSessions(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .claude,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab",
                        presentation: .chat
                    )
                ]
            ),
            launchDefaults: .standard
        )

        let restored = manager.session(projectID: project.id, kind: .claude)
        XCTAssertEqual(restored?.status, .remoteRunning)

        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(projects: [project.displayName], sessions: []),
            launchDefaults: .standard
        )

        XCTAssertTrue(
            manager.sessions.isEmpty,
            "An unconfirmed cached row must be removed, not left as an exited ghost."
        )
    }

    func testRestoredCachedSessionConfirmedByARefreshKeepsTheExitedTreatment() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let response = WorkerSessionResponse(
            projects: [project.displayName],
            sessions: [
                WorkerSessionSnapshot(
                    kind: .claude,
                    repositoryName: project.displayName,
                    attachedClientCount: 0,
                    instanceToken: instanceToken,
                    presentation: .chat
                )
            ]
        )

        manager.restoreCachedSessions(
            worker: server,
            projects: [project],
            response: response,
            launchDefaults: .standard
        )
        let restored = manager.session(projectID: project.id, kind: .claude)
        manager.reconcile(
            worker: server,
            projects: [project],
            response: response,
            launchDefaults: .standard
        )
        manager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(projects: [project.displayName], sessions: []),
            launchDefaults: .standard
        )

        XCTAssertTrue(manager.session(projectID: project.id, kind: .claude) === restored)
        XCTAssertEqual(
            restored?.status,
            .exited(nil),
            "A worker-confirmed row keeps the normal exited treatment when it vanishes."
        )
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

    func testReconcileUsesAndRefreshesRemoteConversationTitle() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"

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
                        instanceToken: instanceToken,
                        title: "Improve terminal titles",
                        threadID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
                    )
                ]
            ),
            launchDefaults: .standard
        )

        let session = manager.session(projectID: project.id, kind: .codex)
        XCTAssertEqual(session?.displayTitle, "Improve terminal titles")
        XCTAssertEqual(session?.threadID, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

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
                        instanceToken: instanceToken,
                        title: "Polish terminal titles",
                        threadID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
                    )
                ]
            ),
            launchDefaults: .standard
        )

        XCTAssertTrue(manager.session(projectID: project.id, kind: .codex) === session)
        XCTAssertEqual(session?.displayTitle, "Polish terminal titles")
        XCTAssertEqual(session?.threadID, "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")

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
                        instanceToken: instanceToken,
                        reportedWorking: false
                    )
                ]
            ),
            launchDefaults: .standard
        )

        XCTAssertEqual(session?.displayTitle, "Codex 1")
    }

    func testClaudeChatSessionWithoutSnapshotThreadIDKeepsCacheIdentityInSync() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let session = TerminalSession(
            project: project,
            server: server,
            kind: .claude,
            sequenceNumber: 1,
            instanceToken: instanceToken,
            presentation: .chat
        )

        XCTAssertEqual(session.threadID, instanceToken)
        XCTAssertEqual(session.chatCoordinator?.identity.providerThreadID, session.threadID)
    }

    func testRemoteRefreshPreservesLiveCodexWorkingStateAndUsesReportedState() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let session = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard,
            instanceToken: instanceToken
        ).localSession!

        session.setTerminalTitle(
            source: session.terminalView,
            title: "Fix spinner state | Working"
        )
        await Task.yield()
        XCTAssertTrue(session.isWorking)

        session.applyRemoteSnapshot(
            WorkerSessionSnapshot(
                kind: .codex,
                repositoryName: project.displayName,
                attachedClientCount: 1,
                instanceToken: instanceToken,
                title: "Fix spinner state",
                reportedWorking: true
            )
        )

        XCTAssertEqual(session.displayTitle, "Fix spinner state")
        XCTAssertTrue(session.isWorking)

        session.applyRemoteSnapshot(
            WorkerSessionSnapshot(
                kind: .codex,
                repositoryName: project.displayName,
                attachedClientCount: 1,
                instanceToken: instanceToken,
                title: "Fix spinner state",
                reportedWorking: false
            )
        )
        session.setTerminalTitle(
            source: session.terminalView,
            title: "Fix spinner state | Ready"
        )
        await Task.yield()

        XCTAssertFalse(session.isWorking)
    }

    func testTaskCompletionNotificationsFollowPreferenceAndIgnoreAgentStops() {
        let suiteName = "TerminalRelayTests.TaskCompletionNotifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        var notifications: [String] = []
        let manager = SessionManager(defaults: defaults) { session in
            notifications.append(
                "\(session.kind.displayName)|\(session.projectName)|\(session.displayTitle)"
            )
        }

        func reconcile(reportedWorking: Bool) {
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
                            instanceToken: instanceToken,
                            title: "Review notification behavior",
                            reportedWorking: reportedWorking
                        )
                    ]
                ),
                launchDefaults: .standard
            )
        }

        reconcile(reportedWorking: true)
        reconcile(reportedWorking: false)
        XCTAssertTrue(notifications.isEmpty)

        defaults.set(
            true,
            forKey: ApplicationSettings.StorageKey.showTaskCompletionNotifications
        )
        reconcile(reportedWorking: true)
        reconcile(reportedWorking: false)

        XCTAssertEqual(
            notifications,
            ["Codex|terminal-relay|Review notification behavior"]
        )

        reconcile(reportedWorking: true)
        manager.session(projectID: project.id, kind: .codex)?.beginRemoteStop()
        XCTAssertEqual(notifications.count, 1)
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

    func testNewSessionUsesOneStartCommandAndKeepsReturnedInstanceToken() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let recorder = WorkerSessionCommandRecorder(
            results: [
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

        let result = await manager.openNewSession(
            project: project,
            on: server,
            kind: .codex,
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
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: server,
                    kind: .codex,
                    repositoryName: project.displayName,
                    threadID: nil,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testNewSessionShowsPendingPanelAndRefreshesNativeChatWorkspace() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        var callbackSession: TerminalSession?

        let start = Task {
            await manager.openNewSession(
                project: project,
                on: server,
                kind: .claude,
                launchDefaults: .standard,
                onPendingSession: { callbackSession = $0 },
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }

        let pendingSession = try! XCTUnwrap(manager.sessions.last)
        XCTAssertTrue(callbackSession === pendingSession)
        XCTAssertTrue(pendingSession.isLaunchPending)
        XCTAssertNil(pendingSession.launchFailureMessage)
        XCTAssertEqual(pendingSession.status, .connecting)
        XCTAssertEqual(manager.selectedSessionID, pendingSession.id)
        let pendingID = pendingSession.id
        let pendingTerminalIdentity = pendingSession.terminalViewIdentity
        let pendingWorkspaceIdentity = pendingSession.workspaceViewIdentity

        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        recorder.finish(
            with: Self.statusResult(
                kind: .claude,
                repositoryName: project.displayName,
                instanceToken: instanceToken
            )
        )
        let result = await start.value

        guard case .opened(let session) = result else {
            return XCTFail("Expected the pending session to finish opening")
        }
        XCTAssertFalse(session === pendingSession)
        XCTAssertEqual(session.id, pendingID)
        XCTAssertEqual(session.terminalViewIdentity, pendingTerminalIdentity)
        XCTAssertNotEqual(session.workspaceViewIdentity, pendingWorkspaceIdentity)
        XCTAssertEqual(session.instanceToken, instanceToken)
        XCTAssertFalse(session.isLaunchPending)
        XCTAssertNil(session.launchFailureMessage)
        XCTAssertEqual(manager.selectedSessionID, session.id)
        XCTAssertTrue(manager.sessions.last === session)
    }

    func testResumingThreadShowsLoadingWorkspaceBeforeRemoteHistoryIsReady() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let relayID = "01234567-89ab-4def-8abc-0123456789ab"
        let thread = WorkerThreadSnapshot(
            kind: .codex,
            repositoryName: project.displayName,
            threadID: threadID,
            title: "Review initial loading",
            updatedAt: 100,
            isArchived: false,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .dormant
        )
        var callbackSession: TerminalSession?

        let resume = Task {
            await manager.resumeThread(
                thread,
                project: project,
                on: server,
                launchDefaults: .standard,
                onPendingSession: { callbackSession = $0 },
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }

        let pendingSession = try! XCTUnwrap(manager.sessions.last)
        XCTAssertTrue(callbackSession === pendingSession)
        XCTAssertTrue(pendingSession.isLoadingExistingConversation)
        XCTAssertEqual(pendingSession.threadID, threadID)
        XCTAssertEqual(pendingSession.displayTitle, "Review initial loading")
        XCTAssertEqual(
            pendingSession.lastActivityAt,
            Date(timeIntervalSince1970: 100),
            "A resumed conversation keeps the thread's recency so its row does not jump."
        )
        XCTAssertEqual(manager.selectedSessionID, pendingSession.id)
        let pendingID = pendingSession.id

        let duplicateResult = await manager.resumeThread(
            thread,
            project: project,
            on: server,
            launchDefaults: .standard,
            using: service
        )
        guard case .selectedExisting(let duplicateSession) = duplicateResult else {
            return XCTFail("Expected a repeated open to select the in-flight conversation")
        }
        XCTAssertTrue(duplicateSession === pendingSession)
        XCTAssertEqual(recorder.callCount, 1)

        recorder.finish(
            with: Self.statusResult(
                snapshot: WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: project.displayName,
                    attachedClientCount: 0,
                    instanceToken: relayID,
                    threadID: threadID,
                    presentation: .chat
                )
            )
        )
        let result = await resume.value

        guard case .opened(let session) = result else {
            return XCTFail("Expected the pending conversation to finish loading")
        }
        XCTAssertEqual(session.id, pendingID)
        XCTAssertEqual(session.instanceToken, relayID)
        XCTAssertEqual(session.threadID, threadID)
        XCTAssertEqual(session.displayTitle, "Review initial loading")
        XCTAssertFalse(session.isLaunchPending)
        XCTAssertEqual(
            session.lastActivityAt,
            Date(timeIntervalSince1970: 100),
            "The confirmed session keeps the inherited recency across the swap."
        )
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: server,
                    kind: .codex,
                    repositoryName: project.displayName,
                    threadID: threadID,
                    launchDefaults: .standard
                )
            ]
        )
    }

    func testNewSessionDoesNotReplaceKnownSameRepositorySession() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let existingToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let startedToken = "11111111-2222-" + "4333-8444-555555555555"
        let existing = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: existingToken
        ).localSession!
        let recorder = WorkerSessionCommandRecorder(
            results: [
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

        let result = await manager.openNewSession(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            using: service
        )

        guard case .opened(let session) = result else {
            return XCTFail("Expected the returned instance to get a distinct session")
        }
        XCTAssertEqual(session.instanceToken, startedToken)
        XCTAssertEqual(session.status, .connecting)
        XCTAssertEqual(manager.sessions.count, 2)
        XCTAssertTrue(manager.sessions.contains { $0 === existing })
        XCTAssertEqual(recorder.configurations.count, 1)
        XCTAssertEqual(
            recorder.configurations.last,
            SSHCommandBuilder.workerChatStartConfiguration(
                for: server,
                kind: .claude,
                repositoryName: project.displayName,
                threadID: nil,
                launchDefaults: .standard
            )
        )
    }

    func testNewSessionStartsWhenSameKindIsKnownOnAnotherRepository() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let otherProject = makeProject(name: "Another Repository", server: server)
        let manager = SessionManager()
        let startedToken = "11111111-2222-" + "4333-8444-555555555555"
        _ = manager.open(
            project: otherProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard,
            instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
        )
        let recorder = WorkerSessionCommandRecorder(
            results: [
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

        let result = await manager.openNewSession(
            project: project,
            on: server,
            kind: .codex,
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
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: server,
                    kind: .codex,
                    repositoryName: project.displayName,
                    threadID: nil,
                    launchDefaults: .standard
                )
            ]
        )
        XCTAssertEqual(manager.sessions.count, 2)
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

    func testReconnectCompletionDoesNotOverrideANewerSelection() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let reconnecting = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        reconnecting.processTerminated(source: reconnecting.terminalView, exitCode: nil)
        await Task.yield()

        let otherInstanceID = UUID().uuidString.lowercased()
        let other = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: otherInstanceID
        ).localSession!
        manager.selectSession(reconnecting.id)

        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let reconnect = Task {
            await manager.reconnectAfterRefresh(
                sessionID: reconnecting.id,
                project: project,
                on: server,
                projects: [project],
                launchDefaults: .standard,
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }

        manager.selectSession(other.id)
        let reconnectingID = reconnecting.instanceToken
        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: project.displayName,
                instanceToken: reconnectingID
            )
        )
        _ = await reconnect.value

        XCTAssertEqual(manager.selectedSessionID, other.id)
    }

    func testStartCompletionDoesNotOverrideANewerSelection() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let firstProject = makeProject(name: "Terminal Relay", server: server)
        let secondProject = makeProject(name: "Website API", server: server)
        let thirdProject = makeProject(name: "Landing Page", server: server)
        let manager = SessionManager()
        let first = manager.open(
            project: firstProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        let second = manager.open(
            project: secondProject,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: "11111111-2222-" + "4333-8444-555555555555"
        ).localSession!
        manager.selectSession(first.id)

        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let start = Task {
            await manager.openNewSession(
                project: thirdProject,
                on: server,
                kind: .codex,
                launchDefaults: .standard,
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }

        manager.selectSession(second.id)
        let startedInstance = "22222222-3333-" + "4444-8555-666666666666"
        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: thirdProject.displayName,
                instanceToken: startedInstance
            )
        )
        let result = await start.value

        XCTAssertNil(result)
        XCTAssertEqual(manager.selectedSessionID, second.id)
        XCTAssertEqual(
            manager.sessions.first(where: { $0.instanceToken == startedInstance })?.projectID,
            thirdProject.id
        )
    }

    func testStartCompletionDoesNotOverrideARepeatedSelection() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let selectedProject = makeProject(name: "Terminal Relay", server: server)
        let startingProject = makeProject(name: "Landing Page", server: server)
        let manager = SessionManager()
        let selected = manager.open(
            project: selectedProject,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        ).localSession!
        manager.selectSession(selected.id)

        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let start = Task {
            await manager.openNewSession(
                project: startingProject,
                on: server,
                kind: .codex,
                launchDefaults: .standard,
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }

        manager.selectSession(selected.id)
        let startedInstance = "22222222-3333-" + "4444-8555-666666666666"
        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: startingProject.displayName,
                instanceToken: startedInstance
            )
        )
        let result = await start.value

        XCTAssertNil(result)
        XCTAssertEqual(manager.selectedSessionID, selected.id)
        XCTAssertEqual(
            manager.sessions.first(where: { $0.instanceToken == startedInstance })?.projectID,
            startingProject.id
        )
    }

    func testLatestOverlappingStartControlsSelection() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let selectedProject = makeProject(name: "Terminal Relay", server: server)
        let olderProject = makeProject(name: "Website API", server: server)
        let newerProject = makeProject(name: "Landing Page", server: server)
        let manager = SessionManager()
        let selected = manager.open(
            project: selectedProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).localSession!
        manager.selectSession(selected.id)

        let olderRecorder = BlockingWorkerSessionCommandRecorder()
        let olderService = WorkerSessionService { configuration in
            await olderRecorder.run(configuration)
        }
        let olderStart = Task {
            await manager.openNewSession(
                project: olderProject,
                on: server,
                kind: .claude,
                launchDefaults: .standard,
                using: olderService
            )
        }
        while olderRecorder.callCount == 0 {
            await Task.yield()
        }

        let newerRecorder = BlockingWorkerSessionCommandRecorder()
        let newerService = WorkerSessionService { configuration in
            await newerRecorder.run(configuration)
        }
        let newerStart = Task {
            await manager.openNewSession(
                project: newerProject,
                on: server,
                kind: .codex,
                launchDefaults: .standard,
                using: newerService
            )
        }
        while newerRecorder.callCount == 0 {
            await Task.yield()
        }
        let newerPendingID = manager.selectedSessionID

        let olderInstance = "22222222-3333-" + "4444-8555-666666666666"
        olderRecorder.finish(
            with: Self.statusResult(
                kind: .claude,
                repositoryName: olderProject.displayName,
                instanceToken: olderInstance
            )
        )
        let olderResult = await olderStart.value

        XCTAssertNil(olderResult)
        XCTAssertNotEqual(newerPendingID, selected.id)
        XCTAssertEqual(manager.selectedSessionID, newerPendingID)
        XCTAssertEqual(
            manager.sessions.first(where: { $0.instanceToken == olderInstance })?.projectID,
            olderProject.id
        )

        let newerInstance = "33333333-4444-" + "4555-8666-777777777777"
        newerRecorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: newerProject.displayName,
                instanceToken: newerInstance
            )
        )
        let newerResult = await newerStart.value

        guard case .opened(let newerSession) = newerResult else {
            return XCTFail("Expected the latest start to control selection")
        }
        XCTAssertEqual(newerSession.instanceToken, newerInstance)
        XCTAssertEqual(manager.selectedSessionID, newerSession.id)
    }

    func testInvalidatingPendingOpenSelectionPreventsLateStartSelection() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let selectedProject = makeProject(name: "Terminal Relay", server: server)
        let startingProject = makeProject(name: "Landing Page", server: server)
        let manager = SessionManager()
        let selected = manager.open(
            project: selectedProject,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        ).localSession!
        manager.selectSession(selected.id)

        let recorder = BlockingWorkerSessionCommandRecorder()
        let service = WorkerSessionService { configuration in
            await recorder.run(configuration)
        }
        let start = Task {
            await manager.openNewSession(
                project: startingProject,
                on: server,
                kind: .codex,
                launchDefaults: .standard,
                using: service
            )
        }
        while recorder.callCount == 0 {
            await Task.yield()
        }
        let pendingSessionID = manager.selectedSessionID

        manager.invalidatePendingOpenSelection()
        let startedInstance = "22222222-3333-" + "4444-8555-666666666666"
        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: startingProject.displayName,
                instanceToken: startedInstance
            )
        )
        let result = await start.value

        XCTAssertNil(result)
        XCTAssertNotEqual(pendingSessionID, selected.id)
        XCTAssertEqual(manager.selectedSessionID, pendingSessionID)
        XCTAssertEqual(
            manager.sessions.first(where: { $0.instanceToken == startedInstance })?.projectID,
            startingProject.id
        )
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

    func testFailedStartKeepsReconnectableSessionAndShowsFailurePanel() async {
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

        let result = await manager.openNewSession(
            project: project,
            on: server,
            kind: .codex,
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
        XCTAssertEqual(manager.sessions.count, 2)
        let failedSession = try! XCTUnwrap(manager.sessions.last)
        XCTAssertFalse(failedSession === session)
        XCTAssertEqual(failedSession.status, .exited(nil))
        XCTAssertFalse(failedSession.isLaunchPending)
        XCTAssertEqual(
            failedSession.launchFailureMessage,
            "The worker could not start this agent."
        )
        XCTAssertEqual(manager.selectedSessionID, failedSession.id)
        XCTAssertNotNil(service.error(for: server.id))
    }

    func testNewSessionStartsWhileStatusRefreshIsInFlight() async {
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

        let start = Task {
            await manager.openNewSession(
                project: project,
                on: server,
                kind: .codex,
                launchDefaults: .standard,
                using: service
            )
        }
        while recorder.callCount < 2 {
            await Task.yield()
        }
        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: project.displayName,
                instanceToken: session.instanceToken
            )
        )
        let startedInstance = "01234567-89ab-" + "4def-8abc-0123456789ab"
        recorder.finish(
            with: Self.statusResult(
                kind: .codex,
                repositoryName: project.displayName,
                instanceToken: startedInstance
            )
        )
        let refreshSucceeded = await inFlightRefresh.value
        let result = await start.value

        XCTAssertTrue(refreshSucceeded)
        guard case .opened(let startedSession) = result else {
            return XCTFail("Expected the start to proceed during refresh")
        }
        XCTAssertEqual(startedSession.instanceToken, startedInstance)
        XCTAssertEqual(manager.sessions.count, 2)
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

    func testBeginArchiveStopHidesTheSessionImmediatelyAndStopStillCompletes() async {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let response = WorkerSessionResponse(
            projects: [project.displayName],
            sessions: [
                WorkerSessionSnapshot(
                    kind: .claude,
                    repositoryName: project.displayName,
                    attachedClientCount: 0,
                    instanceToken: instanceToken
                )
            ]
        )
        manager.reconcile(
            worker: server,
            projects: [project],
            response: response,
            launchDefaults: .standard
        )
        let session = manager.session(projectID: project.id, kind: .claude)!
        manager.selectSession(session.id)

        manager.beginArchiveStop(sessionID: session.id)

        XCTAssertEqual(session.status, .stopping)
        XCTAssertNil(manager.selectedSessionID)
        XCTAssertTrue(manager.sidebarSessions(forProjectID: project.id).isEmpty)

        // A status refresh racing the stop must not resurrect or duplicate the row.
        manager.reconcile(
            worker: server,
            projects: [project],
            response: response,
            launchDefaults: .standard
        )
        XCTAssertEqual(session.status, .stopping)
        XCTAssertTrue(manager.sidebarSessions(forProjectID: project.id).isEmpty)
        XCTAssertEqual(manager.sessions.count, 1)

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
        XCTAssertEqual(
            recorder.configurations,
            [
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: server,
                    kind: .claude,
                    repositoryName: project.displayName,
                    instanceToken: instanceToken
                )
            ]
        )
    }

    func testCancelArchiveStopRestoresTheHiddenSession() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let manager = SessionManager()
        let instanceToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
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
                        instanceToken: instanceToken
                    )
                ]
            ),
            launchDefaults: .standard
        )
        let session = manager.session(projectID: project.id, kind: .claude)!

        manager.beginArchiveStop(sessionID: session.id)
        XCTAssertTrue(manager.sidebarSessions(forProjectID: project.id).isEmpty)

        manager.cancelArchiveStop(sessionID: session.id)

        XCTAssertEqual(session.status, .remoteRunning)
        XCTAssertEqual(
            manager.sidebarSessions(forProjectID: project.id).map(\.id),
            [session.id]
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

    func testSidebarSessionOrderPersistsByRemoteInstanceToken() {
        let suiteName = "TerminalRelayTests.SessionManager.SidebarOrder.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = makeServer(name: "Worker 1", host: "worker-1")
        let project = makeProject(name: "Terminal Relay", server: server)
        let codexToken = "01234567-89ab-" + "4def-8abc-0123456789ab"
        let claudeToken = "11111111-2222-" + "4333-8444-555555555555"
        let manager = SessionManager(defaults: defaults)
        let codex = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard,
            instanceToken: codexToken
        ).localSession!
        let claude = manager.open(
            project: project,
            on: server,
            kind: .claude,
            launchDefaults: .standard,
            instanceToken: claudeToken
        ).localSession!

        XCTAssertEqual(
            manager.sidebarSessions(forProjectID: project.id).map(\.id),
            [claude.id, codex.id]
        )

        manager.moveSidebarSession(id: codex.id, before: claude.id)
        XCTAssertEqual(
            manager.sidebarSessions(forProjectID: project.id).map(\.id),
            [codex.id, claude.id]
        )

        let reloadedManager = SessionManager(defaults: defaults)
        reloadedManager.reconcile(
            worker: server,
            projects: [project],
            response: WorkerSessionResponse(
                projects: [project.displayName],
                sessions: [
                    WorkerSessionSnapshot(
                        kind: .codex,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: codexToken
                    ),
                    WorkerSessionSnapshot(
                        kind: .claude,
                        repositoryName: project.displayName,
                        attachedClientCount: 0,
                        instanceToken: claudeToken
                    )
                ]
            ),
            launchDefaults: .standard
        )

        XCTAssertEqual(
            reloadedManager.sidebarSessions(forProjectID: project.id).map(\.instanceToken),
            [codexToken, claudeToken]
        )
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

    private static func statusResult(
        snapshot: WorkerSessionSnapshot
    ) -> WorkerSessionCommandResult {
        let threadID = snapshot.threadID ?? ""
        return WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data(
                """
                __TERMINAL_RELAY_SESSION_V1__
                session|\(snapshot.kind.rawValue)|\(snapshot.repositoryName)|\(snapshot.attachedClientCount)|\(snapshot.instanceToken)|0||0|\(threadID)|\(snapshot.presentation.rawValue)
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

    private static func emptyThreadCatalogResult() -> WorkerSessionCommandResult {
        WorkerSessionCommandResult(
            exitCode: 0,
            standardOutput: Data(
                """
                __TERMINAL_RELAY_THREADS_V2__
                {"threads":[],"nextCursor":null}
                """.utf8
            ),
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

private func sessionManagerTestChatCapabilitiesResult(
    for configuration: SSHLaunchConfiguration
) -> WorkerSessionCommandResult {
    let command = configuration.arguments.last ?? ""
    let kind: AgentKind = command.contains("'chat-capabilities-v1' 'claude'")
        ? .claude
        : .codex
    let capabilities =
        #"{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
    return WorkerSessionCommandResult(
        exitCode: 0,
        standardOutput: Data(
            """
            \(WorkerChatProtocol.marker)
            {"provider":"\(kind.rawValue)","available":true,"capabilities":\(capabilities),"reason":null}

            """.utf8
        ),
        standardError: Data()
    )
}

private func sessionManagerTestChatStartResult(
    from result: WorkerSessionCommandResult
) -> WorkerSessionCommandResult {
    guard result.exitCode == 0,
          let response = try? WorkerSessionProtocol.parse(result.standardOutput),
          response.sessions.count == 1,
          let snapshot = response.sessions.first else {
        return result
    }
    let capabilities =
        #"{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#
    let threadID = snapshot.threadID ?? snapshot.instanceToken
    return WorkerSessionCommandResult(
        exitCode: 0,
        standardOutput: Data(
            """
            \(WorkerChatProtocol.marker)
            {"relayId":"\(snapshot.instanceToken)","provider":"\(snapshot.kind.rawValue)","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{}}

            """.utf8
        ),
        standardError: Data()
    )
}

@MainActor
private final class WorkerSessionCommandRecorder {
    private(set) var configurations: [SSHLaunchConfiguration] = []
    private var results: [WorkerSessionCommandResult]

    init(results: [WorkerSessionCommandResult]) {
        self.results = results
    }

    func run(_ configuration: SSHLaunchConfiguration) async -> WorkerSessionCommandResult {
        if configuration.arguments.last?.contains("'update-status'") == true {
            return WorkerSessionCommandResult(
                exitCode: 64,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        configurations.append(configuration)
        if configuration.arguments.last?.contains("'chat-capabilities-v1'") == true {
            return sessionManagerTestChatCapabilitiesResult(for: configuration)
        }
        let result = results.removeFirst()
        if configuration.arguments.last?.contains("'chat-start-v1'") == true {
            return sessionManagerTestChatStartResult(from: result)
        }
        return result
    }
}

@MainActor
private final class BlockingWorkerSessionCommandRecorder {
    private(set) var callCount = 0
    private(set) var configurations: [SSHLaunchConfiguration] = []
    private var continuations: [CheckedContinuation<WorkerSessionCommandResult, Never>] = []

    func run(_ configuration: SSHLaunchConfiguration) async -> WorkerSessionCommandResult {
        if configuration.arguments.last?.contains("'update-status'") == true {
            return WorkerSessionCommandResult(
                exitCode: 64,
                standardOutput: Data(),
                standardError: Data()
            )
        }
        if configuration.arguments.last?.contains("'chat-capabilities-v1'") == true {
            return sessionManagerTestChatCapabilitiesResult(for: configuration)
        }
        configurations.append(configuration)
        callCount += 1
        let result = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        if configuration.arguments.last?.contains("'chat-start-v1'") == true {
            return sessionManagerTestChatStartResult(from: result)
        }
        return result
    }

    func finish(with result: WorkerSessionCommandResult) {
        continuations.removeFirst().resume(returning: result)
    }
}
