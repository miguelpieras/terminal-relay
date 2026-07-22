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

    func testOpeningAnOccupiedWorkerSlotReportsTheOtherProject() {
        let server = makeServer(name: "Worker 1", host: "worker-1")
        let firstProject = makeProject(name: "Terminal Relay", server: server)
        let secondProject = makeProject(name: "Website API", server: server)
        let manager = SessionManager()

        let codexResult = manager.open(
            project: firstProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        )
        guard case .opened(let codexSession) = codexResult else {
            return XCTFail("Expected the first Codex session to open")
        }

        let claudeResult = manager.open(
            project: secondProject,
            on: server,
            kind: .claude,
            launchDefaults: .standard
        )
        guard case .opened(let claudeSession) = claudeResult else {
            return XCTFail("Codex and Claude should be able to share a worker")
        }

        let occupiedResult = manager.open(
            project: secondProject,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        )
        guard case .occupied(let occupant) = occupiedResult else {
            return XCTFail("Expected the worker's Codex slot to be occupied")
        }

        XCTAssertTrue(occupant === codexSession)
        XCTAssertEqual(occupant.projectID, firstProject.id)
        XCTAssertEqual(manager.selectedSessionID, claudeSession.id)
        XCTAssertEqual(manager.sessions.count, 2)
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

        XCTAssertEqual(firstSession.status, .exited(0))
        XCTAssertEqual(manager.sessions(forProjectID: project.id).map(\.id), [firstSession.id])
        XCTAssertNil(manager.activeSession(projectID: project.id, kind: .codex))

        let secondResult = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        )
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
        ).session

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
        ).session

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
        ).session
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
        ).session

        firstSession.processTerminated(source: firstSession.terminalView, exitCode: 0)
        await Task.yield()
        manager.close(sessionID: firstSession.id)
        XCTAssertTrue(manager.sessions(forProjectID: project.id).isEmpty)

        let secondSession = manager.open(
            project: project,
            on: server,
            kind: .codex,
            launchDefaults: .standard
        ).session

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
        XCTAssertTrue(manager.sessions.first === otherResult.session)
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
