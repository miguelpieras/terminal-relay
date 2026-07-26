import XCTest
@testable import TerminalRelay

final class WorkerUpdateStatusTests: XCTestCase {
    func testParsesSanitizedSuccessAndFailureRecordsAfterLoginNoise() throws {
        let success = try WorkerUpdateStatusProtocol.parse(
            """
            login banner
            \(WorkerUpdateStatusProtocol.marker)
            update|1700000000|success|1.2.3|4.5.6
            """
        )
        let failure = try WorkerUpdateStatusProtocol.parse(
            """
            \(WorkerUpdateStatusProtocol.marker)
            update|1700000001|failure|unknown|4.5.7-beta
            """
        )

        XCTAssertEqual(
            success,
            WorkerUpdateStatus(
                timestamp: 1_700_000_000,
                result: .success,
                codexVersion: "1.2.3",
                claudeVersion: "4.5.6"
            )
        )
        XCTAssertNil(success?.warningMessage)
        XCTAssertEqual(
            failure?.warningMessage,
            "Automatic agent update failed. Codex unknown and Claude Code 4.5.7-beta remain available; the worker will retry automatically."
        )
    }

    func testMarkerOnlyMeansNoUpdateHasRunYet() throws {
        XCTAssertNil(
            try WorkerUpdateStatusProtocol.parse(
                "\(WorkerUpdateStatusProtocol.marker)\n"
            )
        )
    }

    func testRejectsMissingMarkerMalformedAndSensitiveFields() {
        let invalidOutputs = [
            "update|1700000000|failure|1.2.3|4.5.6",
            "\(WorkerUpdateStatusProtocol.marker)\nupdate|bad|failure|1.2.3|4.5.6",
            "\(WorkerUpdateStatusProtocol.marker)\nupdate|1700000000|partial|1.2.3|4.5.6",
            "\(WorkerUpdateStatusProtocol.marker)\nupdate|1700000000|failure|1.2.3|private value",
            "\(WorkerUpdateStatusProtocol.marker)\nupdate|1700000000|failure|1.2.3|4.5.6\nextra",
        ]

        for output in invalidOutputs {
            XCTAssertThrowsError(try WorkerUpdateStatusProtocol.parse(output))
        }
    }
}
