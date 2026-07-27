import XCTest
@testable import TerminalRelay

final class MobilePairingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let pairingIdentifier = "01234567-89ab-cdef-0123-456789abcdef"

    func testPairingCodeRoundTripsWithoutChangingPayload() throws {
        let payload = makePayload()

        let code = try MobilePairingPayloadCodec.encode(payload, now: now)
        let encodedPayload = try XCTUnwrap(
            URLComponents(string: code)?.queryItems?.first { $0.name == "payload" }?.value
        )

        XCTAssertTrue(code.hasPrefix("terminal-relay://pair-device?"))
        XCTAssertEqual(try MobilePairingPayloadCodec.decode(code, now: now), payload)
        XCTAssertFalse(encodedPayload.contains("+"))
        XCTAssertFalse(encodedPayload.contains("/"))
    }

    func testPairingCodeRejectsExpiredAndUnexpectedData() throws {
        let code = try MobilePairingPayloadCodec.encode(makePayload(), now: now)

        XCTAssertThrowsError(
            try MobilePairingPayloadCodec.decode(
                code,
                now: now.addingTimeInterval(601)
            )
        ) { error in
            XCTAssertEqual(error as? MobilePairingPayloadError, .expired)
        }
        XCTAssertThrowsError(
            try MobilePairingPayloadCodec.decode(code + "&extra=value", now: now)
        )
    }

    func testTemporaryAuthorizedKeyIsRestrictedToOneEnrollmentCommand() {
        let entry = MobilePairingService.authorizedKeyEntry(
            publicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest terminal-relay-pairing:\(pairingIdentifier)",
            token: pairingIdentifier,
            expiresAt: 1_800_000_600
        )
        let script = MobilePairingService.enrollmentScript(
            token: pairingIdentifier,
            expiresAt: 1_800_000_600
        )

        XCTAssertTrue(entry.hasPrefix(#"restrict,command=""#))
        XCTAssertTrue(entry.hasSuffix("terminal-relay-pairing:\(pairingIdentifier)"))
        XCTAssertTrue(script.contains("SSH_ORIGINAL_COMMAND"))
        XCTAssertTrue(script.contains("terminal-relay-enroll-device "))
        XCTAssertTrue(script.contains(MobilePairingService.enrollmentMarker))
        XCTAssertTrue(script.contains("$NF == marker"))
        XCTAssertTrue(script.contains("$NF != marker"))
    }

    func testWorkerPairingScriptsHaveValidShellSyntax() throws {
        let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest terminal-relay-pairing:\(pairingIdentifier)"
        let entry = MobilePairingService.authorizedKeyEntry(
            publicKey: publicKey,
            token: pairingIdentifier,
            expiresAt: 1_800_000_600
        )

        try assertShellSyntax(
            MobilePairingService.enrollmentScript(
                token: pairingIdentifier,
                expiresAt: 1_800_000_600
            )
        )
        try assertShellSyntax(
            MobilePairingService.pairingSetupScript(authorizedKeyEntry: entry)
        )
        try assertShellSyntax(
            MobilePairingService.pairingRevocationScript(token: pairingIdentifier)
        )
    }

    private func makePayload() -> MobilePairingPayload {
        MobilePairingPayload(
            version: MobilePairingPayload.currentVersion,
            workerName: "Worker 1",
            host: "worker.example.com",
            port: 22,
            username: "terminal-relay",
            hostKeyFingerprint: "SHA256:AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE",
            temporaryPrivateKey: Data(repeating: 7, count: 32).base64EncodedString(),
            pairingToken: pairingIdentifier,
            expiresAt: 1_800_000_600
        )
    }

    private func assertShellSyntax(
        _ script: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let process = Process()
        let input = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n"]
        process.standardInput = input
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(script.utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        XCTAssertEqual(
            process.terminationStatus,
            0,
            String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            file: file,
            line: line
        )
    }
}
