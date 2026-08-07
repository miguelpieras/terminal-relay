import Foundation
import XCTest
@testable import TerminalRelay

final class WorkerRuntimeStatusTests: XCTestCase {
    func testParsesCompatibleRuntimeInformation() throws {
        let data = Data(
            """
            \(WorkerRuntimeInfoProtocol.marker)
            runtime|2000000000|1|2|agent-sessions,chat-v1,file-attachments-v1,runtime-updates-v1,threads-v1,threads-v2
            """.utf8
        )
        let info = try WorkerRuntimeInfoProtocol.parse(data)
        XCTAssertEqual(info.version, 2_000_000_000)
        XCTAssertTrue(info.isClientProtocolCompatible)
        XCTAssertTrue(info.supports("file-attachments-v1"))
        XCTAssertTrue(info.supports("threads-v2"))
        XCTAssertFalse(info.supports("unknown"))
    }

    func testParsesRuntimeUpdateProgressAndFailure() throws {
        let checking = try WorkerRuntimeUpdateStatusProtocol.parse(
            Data(
                """
                \(WorkerRuntimeUpdateStatusProtocol.marker)
                runtime-update|1785055400|checking|2000000000|2000000001|none
                """.utf8
            )
        )
        XCTAssertEqual(checking?.result, .checking)
        XCTAssertEqual(checking?.message, "Updating worker runtime…")

        let failure = try WorkerRuntimeUpdateStatusProtocol.parse(
            Data(
                """
                \(WorkerRuntimeUpdateStatusProtocol.marker)
                runtime-update|1785055500|failure|2000000000|2000000001|signature-invalid
                """.utf8
            )
        )
        XCTAssertEqual(failure?.failureCode, "signature-invalid")
        XCTAssertNotNil(failure?.message)
    }

    func testRejectsUnsortedCapabilitiesAndUnsafeFailureCode() {
        XCTAssertThrowsError(
            try WorkerRuntimeInfoProtocol.parse(
                Data(
                    """
                    \(WorkerRuntimeInfoProtocol.marker)
                    runtime|2|1|2|threads-v2,agent-sessions
                    """.utf8
                )
            )
        )
        XCTAssertThrowsError(
            try WorkerRuntimeUpdateStatusProtocol.parse(
                Data(
                    """
                    \(WorkerRuntimeUpdateStatusProtocol.marker)
                    runtime-update|1|failure|1|2|private value
                    """.utf8
                )
            )
        )
    }
}
