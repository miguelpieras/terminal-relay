import Foundation
import XCTest
@testable import TerminalRelay

final class WorkerChatStateTests: XCTestCase {
    private let capabilities =
        #"{"protocolVersion":1,"features":["history","streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#

    func testParsesAvailableCapabilitiesAfterLoginNoise() throws {
        let data = Data(
            """
            login banner
            \(WorkerChatProtocol.marker)
            {"provider":"codex","available":true,"capabilities":\(capabilities),"reason":null}

            """.utf8
        )

        let response = try WorkerChatProtocol.parseCapabilities(data, expectedKind: .codex)

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.capabilities?.protocolVersion, 1)
        XCTAssertEqual(response.capabilities?.features, ["history", "streaming"])
        XCTAssertNil(response.reason)
    }

    func testParsesUnavailableCapabilityReason() throws {
        let data = Data(
            """
            \(WorkerChatProtocol.marker)
            {"provider":"claude","available":false,"capabilities":null,"reason":"sdk-unavailable"}

            """.utf8
        )

        let response = try WorkerChatProtocol.parseCapabilities(data, expectedKind: .claude)

        XCTAssertFalse(response.isAvailable)
        XCTAssertNil(response.capabilities)
        XCTAssertEqual(response.reason, "sdk-unavailable")
    }

    func testParsesChatStartIdentityAndAcceptedOptions() throws {
        let relayID = "11111111-1111-4111-8111-111111111111"
        let threadID = "22222222-2222-4222-8222-222222222222"
        let data = Data(
            """
            \(WorkerChatProtocol.marker)
            {"relayId":"\(relayID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{"model":"gpt-example","fullAccess":true}}

            """.utf8
        )

        let response = try WorkerChatProtocol.parseStart(data, expectedKind: .codex)

        XCTAssertEqual(response.relayID, relayID)
        XCTAssertEqual(response.providerThreadID, threadID)
        XCTAssertEqual(response.launchOptions["model"], .string("gpt-example"))
        XCTAssertEqual(response.launchOptions["fullAccess"], .bool(true))
    }

    func testRejectsMismatchedProviderMalformedIdentityAndExtraRecord() {
        let inputs = [
            """
            \(WorkerChatProtocol.marker)
            {"provider":"claude","available":true,"capabilities":\(capabilities),"reason":null}
            """,
            """
            \(WorkerChatProtocol.marker)
            {"relayId":"NOT-A-UUID","provider":"codex","providerThreadId":"22222222-2222-4222-8222-222222222222","capabilities":\(capabilities),"launchOptions":{}}
            """,
            """
            \(WorkerChatProtocol.marker)
            {"provider":"codex","available":false,"capabilities":null,"reason":"sdk-unavailable"}
            {"unexpected":true}
            """,
        ]

        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(inputs[0].utf8),
                expectedKind: .codex
            )
        )
        XCTAssertThrowsError(
            try WorkerChatProtocol.parseStart(
                Data(inputs[1].utf8),
                expectedKind: .codex
            )
        )
        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(inputs[2].utf8),
                expectedKind: .codex
            )
        )
    }
}
