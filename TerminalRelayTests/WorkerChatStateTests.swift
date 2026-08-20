import Foundation
import XCTest
@testable import TerminalRelay

final class WorkerChatStateTests: XCTestCase {
    private let accountID = ProviderAccountID(
        UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    )
    private let capabilities =
        #"{"protocolVersion":2,"features":["history","streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false}"#

    func testParsesAvailableCapabilitiesAfterLoginNoise() throws {
        let data = Data(
            """
            login banner
            \(WorkerChatProtocol.marker)
            {"provider":"codex","accountID":"\(accountID.rawValue)","available":true,"capabilities":\(capabilities),"reason":null}

            """.utf8
        )

        let response = try WorkerChatProtocol.parseCapabilities(
            data,
            expectedKind: .codex,
            expectedAccountID: accountID
        )

        XCTAssertTrue(response.isAvailable)
        XCTAssertEqual(response.accountID, accountID)
        XCTAssertEqual(response.capabilities?.protocolVersion, 2)
        XCTAssertEqual(response.capabilities?.features, ["history", "streaming"])
        XCTAssertNil(response.reason)
    }

    func testParsesUnavailableCapabilityReason() throws {
        let data = Data(
            """
            \(WorkerChatProtocol.marker)
            {"provider":"claude","accountID":"\(accountID.rawValue)","available":false,"capabilities":null,"reason":"sdk-unavailable"}

            """.utf8
        )

        let response = try WorkerChatProtocol.parseCapabilities(
            data,
            expectedKind: .claude,
            expectedAccountID: accountID
        )

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
            {"relayId":"\(relayID)","provider":"codex","accountID":"\(accountID.rawValue)","providerThreadId":"\(threadID)","capabilities":\(capabilities),"launchOptions":{"model":"gpt-example","fullAccess":true}}

            """.utf8
        )

        let response = try WorkerChatProtocol.parseStart(
            data,
            expectedKind: .codex,
            expectedAccountID: accountID
        )

        XCTAssertEqual(response.relayID, relayID)
        XCTAssertEqual(response.accountID, accountID)
        XCTAssertEqual(response.providerThreadID, threadID)
        XCTAssertEqual(response.launchOptions["model"], .string("gpt-example"))
        XCTAssertEqual(response.launchOptions["fullAccess"], .bool(true))
    }

    func testRejectsMismatchedProviderMalformedIdentityAndExtraRecord() {
        let inputs = [
            """
            \(WorkerChatProtocol.marker)
            {"provider":"claude","accountID":"\(accountID.rawValue)","available":true,"capabilities":\(capabilities),"reason":null}
            """,
            """
            \(WorkerChatProtocol.marker)
            {"relayId":"NOT-A-UUID","provider":"codex","accountID":"\(accountID.rawValue)","providerThreadId":"22222222-2222-4222-8222-222222222222","capabilities":\(capabilities),"launchOptions":{}}
            """,
            """
            \(WorkerChatProtocol.marker)
            {"provider":"codex","accountID":"\(accountID.rawValue)","available":false,"capabilities":null,"reason":"sdk-unavailable"}
            {"unexpected":true}
            """,
        ]

        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(inputs[0].utf8),
                expectedKind: .codex,
                expectedAccountID: accountID
            )
        )
        XCTAssertThrowsError(
            try WorkerChatProtocol.parseStart(
                Data(inputs[1].utf8),
                expectedKind: .codex,
                expectedAccountID: accountID
            )
        )
        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(inputs[2].utf8),
                expectedKind: .codex,
                expectedAccountID: accountID
            )
        )
    }
}
