import XCTest
@testable import TerminalRelayIOS

final class WorkerProfileTests: XCTestCase {
    private let fingerprint = "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"

    func testValidProfileIsNormalized() throws {
        let profile = try WorkerProfile.validated(
            name: " Worker 1 ",
            host: " worker.tailnet.ts.net \n",
            port: 22,
            username: " relay ",
            expectedHostKeyFingerprint: " \(fingerprint)= "
        )

        XCTAssertEqual(profile.name, "Worker 1")
        XCTAssertEqual(profile.displayName, "Worker 1")
        XCTAssertEqual(profile.host, "worker.tailnet.ts.net")
        XCTAssertEqual(profile.port, 22)
        XCTAssertEqual(profile.username, "relay")
        XCTAssertEqual(profile.expectedHostKeyFingerprint, fingerprint)
    }

    func testHostRejectsCommandAndPathCharacters() {
        for host in ["worker;reboot", "worker name", "worker/other", "-worker.tailnet"] {
            XCTAssertThrowsError(
                try WorkerProfile.validated(
                    host: host,
                    port: 22,
                    username: "relay",
                    expectedHostKeyFingerprint: fingerprint
                )
            )
        }
    }

    func testPortUsernameAndFingerprintAreValidated() {
        XCTAssertThrowsError(
            try WorkerProfile.validated(
                host: "worker.tailnet",
                port: 0,
                username: "relay",
                expectedHostKeyFingerprint: fingerprint
            )
        )
        XCTAssertThrowsError(
            try WorkerProfile.validated(
                host: "worker.tailnet",
                port: 22,
                username: "relay;id",
                expectedHostKeyFingerprint: fingerprint
            )
        )
        XCTAssertThrowsError(
            try WorkerProfile.validated(
                host: "worker.tailnet",
                port: 22,
                username: "relay",
                expectedHostKeyFingerprint: "SHA256:not-a-sha256-digest"
            )
        )
    }
}
