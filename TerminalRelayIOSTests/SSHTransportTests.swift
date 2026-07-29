import XCTest
@testable import TerminalRelayIOS

final class SSHTransportTests: XCTestCase {
    func testOneShotExecKeepsStandardOutputAndErrorSeparate() throws {
        var accumulator = SSHExecResultAccumulator()
        accumulator.append(Data("protocol\n".utf8), to: .standardOutput)
        accumulator.append(Data("diagnostic\n".utf8), to: .standardError)
        accumulator.recordExitStatus(0)

        XCTAssertNil(accumulator.resultIfComplete())

        accumulator.recordEOF()
        let result = try XCTUnwrap(accumulator.resultIfComplete()).get()
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.standardOutput, as: UTF8.self), "protocol\n")
        XCTAssertEqual(String(decoding: result.standardError, as: UTF8.self), "diagnostic\n")
    }

    func testOneShotExecRetainsFirstExitStatusAcrossDuplicateEvents() throws {
        var accumulator = SSHExecResultAccumulator()
        accumulator.recordExitStatus(17)
        accumulator.recordExitStatus(0)

        let result = try accumulator.resultAtChannelClose().get()
        XCTAssertEqual(result.status, 17)
    }

    func testStreamingExecEventsNeverConflateProtocolAndDiagnostics() {
        let protocolBytes = Data(#"{"v":1}"#.utf8)
        let diagnosticBytes = Data("connection lost".utf8)

        XCTAssertNotEqual(
            SSHStreamingExecEvent.standardOutput(protocolBytes),
            .standardError(protocolBytes)
        )
        XCTAssertEqual(
            SSHStreamingExecEvent.standardOutput(protocolBytes),
            .standardOutput(protocolBytes)
        )
        XCTAssertEqual(
            SSHStreamingExecEvent.standardError(diagnosticBytes),
            .standardError(diagnosticBytes)
        )
        XCTAssertNotEqual(
            SSHStreamingExecEvent.exitStatus(0),
            .exitSignal("TERM")
        )
    }

    func testStreamingFailureClassificationPreservesTrustBoundaryWithoutRawDetails() {
        XCTAssertEqual(
            SSHStreamingExecFailure.classify(SSHTransportError.invalidHostKey),
            .hostKey
        )
        XCTAssertEqual(
            SSHStreamingExecFailure.classify(
                SSHTransportError.hostKeyMismatch(
                    expected: "private-expected-value",
                    actual: "private-actual-value"
                )
            ),
            .hostKey
        )
        XCTAssertEqual(
            SSHStreamingExecFailure.classify(
                SSHTransportError.publicKeyAuthenticationUnavailable
            ),
            .authentication
        )
        XCTAssertEqual(
            SSHStreamingExecFailure.classify(
                SSHTransportError.connection("worker.example.com")
            ),
            .connection
        )

        let hostKeyFailure = IOSSSHChatFailurePolicy.failure(for: .hostKey)
        let authFailure = IOSSSHChatFailurePolicy.failure(for: .authentication)
        let connectionFailure = IOSSSHChatFailurePolicy.failure(for: .connection)
        XCTAssertEqual(hostKeyFailure.category, "host_key")
        XCTAssertEqual(authFailure.category, "authentication")
        XCTAssertEqual(connectionFailure.category, "ssh")
        XCTAssertFalse(hostKeyFailure.message.contains("private-"))
        XCTAssertFalse(authFailure.message.contains("private-"))
        XCTAssertFalse(connectionFailure.message.contains("worker.example.com"))
    }

    func testStreamingConnectionLifecycleIsIdempotentAndReconnectable() {
        var lifecycle = IOSSSHChatConnectionLifecycle()

        XCTAssertEqual(lifecycle.begin(), .started)
        XCTAssertEqual(lifecycle.begin(), .alreadyConnecting)
        XCTAssertTrue(lifecycle.markConnected())
        XCTAssertFalse(lifecycle.markConnected())
        XCTAssertEqual(lifecycle.begin(), .alreadyConnected)
        XCTAssertTrue(lifecycle.finish())
        XCTAssertFalse(lifecycle.finish())

        XCTAssertEqual(lifecycle.begin(), .started)
        XCTAssertTrue(lifecycle.markConnected())
        XCTAssertTrue(lifecycle.finish())
    }

    func testChatStreamDecodesOnlyStandardOutputAndTreatsCleanEOFAsClean() throws {
        let relayID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let eventID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        let envelope = ChatEnvelope(
            type: "session.hello",
            eventID: eventID,
            relayID: relayID,
            provider: .codex,
            sequence: 1
        )
        let line = try ChatNDJSONEncoder.encode(envelope)
        let split = line.index(line.startIndex, offsetBy: max(1, line.count / 2))
        var stream = IOSSSHChatStreamState()

        XCTAssertEqual(
            try stream.receive(.standardOutput(Data(line[..<split]))),
            []
        )
        XCTAssertEqual(
            try stream.receive(
                .standardError(Data(#"{"v":1,"type":"must.not.decode"}\n"#.utf8))
            ),
            []
        )
        XCTAssertEqual(
            try stream.receive(.standardOutput(Data(line[split...]))),
            [envelope]
        )
        XCTAssertEqual(try stream.receive(.exitStatus(0)), [])
        try stream.finish()
        XCTAssertNil(stream.terminationFailure())
    }

    func testChatStreamRejectsMalformedAndUnterminatedProtocol() throws {
        var malformed = IOSSSHChatStreamState()
        XCTAssertThrowsError(
            try malformed.receive(.standardOutput(Data("{nope}\n".utf8)))
        ) { error in
            XCTAssertEqual(
                error as? ChatProtocolError,
                .invalidJSON(
                    ChatProtocolContext(
                        requestID: nil,
                        eventID: nil,
                        sequence: nil
                    )
                )
            )
        }

        var unterminated = IOSSSHChatStreamState()
        XCTAssertEqual(
            try unterminated.receive(
                .standardOutput(Data(#"{"v":1"#.utf8))
            ),
            []
        )
        XCTAssertThrowsError(try unterminated.finish()) { error in
            XCTAssertEqual(error as? ChatProtocolError, .unterminatedRecord)
        }
    }

    func testChatStreamReportsSanitizedRemoteExitAndSignal() throws {
        var exit = IOSSSHChatStreamState()
        _ = try exit.receive(.exitStatus(23))
        XCTAssertEqual(exit.terminationFailure()?.category, "remote_exit")
        XCTAssertTrue(exit.terminationFailure()?.message.contains("23") == true)

        var signal = IOSSSHChatStreamState()
        _ = try signal.receive(.exitSignal("private-remote-value"))
        XCTAssertEqual(signal.terminationFailure()?.category, "remote_signal")
        XCTAssertFalse(
            signal.terminationFailure()?.message.contains("private-remote-value") == true
        )
    }

    func testShortLivedCallbackPumpDeliversFinalNDJSONBeforeEOF() async throws {
        let envelope = ChatEnvelope(
            type: "session.hello",
            eventID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            relayID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            provider: .codex,
            sequence: 1
        )
        let pump = IOSSSHChatOrderedCallbackPump()
        pump.yield(.event(.standardOutput(try ChatNDJSONEncoder.encode(envelope))))
        pump.yield(.event(.exitStatus(0)))
        pump.yield(.state(.disconnected))
        pump.finish()

        var streamState = IOSSSHChatStreamState()
        var callbacks: [String] = []
        var received: [ChatEnvelope] = []
        for await callback in pump.stream {
            switch callback {
            case .event(let event):
                callbacks.append("event")
                received.append(contentsOf: try streamState.receive(event))
            case .state(.disconnected):
                callbacks.append("disconnected")
                try streamState.finish()
            case .state:
                callbacks.append("state")
            }
        }

        XCTAssertEqual(received, [envelope])
        XCTAssertEqual(callbacks, ["event", "event", "disconnected"])
        XCTAssertNil(streamState.terminationFailure())
    }

    func testReconnectPumpCannotConsumeStaleLocalDisconnect() async {
        let oldPump = IOSSSHChatOrderedCallbackPump()
        oldPump.finish()
        guard case .terminated = oldPump.yield(.state(.disconnected)) else {
            return XCTFail("A closed generation must reject late callbacks")
        }

        let newPump = IOSSSHChatOrderedCallbackPump()
        newPump.yield(.state(.connecting))
        newPump.yield(.state(.connected))
        newPump.finish()

        var callbacks: [IOSSSHChatConnectionCallback] = []
        for await callback in newPump.stream {
            callbacks.append(callback)
        }
        XCTAssertEqual(callbacks, [.state(.connecting), .state(.connected)])
    }
}
