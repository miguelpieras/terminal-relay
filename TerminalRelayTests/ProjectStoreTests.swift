import XCTest
@testable import TerminalRelay

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testSeedsOneProjectForEachServerWorkingDirectoryOnlyOnce() {
        let suiteName = "TerminalRelayTests.ProjectStore.Seed.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstServer = ServerProfile(
            name: "Worker 1",
            host: "worker-1",
            workingDirectory: "/home/relay/dev/terminal-relay"
        )
        let secondServer = ServerProfile(
            name: "Worker 2",
            host: "worker-2",
            workingDirectory: "/workspace"
        )
        let emptyServer = ServerProfile(name: "Worker 3", host: "worker-3")

        let firstStore = ProjectStore(
            defaults: defaults,
            servers: [firstServer, secondServer, emptyServer]
        )

        XCTAssertEqual(firstStore.projects.count, 2)
        XCTAssertEqual(firstStore.projects.map(\.name), ["terminal-relay", "Workspace"])
        XCTAssertEqual(firstStore.projects.map(\.serverID), [firstServer.id, secondServer.id])
        XCTAssertTrue(firstStore.projects.allSatisfy { $0.githubRepository.isEmpty })

        let changedServer = ServerProfile(
            name: "New Worker",
            host: "new-worker",
            workingDirectory: "/home/relay/dev/new-project"
        )
        let reloadedStore = ProjectStore(defaults: defaults, servers: [firstServer, secondServer, changedServer])

        XCTAssertEqual(reloadedStore.projects, firstStore.projects)
    }

    func testSaveUpdateLoadAndDeletePersistAcrossStoreInstances() {
        let suiteName = "TerminalRelayTests.ProjectStore.Persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ServerProfile(name: "Worker", host: "worker")
        let projectID = UUID()
        let original = ProjectProfile(
            id: projectID,
            name: "Original",
            serverID: server.id,
            workingDirectory: "/home/relay/dev/original"
        )
        let firstStore = ProjectStore(defaults: defaults, servers: [server], initialProjects: [])

        XCTAssertTrue(firstStore.save(original))
        XCTAssertEqual(ProjectStore(defaults: defaults, servers: [server]).project(id: projectID), original)

        var updated = original
        updated.name = "Updated"
        updated.githubRepository = "owner/updated"
        XCTAssertTrue(firstStore.save(updated))

        let reloadedStore = ProjectStore(defaults: defaults, servers: [server])
        XCTAssertEqual(reloadedStore.projects, [updated])
        XCTAssertEqual(reloadedStore.projects(for: server.id), [updated])
        XCTAssertNil(reloadedStore.persistenceError)

        reloadedStore.delete(id: projectID)
        XCTAssertTrue(ProjectStore(defaults: defaults, servers: [server]).projects.isEmpty)
    }

    func testRejectsSaveForMissingServerAndDetectsServerRemoval() {
        let suiteName = "TerminalRelayTests.ProjectStore.Validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ServerProfile(name: "Worker", host: "worker")
        let project = ProjectProfile(
            name: "Terminal Relay",
            serverID: server.id,
            workingDirectory: "/home/relay/dev/terminal-relay"
        )
        let store = ProjectStore(defaults: defaults, servers: [server], initialProjects: [])

        XCTAssertTrue(store.save(project))
        XCTAssertNil(store.validationError)

        store.updateServers([])
        XCTAssertNotNil(store.validationError)

        store.dismissValidationError()
        XCTAssertNil(store.validationError)

        let missingProject = ProjectProfile(
            name: "Missing",
            serverID: UUID(),
            workingDirectory: "/home/relay/dev/missing"
        )
        XCTAssertFalse(store.save(missingProject))
        XCTAssertEqual(store.projects, [project])
        XCTAssertNotNil(store.validationError)
    }

    func testInvalidSavedDataReportsDismissiblePersistenceError() {
        let suiteName = "TerminalRelayTests.ProjectStore.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "projectProfiles.v1")

        let store = ProjectStore(defaults: defaults, servers: [], initialProjects: [])

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNotNil(store.persistenceError)

        store.dismissPersistenceError()
        XCTAssertNil(store.persistenceError)
    }
}
