import XCTest
@testable import TerminalRelayIOS

@MainActor
final class SharedChatIOSTests: XCTestCase {
    private let relayID = "00000000-0000-4000-8000-000000000001"
    private let threadID = "00000000-0000-4000-8000-000000000002"
    private let generation = "00000000-0000-4000-8000-000000000003"

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
