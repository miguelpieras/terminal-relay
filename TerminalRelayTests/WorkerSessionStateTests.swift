import XCTest
@testable import TerminalRelay

final class WorkerSessionStateTests: XCTestCase {
    func testParsesProjectsAndActiveSessionsAfterLoginNoise() throws {
        let response = try WorkerSessionProtocol.parse(
            """
            login banner
            __TERMINAL_RELAY_SESSION_V1__
            project|website-api
            project|terminal-relay
            session|codex|terminal-relay|2|01234567-89AB-4DEF-8ABC-0123456789AB
            session|claude|website-api|0|11111111-2222-4333-8444-555555555555
            """
        )

        XCTAssertEqual(response.projects, ["terminal-relay", "website-api"])
        XCTAssertEqual(
            response.sessions,
            [
                WorkerSessionSnapshot(
                    kind: .claude,
                    repositoryName: "website-api",
                    attachedClientCount: 0,
                    instanceToken: "11111111-2222-" + "4333-8444-555555555555"
                ),
                WorkerSessionSnapshot(
                    kind: .codex,
                    repositoryName: "terminal-relay",
                    attachedClientCount: 2,
                    instanceToken: "01234567-89ab-" + "4def-8abc-0123456789ab"
                )
            ]
        )
    }

    func testRejectsMissingProtocolMarker() {
        XCTAssertThrowsError(try WorkerSessionProtocol.parse("session|codex|terminal-relay|1")) {
            XCTAssertEqual($0 as? WorkerSessionProtocolError, .missingMarker)
        }
    }

    func testRejectsDuplicateAgentSlotsAndUnsafeProjectNames() {
        let duplicateSlot = """
        __TERMINAL_RELAY_SESSION_V1__
        session|codex|terminal-relay|1|01234567-89ab-4def-8abc-0123456789ab
        session|codex|website-api|0|11111111-2222-4333-8444-555555555555
        """
        XCTAssertThrowsError(try WorkerSessionProtocol.parse(duplicateSlot)) {
            XCTAssertEqual($0 as? WorkerSessionProtocolError, .invalidRecord)
        }

        let unsafeProject = """
        __TERMINAL_RELAY_SESSION_V1__
        project|../secrets
        """
        XCTAssertThrowsError(try WorkerSessionProtocol.parse(unsafeProject)) {
            XCTAssertEqual($0 as? WorkerSessionProtocolError, .invalidRecord)
        }

        let malformedToken = """
        __TERMINAL_RELAY_SESSION_V1__
        session|claude|website-api|0|not-a-uuid
        """
        XCTAssertThrowsError(try WorkerSessionProtocol.parse(malformedToken)) {
            XCTAssertEqual($0 as? WorkerSessionProtocolError, .invalidRecord)
        }
    }
}
