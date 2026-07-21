import XCTest
@testable import AgentConsole

@MainActor
final class ServerStoreTests: XCTestCase {
    func testSaveUpdateLoadAndDeletePersistAcrossStoreInstances() {
        let suiteName = "AgentConsoleTests.ServerStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let id = UUID()
        let original = ServerProfile(
            id: id,
            name: "Original",
            host: "original.example.com",
            codexCommand: "codex",
            claudeCommand: "claude"
        )
        let firstStore = ServerStore(defaults: defaults, initialServers: [])

        firstStore.save(original)
        XCTAssertEqual(ServerStore(defaults: defaults, initialServers: []).server(id: id), original)

        var updated = original
        updated.name = "Updated"
        updated.port = 2_222
        firstStore.save(updated)

        let reloadedStore = ServerStore(defaults: defaults, initialServers: [])
        XCTAssertEqual(reloadedStore.servers, [updated])
        XCTAssertNil(reloadedStore.persistenceError)

        reloadedStore.delete(id: id)
        XCTAssertTrue(ServerStore(defaults: defaults, initialServers: []).servers.isEmpty)
    }

    func testInvalidSavedDataReportsDismissiblePersistenceError() {
        let suiteName = "AgentConsoleTests.ServerStore.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "serverProfiles.v2")

        let store = ServerStore(defaults: defaults, initialServers: [])

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertNotNil(store.persistenceError)

        store.dismissPersistenceError()
        XCTAssertNil(store.persistenceError)
    }
}
