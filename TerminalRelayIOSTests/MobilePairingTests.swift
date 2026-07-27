import XCTest
@testable import TerminalRelayIOS

final class MobilePairingTests: XCTestCase {
    func testEnrollmentCommandCarriesOnlyThePermanentPublicKey() throws {
        let publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest terminal-relay-ios"

        let command = MobilePairingClient.enrollmentCommand(publicKey: publicKey)
        let encoded = try XCTUnwrap(command.split(separator: " ").last)

        XCTAssertEqual(
            Data(base64Encoded: String(encoded)).map { String(decoding: $0, as: UTF8.self) },
            publicKey
        )
        XCTAssertFalse(command.contains("PRIVATE"))
    }

    func testEnrollmentResponseRequiresMarkerAndConfirmation() throws {
        let valid = Data(
            """
            welcome
            \(MobilePairingClient.enrollmentMarker)
            paired
            """.utf8
        )

        XCTAssertNoThrow(try MobilePairingClient.validateEnrollmentResponse(valid))
        XCTAssertThrowsError(
            try MobilePairingClient.validateEnrollmentResponse(Data("paired\n".utf8))
        )
    }
}
