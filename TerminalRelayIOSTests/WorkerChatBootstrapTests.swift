import XCTest
@testable import TerminalRelayIOS

final class WorkerChatBootstrapTests: XCTestCase {
    private let relayID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let threadID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testParsesAvailableCapabilitiesForTheExpectedProvider() throws {
        let status = try WorkerChatProtocol.parseCapabilities(
            Data(
                """
                login banner
                \(WorkerChatProtocol.marker)
                {"provider":"codex","available":true,"capabilities":{"protocolVersion":1,"features":["streaming","tools"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":true},"reason":null}
                """.utf8
            ),
            expectedKind: .codex
        )

        XCTAssertTrue(status.isAvailable)
        XCTAssertEqual(status.kind, .codex)
        XCTAssertEqual(status.capabilities?.protocolVersion, 1)
        XCTAssertEqual(status.capabilities?.features, ["streaming", "tools"])
        XCTAssertTrue(status.capabilities?.supportsAttachments == true)
        XCTAssertNil(status.reason)
    }

    func testParsesUnavailableCapabilityWithoutInventingFeatures() throws {
        let status = try WorkerChatProtocol.parseCapabilities(
            Data(
                """
                \(WorkerChatProtocol.marker)
                {"provider":"claude","available":false,"capabilities":null,"reason":"sdk-unavailable"}
                """.utf8
            ),
            expectedKind: .claude
        )

        XCTAssertFalse(status.isAvailable)
        XCTAssertNil(status.capabilities)
        XCTAssertEqual(status.reason, "sdk-unavailable")
    }

    func testParsesStartedIdentityAndIgnoresForwardCompatibleLaunchMetadata() throws {
        let status = try WorkerChatProtocol.parseStart(
            Data(
                """
                \(WorkerChatProtocol.marker)
                {"relayId":"\(relayID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":true},"launchOptions":{"model":"gpt","effort":"high","permissionMode":"default","fullAccess":false,"fastMode":false}}
                """.utf8
            ),
            expectedKind: .codex
        )

        XCTAssertEqual(
            status.relayID,
            relayID
        )
        XCTAssertEqual(status.kind, .codex)
        XCTAssertEqual(status.providerThreadID, threadID)
        XCTAssertEqual(status.capabilities.features, ["streaming"])
    }

    func testRejectsMissingMarkerWrongProviderAndNonCanonicalIdentity() {
        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data("{}".utf8),
                expectedKind: .codex
            )
        ) { error in
            XCTAssertEqual(
                error as? WorkerChatProtocolError,
                .missingMarker
            )
        }

        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(
                    """
                    \(WorkerChatProtocol.marker)
                    {"provider":"claude","available":true,"capabilities":{"protocolVersion":1,"features":[],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":false},"reason":null}
                    """.utf8
                ),
                expectedKind: .codex
            )
        )

        XCTAssertThrowsError(
            try WorkerChatProtocol.parseStart(
                Data(
                    """
                    \(WorkerChatProtocol.marker)
                    {"relayId":"\(relayID.uppercased())","provider":"codex","providerThreadId":"\(threadID)","capabilities":{"protocolVersion":1,"features":[],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":true},"launchOptions":{}}
                    """.utf8
                ),
                expectedKind: .codex
            )
        )
    }

    func testRejectsUnsafeUnavailableReasonAndExtraRecords() {
        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(
                    """
                    \(WorkerChatProtocol.marker)
                    {"provider":"codex","available":false,"capabilities":null,"reason":"worker.example.com: secret"}
                    """.utf8
                ),
                expectedKind: .codex
            )
        )

        XCTAssertThrowsError(
            try WorkerChatProtocol.parseCapabilities(
                Data(
                    """
                    \(WorkerChatProtocol.marker)
                    {"provider":"codex","available":false,"capabilities":null,"reason":"not_ready"}
                    {"provider":"codex","available":false,"capabilities":null,"reason":"not_ready"}
                    """.utf8
                ),
                expectedKind: .codex
            )
        )
    }
}
