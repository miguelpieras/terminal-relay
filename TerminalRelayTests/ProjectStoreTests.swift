import XCTest
@testable import TerminalRelay

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testStartsEmptyAndIgnoresLegacyWorkspaceStorage() throws {
        let suiteName = "TerminalRelayTests.ProjectStore.Empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ServerProfile(
            name: "Worker",
            host: "worker",
            workingDirectory: "/workspace"
        )
        let legacyWorkspace = ProjectProfile(serverID: server.id, repositoryName: "Workspace")
        defaults.set(try JSONEncoder().encode([legacyWorkspace]), forKey: "projectProfiles.v1")

        let store = ProjectStore(defaults: defaults, servers: [server])

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "projectProfiles.v2"))
    }

    func testSaveUpdateLoadAndDeletePersistAcrossStoreInstances() {
        let suiteName = "TerminalRelayTests.ProjectStore.Persistence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ServerProfile(name: "Worker", host: "worker")
        let projectID = UUID()
        let original = ProjectProfile(
            id: projectID,
            serverID: server.id,
            repositoryName: "original"
        )
        let firstStore = ProjectStore(defaults: defaults, servers: [server], initialProjects: [])

        XCTAssertTrue(firstStore.save(original))
        XCTAssertEqual(ProjectStore(defaults: defaults, servers: [server]).project(id: projectID), original)

        var updated = original
        updated.repositoryName = "updated"
        XCTAssertTrue(firstStore.save(updated))

        let reloadedStore = ProjectStore(defaults: defaults, servers: [server])
        XCTAssertEqual(reloadedStore.projects, [updated])
        XCTAssertEqual(reloadedStore.projects(for: server.id), [updated])
        XCTAssertEqual(reloadedStore.projects.first?.workingDirectory, "/workspace/updated")
        XCTAssertNil(reloadedStore.persistenceError)

        reloadedStore.delete(id: projectID)
        XCTAssertTrue(ProjectStore(defaults: defaults, servers: [server]).projects.isEmpty)
    }

    func testRejectsInvalidProjectOrMissingServerAndDetectsServerRemoval() {
        let suiteName = "TerminalRelayTests.ProjectStore.Validation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ServerProfile(name: "Worker", host: "worker")
        let project = ProjectProfile(
            serverID: server.id,
            repositoryName: "terminal-relay"
        )
        let store = ProjectStore(defaults: defaults, servers: [server], initialProjects: [])

        XCTAssertTrue(store.save(project))
        XCTAssertNil(store.validationError)

        store.updateServers([])
        XCTAssertNotNil(store.validationError)

        store.dismissValidationError()
        XCTAssertNil(store.validationError)

        let missingProject = ProjectProfile(
            serverID: UUID(),
            repositoryName: "missing"
        )
        XCTAssertFalse(store.save(missingProject))
        XCTAssertEqual(store.projects, [project])
        XCTAssertNotNil(store.validationError)

        let invalidProject = ProjectProfile(serverID: server.id, repositoryName: "../invalid")
        XCTAssertFalse(store.save(invalidProject))
        XCTAssertEqual(store.projects, [project])

        let duplicate = ProjectProfile(
            serverID: server.id,
            repositoryName: "TERMINAL-RELAY"
        )
        XCTAssertFalse(store.save(duplicate))
        XCTAssertEqual(store.projects, [project])
    }

    func testInvalidSavedDataReportsDismissiblePersistenceError() {
        let suiteName = "TerminalRelayTests.ProjectStore.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "projectProfiles.v2")

        let store = ProjectStore(defaults: defaults, servers: [], initialProjects: [])

        XCTAssertTrue(store.projects.isEmpty)
        XCTAssertNotNil(store.persistenceError)

        store.dismissPersistenceError()
        XCTAssertNil(store.persistenceError)
    }

    func testSidebarFoldersProjectOrderingAndMovesPersist() {
        let suiteName = "TerminalRelayTests.ProjectStore.Sidebar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let server = ServerProfile(name: "Worker", host: "worker")
        let first = ProjectProfile(serverID: server.id, repositoryName: "first")
        let second = ProjectProfile(serverID: server.id, repositoryName: "second")
        let third = ProjectProfile(serverID: server.id, repositoryName: "third")
        let store = ProjectStore(defaults: defaults, servers: [server], initialProjects: [])

        XCTAssertTrue(store.save(first))
        XCTAssertTrue(store.save(second))
        XCTAssertTrue(store.save(third))

        let work = try! XCTUnwrap(store.createSidebarFolder(named: "Work"))
        let later = try! XCTUnwrap(store.createSidebarFolder(named: "Later"))
        store.moveProject(id: second.id, intoSidebarFolder: work.id)
        store.moveProject(id: third.id, before: second.id, intoSidebarFolder: work.id)
        store.moveSidebarFolder(id: later.id, before: work.id)

        XCTAssertEqual(store.rootProjects.map(\.id), [first.id])
        XCTAssertEqual(store.projects(inSidebarFolder: work.id).map(\.id), [third.id, second.id])
        XCTAssertEqual(store.sidebarFolders.map(\.id), [later.id, work.id])
        XCTAssertNil(store.sidebarFolderID(containing: first.id))
        XCTAssertEqual(store.sidebarFolderID(containing: second.id), work.id)

        let reloadedStore = ProjectStore(defaults: defaults, servers: [server])
        XCTAssertEqual(reloadedStore.rootProjects.map(\.id), [first.id])
        XCTAssertEqual(
            reloadedStore.projects(inSidebarFolder: work.id).map(\.id),
            [third.id, second.id]
        )
        XCTAssertEqual(reloadedStore.sidebarFolders.map(\.id), [later.id, work.id])

        reloadedStore.moveProject(id: third.id, intoSidebarFolder: nil)
        reloadedStore.deleteSidebarFolder(id: work.id)
        XCTAssertEqual(reloadedStore.rootProjects.map(\.id), [first.id, third.id, second.id])
        XCTAssertNil(reloadedStore.sidebarFolderID(containing: second.id))
        XCTAssertEqual(reloadedStore.sidebarFolders.map(\.id), [later.id])
    }
}
