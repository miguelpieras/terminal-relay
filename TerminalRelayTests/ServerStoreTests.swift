import XCTest
@testable import TerminalRelay

@MainActor
final class ServerStoreTests: XCTestCase {
    func testSaveUpdateLoadAndDeletePersistAcrossStoreInstances() {
        let suiteName = "TerminalRelayTests.ServerStore.\(UUID().uuidString)"
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
        let suiteName = "TerminalRelayTests.ServerStore.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "serverProfiles.v3")

        let store = ServerStore(defaults: defaults, initialServers: [])

        XCTAssertTrue(store.servers.isEmpty)
        XCTAssertNotNil(store.persistenceError)

        store.dismissPersistenceError()
        XCTAssertNil(store.persistenceError)
    }

    func testRegisterWorkerPersistsAndReplayUpdatesOneStableProfile() throws {
        let suiteName = "TerminalRelayTests.ServerStore.Registration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let identifier = UUID()
        let store = ServerStore(defaults: defaults, initialServers: [])
        let original = try WorkerRegistrationURL.registration(
            from: registrationURL(
                id: identifier,
                host: "first.example.com"
            )
        ).profile
        store.save(original)

        XCTAssertEqual(store.servers, [original])
        XCTAssertEqual(ServerStore(defaults: defaults).servers, [original])

        let updated = try WorkerRegistrationURL.registration(
            from: registrationURL(
                id: identifier,
                host: "second.example.com",
                port: 2_222
            )
        ).profile
        store.save(updated)

        XCTAssertEqual(store.servers, [updated])
        XCTAssertEqual(store.server(id: identifier)?.host, "second.example.com")
        XCTAssertEqual(store.server(id: identifier)?.port, 2_222)
        XCTAssertEqual(ServerStore(defaults: defaults).servers, [updated])
    }

    func testInvalidRegistrationDoesNotMutateOrPersistServers() {
        let suiteName = "TerminalRelayTests.ServerStore.InvalidRegistration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = ServerProfile(name: "Existing", host: "existing")
        let store = ServerStore(defaults: defaults, initialServers: [existing])

        XCTAssertThrowsError(
            try WorkerRegistrationURL.registration(
                from: registrationURL(id: UUID(), username: "root")
            )
        )
        XCTAssertEqual(store.servers, [existing])
        XCTAssertEqual(ServerStore(defaults: defaults).servers, [existing])
    }

    func testRegisterWorkerPreservesBundledWorkerOne() throws {
        let suiteName = "TerminalRelayTests.ServerStore.BundledRegistration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ServerStore(defaults: defaults)
        XCTAssertEqual(store.servers.count, 1)
        XCTAssertEqual(store.servers.first?.name, "Terminal Relay Worker 1")

        let importedID = UUID()
        let imported = try WorkerRegistrationURL.registration(
            from: registrationURL(id: importedID)
        ).profile
        store.save(imported)

        XCTAssertEqual(store.servers.count, 2)
        XCTAssertEqual(store.servers.first?.name, "Terminal Relay Worker 1")
        XCTAssertNotNil(store.server(id: importedID))
    }

    private func registrationURL(
        id: UUID,
        name: String? = nil,
        host: String = "worker.example.com",
        port: Int = 22,
        username: String = "terminal-relay",
        identity: String = ""
    ) -> URL {
        let resolvedName = name
            ?? "Terminal Relay Worker \(id.uuidString.prefix(8).lowercased())"
        let query = [
            "v=1",
            "id=\(id.uuidString)",
            "name=\(encoded(resolvedName))",
            "host=\(encoded(host))",
            "port=\(port)",
            "username=\(encoded(username))",
            "identity=\(encoded(identity))",
            "proof=\(String(repeating: "a", count: 64))"
        ].joined(separator: "&")
        return URL(string: "terminal-relay://register-worker?\(query)")!
    }

    private func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
