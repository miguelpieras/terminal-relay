import XCTest
@testable import TerminalRelayIOS

@MainActor
final class SharedChatIOSTests: XCTestCase {
    private let relayID = "00000000-0000-4000-8000-000000000001"
    private let threadID = "00000000-0000-4000-8000-000000000002"
    private let generation = "00000000-0000-4000-8000-000000000003"

    func testSharedInteractiveControlsUse44PointIOSPolicyWithCompactVisualPadding() {
        XCTAssertTrue(ChatInteractionTargetLayout.appliesMinimumDimension)
        XCTAssertEqual(ChatInteractionTargetLayout.minimumIOSDimension, 44)
        XCTAssertEqual(ChatInteractionTargetLayout.jumpButtonDimension, 44)
        XCTAssertEqual(
            ChatInteractionTargetLayout.jumpButtonDimension
                + (2 * ChatInteractionTargetLayout.jumpButtonOuterPadding),
            60,
            "The larger hit target must preserve the existing overlay footprint."
        )
        XCTAssertEqual(ChatInteractionTargetLayout.codeHeaderVerticalPadding, 0)
        XCTAssertEqual(ChatInteractionTargetLayout.compactControlVerticalPadding, 0)
        XCTAssertEqual(ChatInteractionTargetLayout.attachmentChipVerticalPadding, 0)
    }

    func testSharedStreamingCodecAndReducerRunOnIOS() throws {
        let hello = event(
            "session.hello",
            sequence: 0,
            payload: .object([
                "connectionState": .string("streaming"),
                "capabilities": try JSONValue.encoded(
                    ChatCapabilities(features: ["streaming"])
                ),
            ])
        )
        let message = event(
            "message.completed",
            sequence: 1,
            itemID: "message-1",
            payload: .object([
                "role": .string("assistant"),
                "text": .string("Hello from native chat"),
            ])
        )
        let stream = try ChatNDJSONEncoder.encode(hello)
            + ChatNDJSONEncoder.encode(message)
        var decoder = ChatNDJSONDecoder()
        let envelopes = try decoder.append(stream)
        XCTAssertEqual(envelopes, [hello, message])
        XCTAssertNoThrow(try decoder.finish())

        let store = ConversationStore()
        for envelope in envelopes {
            try store.apply(envelope)
        }
        XCTAssertEqual(store.state.connectionState, .streaming)
        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertEqual(store.state.messages.map(\.text), ["Hello from native chat"])
    }

    func testSharedIdleResumeSnapshotInfersActiveTurnOnIOS() throws {
        let activeTurnID = "10000000-0000-4000-8000-000000000010"
        let store = ConversationStore()
        let snapshot = ConversationSnapshot(
            snapshotGeneration: generation,
            baseSequence: 1,
            items: [
                .message(
                    ChatMessage(
                        id: "assistant-stream",
                        turnID: activeTurnID,
                        role: .assistant,
                        text: "Partial response",
                        isStreaming: true
                    )
                ),
            ],
            connectionState: .streaming,
            turnState: .idle
        )

        try store.apply(
            event(
                "conversation.snapshot",
                sequence: 1,
                payload: try JSONValue.encoded(snapshot)
            )
        )

        XCTAssertEqual(store.state.turnState, .running)
        XCTAssertEqual(store.state.activeTurnID, activeTurnID)

        let preItemStore = ConversationStore()
        let preItemSnapshot = ConversationSnapshot(
            snapshotGeneration: generation,
            baseSequence: 1,
            connectionState: .streaming,
            turnState: .unknown("streaming"),
            activeTurnID: activeTurnID
        )
        try preItemStore.apply(
            event(
                "conversation.snapshot",
                sequence: 1,
                payload: try JSONValue.encoded(preItemSnapshot)
            )
        )
        XCTAssertEqual(preItemStore.state.turnState, .running)
        XCTAssertEqual(preItemStore.state.activeTurnID, activeTurnID)
    }

    func testSharedSafeLinkPolicyRunsOnIOS() throws {
        let external = try XCTUnwrap(URL(string: "https://example.com/docs"))
        XCTAssertEqual(ChatURLPolicy.classify(external), .external(external))

        let repository = try XCTUnwrap(
            URL(string: "terminal-relay-file:///Sources/App.swift#L15")
        )
        XCTAssertEqual(
            ChatURLPolicy.classify(repository),
            .repository(
                ChatRepositoryLink(path: "Sources/App.swift", line: 15, column: nil)
            )
        )

        let blocked = try XCTUnwrap(URL(string: "javascript:alert(1)"))
        XCTAssertEqual(ChatURLPolicy.classify(blocked), .blocked)
    }

    func testComposerReturnPolicyKeepsNewlineAndSendDistinctOnIOS() {
        XCTAssertEqual(
            ComposerInputPolicy.returnAction(
                commandKeyPressed: false,
                canSend: true
            ),
            .insertNewline
        )
        XCTAssertEqual(
            ComposerInputPolicy.returnAction(
                commandKeyPressed: true,
                canSend: true
            ),
            .send
        )
        XCTAssertEqual(
            ComposerInputPolicy.returnAction(
                commandKeyPressed: true,
                canSend: false
            ),
            .ignore
        )
    }

    func testSharedDoubleEscapePolicyRunsOnIOS() {
        var policy = ComposerEscapePolicy()

        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20.1, isRepeat: true),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20.02, isRepeat: false),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20.4, isRepeat: false),
            .interrupt
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20.42, isRepeat: false),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20.6, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-ios", timestamp: 20.9, isRepeat: false),
            .interrupt
        )
        XCTAssertEqual(
            policy.action(activeTurnID: nil, timestamp: 21, isRepeat: false),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-next", timestamp: 22, isRepeat: false),
            .armed
        )
    }

    func testMobileComposerLaunchPolicyUsesProviderModelsAndSupportedEfforts() {
        XCTAssertEqual(
            MobileComposerLaunchPolicy.models(for: .codex).map(\.id),
            ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        )
        XCTAssertEqual(
            MobileComposerLaunchPolicy.models(for: .claude).map(\.id),
            ["fable", "opus", "sonnet"]
        )
        XCTAssertTrue(
            MobileComposerLaunchPolicy.availableEfforts(
                provider: .codex,
                model: "gpt-5.6-sol"
            ).contains(.ultra)
        )
        XCTAssertFalse(
            MobileComposerLaunchPolicy.availableEfforts(
                provider: .codex,
                model: "gpt-5.6-luna"
            ).contains(.ultra)
        )
        XCTAssertEqual(
            MobileComposerLaunchPolicy.normalizedEffort(
                .ultra,
                provider: .codex,
                model: "gpt-5.6-luna"
            ),
            .max
        )
        XCTAssertFalse(
            MobileComposerLaunchPolicy.availableEfforts(
                provider: .claude,
                model: "opus"
            ).contains(.ultra)
        )
    }

    private func event(
        _ type: String,
        sequence: Int64,
        itemID: String? = nil,
        payload: JSONValue
    ) -> ChatEnvelope {
        ChatEnvelope(
            type: type,
            eventID: String(
                format: "00000000-0000-4000-8%03lld-%012lld",
                sequence % 1_000,
                sequence
            ),
            relayID: relayID,
            provider: .codex,
            providerThreadID: threadID,
            snapshotGeneration: generation,
            sequence: sequence,
            occurredAt: max(sequence, 0),
            itemID: itemID,
            payload: payload
        )
    }
}
