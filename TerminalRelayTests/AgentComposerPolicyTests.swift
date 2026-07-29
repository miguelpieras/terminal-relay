import AppKit
import XCTest
@testable import TerminalRelay

final class AgentComposerPolicyTests: XCTestCase {
    func testNativeChatSendPolicyCoversEveryBlockingState() {
        XCTAssertTrue(
            canSend(draft: "Ship it")
        )
        XCTAssertTrue(
            canSend(draft: "", hasUploadedAttachments: true)
        )
        XCTAssertFalse(
            canSend(status: .connecting, draft: "Ship it")
        )
        XCTAssertFalse(
            canSend(isWorking: true, draft: "Do this next")
        )
        XCTAssertTrue(
            canSend(usesNativeChat: false, isWorking: true, draft: "Terminal follow-up")
        )
        XCTAssertFalse(
            canSend(draft: "Ship it", hasUploadingAttachments: true)
        )
        XCTAssertFalse(
            canSend(
                draft: "Ship it",
                hasFailedAttachments: true,
                hasUploadedAttachments: true
            )
        )
        XCTAssertFalse(
            canSend(draft: " \n ")
        )
    }

    func testComposerReturnEscapeAndSystemKeyPolicy() {
        XCTAssertEqual(
            AgentComposerKeyPolicy.action(keyCode: 36, modifiers: []),
            .submit
        )
        XCTAssertEqual(
            AgentComposerKeyPolicy.action(keyCode: 76, modifiers: [.command]),
            .submit
        )
        XCTAssertEqual(
            AgentComposerKeyPolicy.action(keyCode: 36, modifiers: [.shift]),
            .insertNewline
        )
        XCTAssertEqual(
            AgentComposerKeyPolicy.action(keyCode: 53, modifiers: []),
            .escape
        )
        XCTAssertEqual(
            AgentComposerKeyPolicy.action(keyCode: 0, modifiers: []),
            .system
        )
    }

    private func canSend(
        status: TerminalSessionStatus = .running,
        usesNativeChat: Bool = true,
        isWorking: Bool = false,
        draft: String,
        hasUploadingAttachments: Bool = false,
        hasFailedAttachments: Bool = false,
        hasUploadedAttachments: Bool = false
    ) -> Bool {
        AgentComposerSendPolicy.canSend(
            status: status,
            usesNativeChat: usesNativeChat,
            isWorking: isWorking,
            draft: draft,
            hasUploadingAttachments: hasUploadingAttachments,
            hasFailedAttachments: hasFailedAttachments,
            hasUploadedAttachments: hasUploadedAttachments
        )
    }
}
