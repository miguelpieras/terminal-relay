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

    func testUnreadStateSurvivesANewRelayInstanceForTheSameThread() {
        let suiteName = "DemoWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = WorkerSessionModel(
            readStateDefaults: defaults,
            screenshotDemo: true
        )
        let original = DemoWorkspace.sessions[0]
        model.openTerminal(original)
        let replacement = WorkerSessionSnapshot(
            kind: original.kind,
            repositoryName: original.repositoryName,
            attachedClientCount: 0,
            instanceToken:
                "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
            title: original.title,
            lastActivityAt: original.lastActivityAt,
            reportedWorking: false,
            threadID: original.threadID
        )

        XCTAssertFalse(
            model.isUnread(replacement, profileID: DemoWorkspace.worker.id)
        )
    }

    func testChatDemoFixtureExercisesRichRenderingStatesLocally() throws {
        let events = MobileChatDemoFixture.events
        XCTAssertTrue(events.allSatisfy { $0.v == 1 })
        XCTAssertTrue(events.allSatisfy { $0.accountID == nil })
        XCTAssertEqual(
            events.map(\.type),
            [
                "conversation.snapshot",
                "message.delta",
                "message.completed",
                "turn.completed",
            ]
        )

        let store = ConversationStore()
        for event in events {
            try store.apply(event)
        }

        let assistant = try XCTUnwrap(
            store.state.messages.first { $0.role == .assistant }
        )
        XCTAssertFalse(assistant.isStreaming)
        XCTAssertTrue(assistant.text.contains("| Surface | Result |"))
        XCTAssertTrue(assistant.text.contains("```swift"))
        XCTAssertTrue(assistant.text.contains("https://example.com/security"))
        XCTAssertEqual(store.state.tools.first?.status, .completed)
        XCTAssertTrue(
            store.state.items.contains {
                if case .diff = $0 { return true }
                return false
            }
        )
        XCTAssertEqual(store.state.approvals.first?.status, .approved)
        XCTAssertTrue(
            store.state.items.contains {
                guard case .generic(let item) = $0 else { return false }
                return item.type == "error"
            }
        )
        XCTAssertEqual(store.state.turnState, .completed)
    }

    func testChatDemoCoordinatorStreamsFixtureThroughTheRealLifecycle() async {
        let coordinator = MobileChatDemoFixture.makeCoordinator()

        XCTAssertNil(MobileChatDemoFixture.identity.accountID)

        coordinator.start()
        for _ in 0..<2000 {
            if coordinator.store.state.lastAppliedSequence == 4 { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        XCTAssertEqual(coordinator.store.state.lastAppliedSequence, 4)
        XCTAssertEqual(coordinator.store.state.turnState, .completed)
        XCTAssertEqual(coordinator.store.state.connectionState, .streaming)
        await coordinator.detach()
    }
}
