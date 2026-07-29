import XCTest
@testable import TerminalRelayIOS

@MainActor
final class MobileChatSessionControllerTests: XCTestCase {
    private let relayID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let threadID = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testExistingTerminalRouteBypassesChatCapabilityCheck() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = MobileChatSessionController(
            route: TerminalRoute(
                kind: .codex,
                repositoryName: "example",
                instanceToken: relayID,
                providerThreadID: threadID,
                presentation: .terminal
            ),
            dependencies: recorder.dependencies
        )

        controller.start()

        XCTAssertEqual(controller.phase, .terminalFallback(reason: nil))
        XCTAssertEqual(recorder.commands, [])
    }

    func testUnavailableWorkerFallsBackWithoutStartingAnAgent() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: false),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)

        controller.start()
        await waitForSettledPhase(controller)

        guard case .terminalFallback(let reason) = controller.phase else {
            return XCTFail("Expected terminal fallback")
        }
        XCTAssertNotNil(reason)
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertTrue(recorder.commands[0].contains("chat-capabilities-v1"))
        XCTAssertFalse(recorder.commands[0].contains("chat-start-v1"))
    }

    func testLegacyWorkerWithoutCapabilityMarkerFallsBackWithoutStartingAgent() async {
        let recorder = CommandRecorder(
            capabilityData: Data("legacy worker output".utf8),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)

        controller.start()
        await waitForSettledPhase(controller)

        guard case .terminalFallback(let reason) = controller.phase else {
            return XCTFail("Expected legacy terminal fallback")
        }
        XCTAssertTrue(reason?.contains("Update this worker") == true)
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertFalse(recorder.commands[0].contains("chat-start-v1"))
    }

    func testUnavailableWorkerDoesNotExposeRawTerminalForExistingChat() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: false),
            startData: startData()
        )
        let controller = makeExistingChatController(recorder: recorder)

        controller.start()
        await waitForSettledPhase(controller)

        guard case .failed(let message) = controller.phase else {
            return XCTFail("Expected the existing chat to fail closed")
        }
        XCTAssertTrue(message.contains("still running"))
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertTrue(recorder.commands[0].contains("chat-capabilities-v1"))
        XCTAssertFalse(recorder.commands[0].contains("chat-start-v1"))
        let envelopes = await recorder.transport.sentEnvelopes()
        XCTAssertTrue(envelopes.isEmpty)
    }

    func testLegacyWorkerDoesNotExposeRawTerminalForExistingChat() async {
        let recorder = CommandRecorder(
            capabilityData: Data("legacy worker output".utf8),
            startData: startData()
        )
        let controller = makeExistingChatController(recorder: recorder)

        controller.start()
        await waitForSettledPhase(controller)

        guard case .failed(let message) = controller.phase else {
            return XCTFail("Expected the existing chat to fail closed")
        }
        XCTAssertTrue(message.contains("still running"))
        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertTrue(recorder.commands[0].contains("chat-capabilities-v1"))
        XCTAssertFalse(recorder.commands[0].contains("chat-start-v1"))
        let envelopes = await recorder.transport.sentEnvelopes()
        XCTAssertTrue(envelopes.isEmpty)
    }

    func testNewChatChecksCapabilityStartsAndAttachesInOrder() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)

        controller.start()
        controller.start()
        await waitForPhase(.chat, controller: controller)
        await waitForEnvelopeCount(1, recorder: recorder)

        XCTAssertEqual(recorder.commands.count, 2)
        XCTAssertTrue(recorder.commands[0].contains("chat-capabilities-v1"))
        XCTAssertTrue(recorder.commands[1].contains("chat-start-v1"))
        let envelopes = await recorder.transport.sentEnvelopes()
        XCTAssertEqual(envelopes.first?.type, "session.attach")
        XCTAssertEqual(envelopes.first?.relayID, relayID)
    }

    func testExistingChatAttachesWithoutStartingASecondAgent() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = MobileChatSessionController(
            route: TerminalRoute(
                kind: .codex,
                repositoryName: "example",
                instanceToken: relayID,
                providerThreadID: threadID,
                presentation: .chat
            ),
            dependencies: recorder.dependencies
        )

        controller.start()
        await waitForPhase(.chat, controller: controller)
        await waitForEnvelopeCount(1, recorder: recorder)

        XCTAssertEqual(recorder.commands.count, 1)
        XCTAssertTrue(recorder.commands[0].contains("chat-capabilities-v1"))
        XCTAssertFalse(recorder.commands[0].contains("chat-start-v1"))
        let envelopes = await recorder.transport.sentEnvelopes()
        XCTAssertEqual(envelopes.first?.type, "session.attach")
    }

    func testBackgroundDetachAndForegroundResumeSendDistinctAttachLifecycle() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)
        await waitForEnvelopeCount(1, recorder: recorder)

        await controller.suspendForBackground()
        let afterDetach = await recorder.transport.sentEnvelopes()
        XCTAssertEqual(afterDetach.map(\.type), ["session.attach", "session.detach"])
        XCTAssertEqual(
            controller.coordinator?.store.state.connectionState,
            .offlineAgentRunning
        )

        controller.reconnectAfterForeground()
        await waitForEnvelopeCount(3, recorder: recorder)
        let afterReconnect = await recorder.transport.sentEnvelopes()
        XCTAssertEqual(
            afterReconnect.map(\.type),
            ["session.attach", "session.detach", "session.attach"]
        )
    }

    func testBackgroundDuringPreparationCancelsWorkAndForegroundRetries() async {
        let recorder = BackgroundPreparationRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = MobileChatSessionController(
            route: TerminalRoute(
                kind: .codex,
                repositoryName: "example",
                instanceToken: nil
            ),
            dependencies: recorder.dependencies
        )

        controller.start()
        await recorder.waitForFirstCapabilityAttempt()
        await controller.suspendForBackground()

        XCTAssertEqual(controller.phase, .preparing)
        XCTAssertEqual(recorder.startCommandCount, 0)

        controller.reconnectAfterForeground()
        await waitForPhase(.chat, controller: controller)

        XCTAssertEqual(recorder.capabilityCommandCount, 2)
        XCTAssertEqual(recorder.startCommandCount, 1)
    }

    func testLocalDetachNeverIssuesExactStop() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)
        await waitForEnvelopeCount(1, recorder: recorder)

        await controller.detach()

        XCTAssertFalse(recorder.commands.contains { $0.contains("chat-stop-v1") })
        let envelopes = await recorder.transport.sentEnvelopes()
        XCTAssertEqual(envelopes.last?.type, "session.detach")
    }

    func testStopUsesExactRelayAndDoesNotStartTerminal() async throws {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)
        await waitForEnvelopeCount(1, recorder: recorder)

        try await controller.stopChat()

        XCTAssertEqual(controller.phase, .stopped)
        XCTAssertEqual(
            recorder.commands.last,
            "'/usr/local/bin/terminal-relay-session' 'chat-stop-v1' 'codex' 'example' '\(relayID)'"
        )
    }

    func testTerminalFallbackStopsChatAndPreservesProviderThreadForResume() async throws {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)

        var configuredThreadID: String?
        try await controller.openTerminalFallback {
            configuredThreadID = $0
            return true
        }

        XCTAssertEqual(controller.phase, .terminalFallback(reason: nil))
        XCTAssertEqual(controller.terminalProviderThreadID, threadID)
        XCTAssertEqual(configuredThreadID, threadID)
        XCTAssertEqual(
            try TerminalSessionCommandPolicy.launchCommand(
                kind: .codex,
                repositoryName: "example",
                providerThreadID: configuredThreadID,
                launchArguments: []
            ),
            "'/usr/local/bin/terminal-relay-session' 'thread-resume-v2' 'codex' 'example' '\(threadID)'"
        )
        XCTAssertTrue(recorder.commands.last?.contains("chat-stop-v1") == true)
    }

    func testFailedStopKeepsChatReconnectableAndDoesNotEnterTerminal() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData(),
            failuresRemaining: 1,
            failureCommandSubstring: "chat-stop-v1"
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)
        await waitForEnvelopeCount(1, recorder: recorder)

        do {
            try await controller.openTerminalFallback { _ in
                XCTFail("Terminal must not bind when exact stop fails")
                return true
            }
            XCTFail("Expected the exact stop to fail")
        } catch {
            XCTAssertEqual(error as? MobileChatSessionError, .stopFailed)
        }
        await waitForEnvelopeCount(3, recorder: recorder)

        XCTAssertEqual(controller.phase, .chat)
        XCTAssertEqual(controller.terminalProviderThreadID, threadID)
        let envelopes = await recorder.transport.sentEnvelopes()
        XCTAssertEqual(
            envelopes.map(\.type),
            ["session.attach", "session.detach", "session.attach"]
        )
    }

    func testTerminalFallbackConfigurationFailureNeverBindsTerminal() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData()
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)

        do {
            try await controller.openTerminalFallback { _ in false }
            XCTFail("Expected fallback configuration to fail closed")
        } catch {
            XCTAssertEqual(
                error as? MobileChatSessionError,
                .terminalFallbackUnavailable
            )
        }

        guard case .failed(let message) = controller.phase else {
            return XCTFail("The stopped chat must not bind an unconfigured terminal")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(recorder.commands.last?.contains("chat-stop-v1") == true)
    }

    func testRepeatedTerminalFallbackTapSendsOneExactStop() async throws {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData(),
            stopDelayNanoseconds: 100_000_000
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)

        let first = Task {
            try await controller.openTerminalFallback { _ in true }
        }
        await waitForCommand("chat-stop-v1", recorder: recorder)

        do {
            try await controller.openTerminalFallback { _ in true }
            XCTFail("A repeated fallback tap must not start another transition")
        } catch {
            XCTAssertEqual(error as? MobileChatSessionError, .sessionNotReady)
        }
        try await first.value

        XCTAssertEqual(
            recorder.commands.filter { $0.contains("chat-stop-v1") }.count,
            1
        )
        XCTAssertEqual(controller.phase, .terminalFallback(reason: nil))
    }

    func testRepeatedStopTapSendsOneExactStop() async throws {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData(),
            stopDelayNanoseconds: 100_000_000
        )
        let controller = makeNewController(recorder: recorder)
        controller.start()
        await waitForPhase(.chat, controller: controller)

        let first = Task {
            try await controller.stopChat()
        }
        await waitForCommand("chat-stop-v1", recorder: recorder)

        do {
            try await controller.stopChat()
            XCTFail("A repeated stop tap must not issue another command")
        } catch {
            XCTAssertEqual(error as? MobileChatSessionError, .sessionNotReady)
        }
        try await first.value

        XCTAssertEqual(
            recorder.commands.filter { $0.contains("chat-stop-v1") }.count,
            1
        )
        XCTAssertEqual(controller.phase, .stopped)
    }

    func testPreparationFailureIsSanitizedAndRetryable() async {
        let recorder = CommandRecorder(
            capabilityData: capabilityData(available: true),
            startData: startData(),
            failuresRemaining: 1
        )
        let controller = makeNewController(recorder: recorder)

        controller.start()
        await waitForSettledPhase(controller)
        guard case .failed(let message) = controller.phase else {
            return XCTFail("Expected failure")
        }
        XCTAssertFalse(message.contains("private-worker.example.com"))

        controller.retryPreparation()
        await waitForPhase(.chat, controller: controller)
    }

    private func makeNewController(
        recorder: CommandRecorder
    ) -> MobileChatSessionController {
        MobileChatSessionController(
            route: TerminalRoute(
                kind: .codex,
                repositoryName: "example",
                instanceToken: nil
            ),
            dependencies: recorder.dependencies
        )
    }

    private func makeExistingChatController(
        recorder: CommandRecorder
    ) -> MobileChatSessionController {
        MobileChatSessionController(
            route: TerminalRoute(
                kind: .codex,
                repositoryName: "example",
                instanceToken: relayID,
                providerThreadID: threadID,
                presentation: .chat
            ),
            dependencies: recorder.dependencies
        )
    }

    private func capabilityData(available: Bool) -> Data {
        if available {
            return Data(
                """
                \(WorkerChatProtocol.marker)
                {"provider":"codex","available":true,"capabilities":{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":true},"reason":null}
                """.utf8
            )
        }
        return Data(
            """
            \(WorkerChatProtocol.marker)
            {"provider":"codex","available":false,"capabilities":null,"reason":"not-ready"}
            """.utf8
        )
    }

    private func startData() -> Data {
        Data(
            """
            \(WorkerChatProtocol.marker)
            {"relayId":"\(relayID)","provider":"codex","providerThreadId":"\(threadID)","capabilities":{"protocolVersion":1,"features":["streaming"],"supportsHistory":true,"supportsFilePreview":true,"supportsApprovals":true,"supportsQuestions":true,"supportsAttachments":true},"launchOptions":{}}
            """.utf8
        )
    }

    private func waitForSettledPhase(
        _ controller: MobileChatSessionController
    ) async {
        for _ in 0..<200 {
            if controller.phase != .preparing { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for chat preparation")
    }

    private func waitForPhase(
        _ phase: MobileChatSessionPhase,
        controller: MobileChatSessionController
    ) async {
        for _ in 0..<200 {
            if controller.phase == phase { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(phase)")
    }

    private func waitForEnvelopeCount(
        _ count: Int,
        recorder: CommandRecorder
    ) async {
        for _ in 0..<200 {
            if (await recorder.transport.sentEnvelopes()).count >= count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for transport envelopes")
    }

    private func waitForCommand(
        _ fragment: String,
        recorder: CommandRecorder
    ) async {
        for _ in 0..<200 {
            if recorder.commands.contains(where: { $0.contains(fragment) }) {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for command containing \(fragment)")
    }
}

@MainActor
private final class CommandRecorder {
    private(set) var commands: [String] = []
    let transport = ChatFixtureTransport()
    private let capabilityData: Data
    private let startData: Data
    private var failuresRemaining: Int
    private let failureCommandSubstring: String?
    private let stopDelayNanoseconds: UInt64

    init(
        capabilityData: Data,
        startData: Data,
        failuresRemaining: Int = 0,
        failureCommandSubstring: String? = nil,
        stopDelayNanoseconds: UInt64 = 0
    ) {
        self.capabilityData = capabilityData
        self.startData = startData
        self.failuresRemaining = failuresRemaining
        self.failureCommandSubstring = failureCommandSubstring
        self.stopDelayNanoseconds = stopDelayNanoseconds
    }

    var dependencies: MobileChatSessionDependencies {
        MobileChatSessionDependencies(
            execute: { [weak self] command in
                guard let self else { return Data() }
                commands.append(command)
                if failuresRemaining > 0,
                   failureCommandSubstring.map(command.contains) != false {
                    failuresRemaining -= 1
                    throw SSHTransportError.connection("private-worker.example.com")
                }
                if command.contains("chat-capabilities-v1") {
                    return capabilityData
                }
                if command.contains("chat-start-v1") {
                    return startData
                }
                if command.contains("chat-stop-v1"),
                   stopDelayNanoseconds > 0 {
                    try await Task.sleep(
                        nanoseconds: stopDelayNanoseconds
                    )
                }
                return Data()
            },
            makeTransport: { [transport] _ in transport }
        )
    }
}

@MainActor
private final class BackgroundPreparationRecorder {
    private(set) var capabilityCommandCount = 0
    private(set) var startCommandCount = 0
    private let transport = ChatFixtureTransport()
    private let capabilityData: Data
    private let startData: Data

    init(capabilityData: Data, startData: Data) {
        self.capabilityData = capabilityData
        self.startData = startData
    }

    var dependencies: MobileChatSessionDependencies {
        MobileChatSessionDependencies(
            execute: { [weak self] command in
                guard let self else { return Data() }
                if command.contains("chat-capabilities-v1") {
                    capabilityCommandCount += 1
                    if capabilityCommandCount == 1 {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                    return capabilityData
                }
                if command.contains("chat-start-v1") {
                    startCommandCount += 1
                    return startData
                }
                return Data()
            },
            makeTransport: { [transport] _ in transport }
        )
    }

    func waitForFirstCapabilityAttempt() async {
        for _ in 0..<200 {
            if capabilityCommandCount == 1 { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the first capability attempt")
    }
}
