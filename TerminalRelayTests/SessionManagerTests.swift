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
        let project = makeProject(
            name: "Terminal Relay",
            server: server,
            workingDirectory: "/home/relay/dev/terminal-relay"
        )
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
        XCTAssertEqual(session.projectName, "Terminal Relay")
        XCTAssertEqual(session.workingDirectory, "/home/relay/dev/terminal-relay")
        XCTAssertEqual(session.title, "Terminal Relay · Claude")
        XCTAssertTrue(manager.session(projectID: project.id, kind: .claude) === session)
        XCTAssertEqual(manager.sessions(forProjectID: project.id).map(\.id), [session.id])
        XCTAssertEqual(manager.sessions(for: server).map(\.id), [session.id])
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

    private func makeProject(
        name: String,
        server: ServerProfile,
        workingDirectory: String? = nil
    ) -> ProjectProfile {
        ProjectProfile(
            name: name,
            serverID: server.id,
            githubRepository: "owner/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
            workingDirectory: workingDirectory ?? "/home/relay/dev/\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"
        )
    }
}
