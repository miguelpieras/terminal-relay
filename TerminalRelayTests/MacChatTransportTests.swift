import Foundation
import XCTest
@testable import TerminalRelay

final class MacChatTransportTests: XCTestCase {
    private let relayID = "11111111-1111-1111-1111-111111111111"
    private let accountID = ProviderAccountID(
        UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    )

    func testConnectSendDecodeAndCleanDisconnect() async throws {
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(executable: "/bin/cat", arguments: [])
        )
        let events = await transport.events()
        try await transport.connect()

        let envelope = ChatEnvelope(
            type: "ping",
            requestID: "22222222-2222-2222-2222-222222222222",
            relayID: relayID,
            provider: .codex,
            accountID: accountID,
            sentAt: 1,
            payload: .object([:])
        )
        try await transport.send(envelope)

        let received = await collect(events, count: 1)?.first
        XCTAssertEqual(received, .envelope(envelope))
        await transport.disconnect()

        try await transport.connect()
        await transport.disconnect()
    }

    func testFragmentedMultibyteOutputAndMultipleRecords() async throws {
        let first = event(
            type: "message.delta",
            eventID: "33333333-3333-3333-3333-333333333333",
            sequence: 1,
            payload: .object(["delta": .string("café ☕️")])
        )
        let second = event(
            type: "turn.completed",
            eventID: "44444444-4444-4444-4444-444444444444",
            sequence: 2
        )
        var bytes = try ChatNDJSONEncoder.encode(first)
        bytes.append(try ChatNDJSONEncoder.encode(second))
        let multibyteIndex = try XCTUnwrap(
            bytes.firstIndex(where: { $0 >= 0x80 })
        )
        let splitIndex = bytes.index(after: multibyteIndex)
        let firstFragment = Data(bytes[..<splitIndex]).base64EncodedString()
        let secondFragment = Data(bytes[splitIndex...]).base64EncodedString()
        let script = """
        printf '%s' '\(firstFragment)' | /usr/bin/base64 -D
        /bin/sleep 0.02
        printf '%s' '\(secondFragment)' | /usr/bin/base64 -D
        """
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", script]
            )
        )
        let events = await transport.events()
        try await transport.connect()

        let collected = await collect(events, count: 3)
        let received = try XCTUnwrap(collected)
        XCTAssertEqual(
            received,
            [.envelope(first), .envelope(second), .disconnected(nil)]
        )
    }

    func testMalformedProtocolDisconnectsOnceWithSanitizedFailure() async throws {
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(
                executable: "/bin/sh",
                arguments: ["-c", "printf '%s\\n' 'private malformed payload'"]
            )
        )
        let events = await transport.events()
        try await transport.connect()
        guard case .disconnected(let failure) = await collect(events, count: 1)?.first else {
            return XCTFail("Expected protocol disconnect")
        }
        XCTAssertEqual(failure?.category, "protocol_error")
        XCTAssertFalse(failure?.message.contains("private malformed payload") ?? true)
        XCTAssertEqual(failure?.isRecoverable, false)
    }

    func testUnterminatedRecordIsProtocolFailure() async throws {
        let valid = event(
            type: "session.hello",
            eventID: "55555555-5555-5555-5555-555555555555",
            sequence: 1
        )
        let data = try JSONEncoder.chat.encode(valid)
        let base64 = data.base64EncodedString()
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s' '\(base64)' | /usr/bin/base64 -D",
                ]
            )
        )
        let events = await transport.events()
        try await transport.connect()
        guard case .disconnected(let failure) = await collect(events, count: 1)?.first else {
            return XCTFail("Expected protocol disconnect")
        }
        XCTAssertEqual(failure?.category, "protocol_error")
    }

    func testClassifiesHostKeyFailureWithoutLeakingDiagnostic() async throws {
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "printf '%s' 'Host key verification failed: secret-host' >&2; exit 255",
                ]
            )
        )
        let events = await transport.events()
        try await transport.connect()
        guard case .disconnected(let failure) = await collect(events, count: 1)?.first else {
            return XCTFail("Expected transport failure")
        }
        XCTAssertEqual(failure?.category, "host_key_failed")
        XCTAssertFalse(failure?.message.contains("secret-host") ?? true)
        XCTAssertEqual(failure?.isRecoverable, false)
    }

    func testRepeatedConnectAndDisconnectAreSafe() async throws {
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(executable: "/bin/cat", arguments: [])
        )

        try await transport.connect()
        do {
            try await transport.connect()
            XCTFail("Expected duplicate connection to fail")
        } catch let failure as ChatTransportFailure {
            XCTAssertEqual(failure.category, "already_connected")
        }

        await transport.disconnect()
        await transport.disconnect()

        try await transport.connect()
        await transport.disconnect()
    }

    func testCancelledConsumerCanReconnectWithFreshEventStream() async throws {
        let transport = MacChatTransport(
            configuration: SSHLaunchConfiguration(executable: "/bin/cat", arguments: [])
        )
        let firstEvents = await transport.events()
        try await transport.connect()
        let firstEventReceived = expectation(description: "first event received")
        let firstConsumer = Task {
            var iterator = firstEvents.makeAsyncIterator()
            let received = await iterator.next()
            firstEventReceived.fulfill()
            _ = await iterator.next()
            return received
        }
        let first = event(
            type: "session.hello",
            eventID: "66666666-6666-6666-6666-666666666666",
            sequence: 1
        )
        try await transport.send(first)
        await fulfillment(of: [firstEventReceived], timeout: 2)
        firstConsumer.cancel()
        let firstReceived = await firstConsumer.value
        XCTAssertEqual(firstReceived, .envelope(first))
        await transport.disconnect()

        let secondEvents = await transport.events()
        try await transport.connect()
        let second = event(
            type: "session.hello",
            eventID: "77777777-7777-7777-7777-777777777777",
            sequence: 2
        )
        try await transport.send(second)
        let secondReceived = await collect(secondEvents, count: 1)
        XCTAssertEqual(secondReceived, [.envelope(second)])
        await transport.disconnect()
    }

    private func event(
        type: String,
        eventID: String,
        sequence: Int64,
        payload: JSONValue = .object([:])
    ) -> ChatEnvelope {
        ChatEnvelope(
            type: type,
            eventID: eventID,
            relayID: relayID,
            provider: .codex,
            accountID: accountID,
            snapshotGeneration: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            sequence: sequence,
            occurredAt: sequence,
            payload: payload
        )
    }

    private func collect(
        _ stream: AsyncStream<ChatTransportEvent>,
        count: Int,
        timeoutNanoseconds: UInt64 = 2_000_000_000
    ) async -> [ChatTransportEvent]? {
        await withTaskGroup(of: [ChatTransportEvent]?.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                var values: [ChatTransportEvent] = []
                while values.count < count, let event = await iterator.next() {
                    values.append(event)
                }
                return values.count == count ? values : nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }
}
