import XCTest
@testable import TerminalRelayIOS

final class WorkerProfileStoreTests: XCTestCase {
    func testPersistenceContainsOnlyNonSecretWorkerConfiguration() throws {
        let suiteName = "WorkerProfileStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let profile = try WorkerProfile.validated(
            host: "worker.tailnet.ts.net",
            port: 2222,
            username: "relay",
            expectedHostKeyFingerprint: "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
        )
        let store = WorkerProfileStore(defaults: defaults)
        try store.save(profile)

        XCTAssertEqual(store.load(), profile)
        let persistedData = try XCTUnwrap(
            defaults.dictionaryRepresentation().values.compactMap { $0 as? Data }.first
        )
        let persistedText = String(decoding: persistedData, as: UTF8.self).lowercased()
        XCTAssertTrue(persistedText.contains("worker.tailnet.ts.net"))
        XCTAssertFalse(persistedText.contains("privatekey"))
        XCTAssertFalse(persistedText.contains("privatematerial"))
        XCTAssertFalse(persistedText.contains("password"))
    }
}
