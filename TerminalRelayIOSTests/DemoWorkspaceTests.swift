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
}
