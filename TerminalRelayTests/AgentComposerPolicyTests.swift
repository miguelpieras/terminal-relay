import AppKit
import XCTest
@testable import TerminalRelay

final class AgentComposerPolicyTests: XCTestCase {
    func testClipboardFileURLsReadsFinderStyleFileCopies() throws {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("AgentComposerPolicyTests.files")
        )
        pasteboard.clearContents()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try Data("clipboard file".utf8).write(to: fileURL)
        defer {
            try? FileManager.default.removeItem(at: fileURL)
            pasteboard.clearContents()
        }

        XCTAssertTrue(pasteboard.writeObjects([fileURL as NSURL]))
        XCTAssertEqual(ClipboardFileURLs.read(from: pasteboard), [fileURL])
    }

    func testProjectWorkspaceStartsWithTheEnvironmentSidebarVisible() {
        XCTAssertTrue(
            ProjectWorkspaceLayoutPolicy.showsEnvironmentSidebarByDefault
        )
    }

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
            canSend(draft: "Ship it", isSubmitting: true)
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

    func testComposerEscapePolicyRequiresTwoDeliberateEscapesForTheActiveTurn() {
        var policy = ComposerEscapePolicy()

        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1.1, isRepeat: true),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1.2, isRepeat: false),
            .interrupt
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1.3, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1.4, isRepeat: false),
            .interrupt
        )
    }

    func testComposerEscapePolicyRearmsForTimeoutAndTheNextTurn() {
        var policy = ComposerEscapePolicy(maximumInterval: 0.8, minimumInterval: 0.05)

        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 1.01, isRepeat: false),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 2, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-2", timestamp: 2.2, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: nil, timestamp: 2.4, isRepeat: false),
            .ignored
        )
    }

    func testComposerRestorationRequiresTheExactFailedSubmission() {
        let attachment = ChatAttachmentReference(
            id: "attachment-1",
            path: "/tmp/example.png",
            displayName: "Example",
            mediaType: "image/png"
        )

        XCTAssertTrue(
            AgentComposerRestorationPolicy.shouldRestore(
                submittedPrompt: "Review this",
                submittedAttachments: [attachment],
                restoredDraft: "Review this",
                restoredAttachments: [attachment]
            )
        )
        XCTAssertFalse(
            AgentComposerRestorationPolicy.shouldRestore(
                submittedPrompt: "Review this",
                submittedAttachments: [attachment],
                restoredDraft: "A different failed message",
                restoredAttachments: [attachment]
            )
        )
        XCTAssertFalse(
            AgentComposerRestorationPolicy.shouldRestore(
                submittedPrompt: "Review this",
                submittedAttachments: [attachment],
                restoredDraft: "Review this",
                restoredAttachments: []
            )
        )
    }

    func testNativeSubmissionLatchReleasesForAuthoritativeTurnOrConnectionLoss() {
        XCTAssertTrue(
            AgentComposerSubmissionPolicy.shouldReleaseSendLatch(
                connectionState: .streaming,
                turnState: .running,
                activeTurnID: "turn-1"
            )
        )
        XCTAssertTrue(
            AgentComposerSubmissionPolicy.shouldReleaseSendLatch(
                connectionState: .offlineAgentRunning,
                turnState: .idle,
                activeTurnID: nil
            )
        )
        XCTAssertFalse(
            AgentComposerSubmissionPolicy.shouldReleaseSendLatch(
                connectionState: .streaming,
                turnState: .idle,
                activeTurnID: nil
            )
        )
    }

    private func canSend(
        status: TerminalSessionStatus = .running,
        usesNativeChat: Bool = true,
        isWorking: Bool = false,
        draft: String,
        hasUploadingAttachments: Bool = false,
        hasFailedAttachments: Bool = false,
        hasUploadedAttachments: Bool = false,
        isSubmitting: Bool = false
    ) -> Bool {
        AgentComposerSendPolicy.canSend(
            status: status,
            usesNativeChat: usesNativeChat,
            isWorking: isWorking,
            draft: draft,
            hasUploadingAttachments: hasUploadingAttachments,
            hasFailedAttachments: hasFailedAttachments,
            hasUploadedAttachments: hasUploadedAttachments,
            isSubmitting: isSubmitting
        )
    }
}
