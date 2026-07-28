import XCTest
@testable import TerminalRelayIOS

@MainActor
final class DemoWorkspaceTests: XCTestCase {
    func testDemoWorkspaceLoadsBundledFixturesWithoutRefreshingAWorker() async {
        let model = WorkerSessionModel(screenshotDemo: true)
        let originalProjects = model.projects
        let originalSessions = model.sessions

        await model.refreshProjectCatalogs()
        await model.refreshWorkerOverviews()

        XCTAssertTrue(model.isDemoMode)
        XCTAssertEqual(model.profile, DemoWorkspace.worker)
        XCTAssertEqual(model.projects, originalProjects)
        XCTAssertEqual(model.sessions, originalSessions)
        XCTAssertEqual(model.workerOverviews[DemoWorkspace.worker.id], DemoWorkspace.overview)
    }

    func testDemoWorkspaceContainsOnlyPublishableExampleIdentity() {
        XCTAssertEqual(DemoWorkspace.worker.host, "worker.example.com")
        XCTAssertEqual(DemoWorkspace.worker.username, "example-user")
        XCTAssertTrue(
            DemoWorkspace.worker.expectedHostKeyFingerprint
                .hasPrefix("SHA256:AAAA")
        )
        XCTAssertEqual(
            Set(DemoWorkspace.overview.accounts.values.compactMap(\.account)),
            ["demo@example.com"]
        )
    }

    func testUnreadStateIsScopedToItsWorker() {
        let suiteName = "DemoWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = WorkerSessionModel(
            readStateDefaults: defaults,
            screenshotDemo: true
        )
        let session = DemoWorkspace.sessions[0]
        let otherWorkerID = UUID()

        XCTAssertTrue(model.isUnread(session, profileID: DemoWorkspace.worker.id))
        XCTAssertTrue(model.isUnread(session, profileID: otherWorkerID))

        model.openTerminal(session)

        XCTAssertFalse(model.isUnread(session, profileID: DemoWorkspace.worker.id))
        XCTAssertTrue(model.isUnread(session, profileID: otherWorkerID))
    }
}
