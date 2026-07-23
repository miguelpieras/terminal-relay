import XCTest
@testable import TerminalRelayIOS

final class WorkerProfileStoreTests: XCTestCase {
    func testPersistenceContainsOnlyNonSecretWorkerConfiguration() throws {
        let suiteName = "WorkerProfileStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try WorkerProfile.validated(
            name: "Worker 1",
            host: "worker.tailnet.ts.net",
            port: 2222,
            username: "relay",
            expectedHostKeyFingerprint: "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        )
        let store = WorkerProfileStore(defaults: defaults)
        try store.save(profile)

        XCTAssertEqual(store.load(), [profile])
        let persistedData = try XCTUnwrap(
            defaults.data(forKey: "terminalRelayIOS.workerProfiles.v2")
        )
        let persistedText = String(decoding: persistedData, as: UTF8.self).lowercased()
        XCTAssertTrue(persistedText.contains("worker.tailnet.ts.net"))
        XCTAssertFalse(persistedText.contains("privatekey"))
        XCTAssertFalse(persistedText.contains("privatematerial"))
        XCTAssertFalse(persistedText.contains("password"))
    }

    func testMultipleProfilesAndSelectionPersist() throws {
        let suiteName = "WorkerProfileStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = try WorkerProfile.validated(
            name: "Worker 1",
            host: "worker-1.tailnet.ts.net",
            port: 22,
            username: "relay",
            expectedHostKeyFingerprint: "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        )
        let second = try WorkerProfile.validated(
            name: "Worker 2",
            host: "worker-2.tailnet.ts.net",
            port: 22,
            username: "relay",
            expectedHostKeyFingerprint: "SHA256:AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI"
        )
        let store = WorkerProfileStore(defaults: defaults)

        try store.save(first)
        try store.save(second)
        store.setSelectedProfileID(second.id)

        XCTAssertEqual(store.load(), [first, second])
        XCTAssertEqual(store.selectedProfileID(), second.id)

        store.delete(id: second.id)

        XCTAssertEqual(store.load(), [first])
        XCTAssertEqual(store.selectedProfileID(), first.id)
    }

}
