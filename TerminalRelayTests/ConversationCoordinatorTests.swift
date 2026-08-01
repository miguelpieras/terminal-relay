import XCTest
@testable import TerminalRelay

@MainActor
final class ConversationCoordinatorTests: XCTestCase {
    func testStartAttachesWithCurrentCursorAndDetachLeavesAgentRunning() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 7
            )
        )
        let coordinator = makeCoordinator(store: store, transport: transport)

        coordinator.start()
        await waitUntil {
            await transport.sentEnvelopes().contains { $0.type == "session.attach" }
        }
        let attach = await transport.sentEnvelopes().first { $0.type == "session.attach" }
        XCTAssertEqual(attach?.payload["afterSeq"]?.int64Value, 7)
        XCTAssertEqual(
            attach?.payload["snapshotGeneration"]?.stringValue,
            ChatTestFixtures.generation
        )

        await coordinator.detach()
        let commands = await transport.sentEnvelopes()
        XCTAssertEqual(commands.last?.type, "session.detach")
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testSendClearsComposerImmediatelyAndReconcilesOptimisticMessage() async {
        let transport = ChatFixtureTransport(
            initialEvents: [Self.hello(sequence: 1)]
        ) { command in
            guard command.type == "turn.start", let requestID = command.requestID else { return [] }
            return [
                ChatTestFixtures.event(
                    "message.completed",
                    sequence: 2,
                    itemID: "provider-message",
                    turnID: "turn-1",
                    payload: .object([
                        "role": .string("user"),
                        "text": command.payload["text"] ?? .string(""),
                        "clientUserMessageId": .string(requestID),
                    ])
                ),
            ]
        }
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        coordinator.updateLaunchOptions(
            model: "codex-test-model",
            reasoningEffort: "high",
            fastMode: true
        )

        store.draft = "Build the app\nthen run tests"
        store.attachments = [
            ChatAttachmentReference(
                id: "attachment",
                path: "/workspace/example/screenshot.png",
                displayName: "screenshot.png"
            ),
        ]
        await coordinator.sendDraft()

        XCTAssertEqual(store.draft, "")
        XCTAssertTrue(store.attachments.isEmpty)
        await waitUntil {
            store.state.messages.contains { $0.id == "provider-message" }
        }
        XCTAssertEqual(store.state.messages.map(\.text), ["Build the app\nthen run tests"])
        XCTAssertFalse(store.state.messages.contains { $0.id.hasPrefix("client:") })
        let turnStarts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(turnStarts.count, 1)
        XCTAssertEqual(
            turnStarts.first?.payload["text"]?.stringValue,
            "Build the app\nthen run tests"
        )
        XCTAssertEqual(turnStarts.first?.payload["model"]?.stringValue, "codex-test-model")
        XCTAssertEqual(turnStarts.first?.payload["reasoningEffort"]?.stringValue, "high")
        XCTAssertEqual(turnStarts.first?.payload["fastMode"]?.boolValue, true)
    }

    func testInvalidComposerActionsNeverSendAndRestoreFailedPrompt() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        let baseline = await transport.sentEnvelopes().count

        await coordinator.send(text: "   ")
        let commandsAfterEmptyPrompt = await transport.sentEnvelopes()
        XCTAssertEqual(commandsAfterEmptyPrompt.count, baseline)
        XCTAssertEqual(store.state.lastErrorMessage, ConversationCoordinatorError.emptyPrompt.localizedDescription)

        let oversized = String(repeating: "x", count: 256 * 1_024 + 1)
        await coordinator.send(text: oversized)
        let commandsAfterOversizedPrompt = await transport.sentEnvelopes()
        XCTAssertEqual(commandsAfterOversizedPrompt.count, baseline)
        XCTAssertEqual(store.state.lastErrorMessage, ConversationCoordinatorError.promptTooLarge.localizedDescription)
    }

    func testInferredResumedTurnRejectsNewSendLocallyAndPreservesDraft() async throws {
        let activeTurnID = "10000000-0000-4000-8000-000000000003"
        let snapshot = try ChatTestFixtures.snapshotEvent(
            baseSequence: 1,
            items: [
                .message(
                    ChatMessage(
                        id: "assistant-stream",
                        turnID: activeTurnID,
                        role: .assistant,
                        text: "In progress",
                        isStreaming: true
                    )
                ),
            ],
            turnState: .idle
        )
        let transport = ChatFixtureTransport(initialEvents: [snapshot])
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.activeTurnID == activeTurnID }

        store.draft = "Do this after the current turn"
        await coordinator.sendDraft()

        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertTrue(starts.isEmpty)
        XCTAssertEqual(store.draft, "Do this after the current turn")
        XCTAssertEqual(store.state.turnState, .running)
        XCTAssertEqual(
            store.state.lastErrorMessage,
            ConversationCoordinatorError.turnAlreadyActive.localizedDescription
        )
    }

    func testTurnActiveRaceRestoresRejectedDraftAndReconcilesAuthoritativeStreamingTurn() async throws {
        let activeTurnID = "10000000-0000-4000-8000-000000000004"
        let transport = ChatFixtureTransport(
            initialEvents: [Self.hello(sequence: 1)]
        ) { command in
            guard command.type == "turn.start" else {
                return []
            }
            return [
                ChatTestFixtures.event(
                    "message.started",
                    sequence: 2,
                    itemID: "assistant-stream",
                    turnID: activeTurnID,
                    payload: .object([
                        "role": .string("assistant"),
                        "text": .string("Still working"),
                    ])
                ),
            ]
        }
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "Keep this prompt"
        store.attachments = [
            ChatAttachmentReference(
                id: "failed-attachment",
                path: "/workspace/example/failed.png",
                displayName: "failed.png"
            ),
        ]
        await coordinator.sendDraft()
        let sentAfterStart = await transport.sentEnvelopes()
        let startRequestID = try XCTUnwrap(sentAfterStart
            .last { $0.type == "turn.start" }?
            .requestID)
        store.draft = "Newer draft"
        store.attachments = [
            ChatAttachmentReference(
                id: "new-attachment",
                path: "/workspace/example/new.png",
                displayName: "new.png"
            ),
        ]
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "error",
                    sequence: 3,
                    payload: .object([
                        "requestId": .string(startRequestID),
                        "code": .string("turnActive"),
                        "message": .string("A provider turn is already active."),
                    ])
                )
            )
        )
        await waitUntil { store.state.activeTurnID == activeTurnID }

        XCTAssertEqual(store.draft, "Keep this prompt\n\nNewer draft")
        XCTAssertEqual(
            store.attachments.map(\.id),
            ["failed-attachment", "new-attachment"]
        )
        XCTAssertEqual(store.state.turnState, .running)
        XCTAssertFalse(store.state.messages.contains { $0.isOptimistic })
        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 1)
    }

    func testPendingTurnStartRejectsConcurrentSendAndPreservesNewDraft() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "First prompt"
        await coordinator.sendDraft()
        store.draft = "Second prompt"
        await coordinator.sendDraft()

        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.payload["text"]?.stringValue, "First prompt")
        XCTAssertEqual(store.draft, "Second prompt")
        XCTAssertEqual(
            store.state.lastErrorMessage,
            ConversationCoordinatorError.turnAlreadyActive.localizedDescription
        )

        let firstRequestID = try XCTUnwrap(starts.first?.requestID)
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "ack",
                    sequence: 2,
                    payload: .object([
                        "requestId": .string(firstRequestID),
                    ])
                )
            )
        )
        await waitUntil { store.state.lastAppliedSequence == 2 }
        await coordinator.sendDraft()

        let startsAfterAcknowledgement = await transport.sentEnvelopes()
            .filter { $0.type == "turn.start" }
        XCTAssertEqual(startsAfterAcknowledgement.count, 2)
        XCTAssertEqual(
            startsAfterAcknowledgement.last?.payload["text"]?.stringValue,
            "Second prompt"
        )
        XCTAssertTrue(store.draft.isEmpty)
    }

    func testAuthoritativeTurnStartedReconcilesMissedStartAcknowledgement() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "First prompt"
        await coordinator.sendDraft()
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.started",
                    sequence: 2,
                    turnID: "turn-authoritative",
                    payload: .object(["turnId": .string("turn-authoritative")])
                )
            )
        )
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.completed",
                    sequence: 3,
                    turnID: "turn-authoritative"
                )
            )
        )
        await waitUntil { store.state.turnState == .completed }

        store.draft = "Second prompt"
        await coordinator.sendDraft()

        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.last?.payload["text"]?.stringValue, "Second prompt")
    }

    func testIdleSnapshotAfterNewStartDoesNotUnlatchSecondSend() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "First prompt"
        await coordinator.sendDraft()
        await transport.yield(
            .envelope(
                try ChatTestFixtures.snapshotEvent(
                    baseSequence: 2,
                    turnState: .idle
                )
            )
        )
        await waitUntil { store.state.lastAppliedSequence == 2 }

        store.draft = "Second prompt"
        await coordinator.sendDraft()

        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 1)
        XCTAssertEqual(starts.first?.payload["text"]?.stringValue, "First prompt")
        XCTAssertEqual(store.draft, "Second prompt")
        XCTAssertEqual(
            store.state.lastErrorMessage,
            ConversationCoordinatorError.turnAlreadyActive.localizedDescription
        )
    }

    func testAttachAcknowledgementPreservesLateStartErrorRestoration() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "Failed prompt"
        await coordinator.sendDraft()
        let commands = await transport.sentEnvelopes()
        let startRequestID = try XCTUnwrap(
            commands.last { $0.type == "turn.start" }?.requestID
        )
        let attachRequestID = try XCTUnwrap(
            commands.last { $0.type == "session.attach" }?.requestID
        )
        store.draft = "Newer draft"

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.started",
                    sequence: 2,
                    turnID: "turn-from-another-client",
                    payload: .object(["turnId": .string("turn-from-another-client")])
                )
            )
        )
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "ack",
                    sequence: 3,
                    payload: .object([
                        "requestId": .string(attachRequestID),
                        "commandType": .string("session.attach"),
                    ])
                )
            )
        )
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "error",
                    sequence: 4,
                    payload: .object([
                        "requestId": .string(startRequestID),
                        "code": .string("turnActive"),
                        "message": .string("A provider turn is already active."),
                    ])
                )
            )
        )
        await waitUntil { store.state.lastAppliedSequence == 4 }

        XCTAssertEqual(store.draft, "Failed prompt\n\nNewer draft")
        XCTAssertFalse(store.state.messages.contains { $0.isOptimistic })
    }

    func testCloseAndReopenBeforeStartAcknowledgementDoesNotKeepSendLatched() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "Before close"
        await coordinator.sendDraft()
        await coordinator.detach()
        coordinator.start()
        await waitUntil {
            await transport.sentEnvelopes().filter { $0.type == "session.attach" }.count == 2
        }

        store.draft = "After reopen"
        await coordinator.sendDraft()

        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.map { $0.payload["text"]?.stringValue }, [
            "Before close",
            "After reopen",
        ])
    }

    func testInterruptUsesExactActiveTurnAndRejectsStaleSecondTap() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.started",
                    sequence: 2,
                    turnID: "turn-exact",
                    payload: .object(["turnId": .string("turn-exact")])
                )
            )
        )
        await waitUntil { store.state.activeTurnID == "turn-exact" }

        await coordinator.interrupt()
        let interrupt = await transport.sentEnvelopes().last { $0.type == "turn.interrupt" }
        XCTAssertEqual(interrupt?.turnID, "turn-exact")
        XCTAssertEqual(interrupt?.payload["turnId"]?.stringValue, "turn-exact")

        await coordinator.interrupt()
        let interruptCountBeforeEvent = await transport.sentEnvelopes()
            .filter { $0.type == "turn.interrupt" }
            .count
        XCTAssertEqual(
            interruptCountBeforeEvent,
            1,
            "Repeated stop actions must not send another interrupt while the turn is still active."
        )

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.interrupted",
                    sequence: 3,
                    turnID: "turn-exact"
                )
            )
        )
        await waitUntil { store.state.activeTurnID == nil }
        let count = await transport.sentEnvelopes().filter { $0.type == "turn.interrupt" }.count
        await coordinator.interrupt()
        let interruptCountAfterStaleTap = await transport.sentEnvelopes()
            .filter { $0.type == "turn.interrupt" }
            .count
        XCTAssertEqual(interruptCountAfterStaleTap, count)
    }

    func testRejectedInterruptUnlatchesSameTurnForRetry() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.started",
                    sequence: 2,
                    turnID: "turn-retry",
                    payload: .object(["turnId": .string("turn-retry")])
                )
            )
        )
        await waitUntil { store.state.activeTurnID == "turn-retry" }

        await coordinator.interrupt()
        let firstInterrupt = await transport.sentEnvelopes()
            .last { $0.type == "turn.interrupt" }
        let firstRequestID = try XCTUnwrap(firstInterrupt?.requestID)

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "error",
                    sequence: 3,
                    payload: .object([
                        "requestId": .string(firstRequestID),
                        "code": .string("interruptRejected"),
                        "message": .string("The interrupt was rejected."),
                    ])
                )
            )
        )
        await waitUntil {
            store.state.lastErrorMessage == "The interrupt was rejected."
        }

        await coordinator.interrupt()

        let interrupts = await transport.sentEnvelopes()
            .filter { $0.type == "turn.interrupt" }
        XCTAssertEqual(interrupts.count, 2)
        XCTAssertEqual(interrupts.map(\.turnID), ["turn-retry", "turn-retry"])
        XCTAssertNotEqual(interrupts.first?.requestID, interrupts.last?.requestID)
    }

    func testDestructiveApprovalNeedsConfirmationAndRepeatTapsStayDisabledThroughAck() async {
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)]) { command in
            guard command.type == "approval.respond", let requestID = command.requestID else { return [] }
            return [
                ChatTestFixtures.event(
                    "ack",
                    sequence: 2,
                    payload: .object(["requestId": .string(requestID)])
                ),
            ]
        }
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        var destructiveApproval = ChatTestFixtures.pendingApproval(destructive: true)
        destructiveApproval.decisions.insert(
            ApprovalDecision(
                id: "approve-always",
                label: "Always approve",
                isDestructive: true
            ),
            at: 1
        )
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                approvals: [destructiveApproval],
                turnState: .awaitingApproval,
                activeTurnID: "turn-1"
            )
        )

        await coordinator.respond(to: "approval-1", decisionID: "approve")
        let responsesBeforeConfirmation = await transport.sentEnvelopes()
            .filter { $0.type == "approval.respond" }
        XCTAssertEqual(responsesBeforeConfirmation.count, 0)
        XCTAssertEqual(
            store.pendingDestructiveApprovalConfirmation,
            DestructiveApprovalConfirmation(
                approvalID: "approval-1",
                decisionID: "approve"
            )
        )

        await coordinator.respond(to: "approval-1", decisionID: "approve-always")
        let responsesAfterDifferentDecision = await transport.sentEnvelopes()
            .filter { $0.type == "approval.respond" }
        XCTAssertEqual(responsesAfterDifferentDecision.count, 0)
        XCTAssertEqual(
            store.pendingDestructiveApprovalConfirmation,
            DestructiveApprovalConfirmation(
                approvalID: "approval-1",
                decisionID: "approve-always"
            )
        )

        await coordinator.respond(to: "approval-1", decisionID: "approve-always")
        await waitUntil { store.respondingInteractionIDs.contains("approval-1") }
        let responsesAfterConfirmation = await transport.sentEnvelopes()
            .filter { $0.type == "approval.respond" }
        XCTAssertEqual(responsesAfterConfirmation.count, 1)
        XCTAssertEqual(
            responsesAfterConfirmation.first?.payload["decision"]?.stringValue,
            "approve-always"
        )

        await coordinator.respond(to: "approval-1", decisionID: "approve-always")
        let responsesAfterRepeatedTap = await transport.sentEnvelopes()
            .filter { $0.type == "approval.respond" }
        XCTAssertEqual(responsesAfterRepeatedTap.count, 1)
        XCTAssertTrue(store.respondingInteractionIDs.contains("approval-1"))

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "approval.resolved",
                    sequence: 3,
                    itemID: "approval-1",
                    payload: .object([
                        "displayId": .string("approval-1"),
                        "decision": .string("approve"),
                    ])
                )
            )
        )
        await waitUntil { !store.respondingInteractionIDs.contains("approval-1") }
        XCTAssertEqual(store.state.approvals.first?.status, .approved)
    }

    func testNonDestructiveDenialSendsImmediatelyWithPermissionChanges() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                approvals: [ChatTestFixtures.pendingApproval()],
                turnState: .awaitingApproval,
                activeTurnID: "turn-1"
            )
        )
        let permissionChanges: JSONValue = .object([
            "write": .bool(false),
        ])

        await coordinator.respond(
            to: "approval-1",
            decisionID: "deny",
            permissionChanges: permissionChanges
        )

        let responses = await transport.sentEnvelopes()
            .filter { $0.type == "approval.respond" }
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.payload["decision"]?.stringValue, "deny")
        XCTAssertEqual(responses.first?.payload["permissionChanges"], permissionChanges)
        XCTAssertNil(store.pendingDestructiveApprovalConfirmation)
    }

    func testQuestionAnswerRepeatTapAndSecretAnswerAreEphemeral() async {
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)]) { command in
            guard command.type == "question.respond", let requestID = command.requestID else { return [] }
            return [
                ChatTestFixtures.event(
                    "ack",
                    sequence: 2,
                    payload: .object(["requestId": .string(requestID)])
                ),
            ]
        }
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                questions: [ChatTestFixtures.pendingQuestion(id: "secret", kind: .secret)],
                turnState: .awaitingApproval,
                activeTurnID: "turn-1"
            )
        )

        await coordinator.answer(questionID: "secret", answers: [], secretText: "temporary-secret")
        await waitUntil { store.respondingInteractionIDs.contains("secret") }
        let responses = await transport.sentEnvelopes().filter { $0.type == "question.respond" }
        XCTAssertEqual(responses.count, 1)
        XCTAssertFalse(store.questionText.values.contains("temporary-secret"))
        XCTAssertEqual(
            responses.first?.payload["answers"]?.arrayValue?.first?["text"]?.stringValue,
            "temporary-secret"
        )

        await coordinator.answer(questionID: "secret", answers: [], secretText: "second")
        let responsesAfterRepeatedTap = await transport.sentEnvelopes()
            .filter { $0.type == "question.respond" }
        XCTAssertEqual(responsesAfterRepeatedTap.count, 1)
    }

    func testMultiQuestionResponseSendsAllAnswerRowsAtomically() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let request = QuestionRequest(
            id: "question-group",
            turnID: "turn-1",
            providerConnectionGeneration: "provider-generation-1",
            providerRequestID: .number(77),
            prompt: "Answer every row",
            kind: .freeText,
            status: .pending,
            fields: [
                QuestionField(
                    id: "choice",
                    prompt: "Choose",
                    kind: .singleChoice,
                    options: [QuestionOption(id: "a", label: "A")]
                ),
                QuestionField(id: "text", prompt: "Explain", kind: .freeText),
                QuestionField(id: "secret", prompt: "Token", kind: .secret),
            ]
        )
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                questions: [request],
                turnState: .awaitingApproval,
                activeTurnID: "turn-1"
            )
        )
        let answers = [
            ChatQuestionAnswer(questionID: "choice", selectedOptionIDs: ["a"]),
            ChatQuestionAnswer(questionID: "text", text: "A complete answer"),
            ChatQuestionAnswer(questionID: "secret", text: "ephemeral-secret"),
        ]

        await coordinator.answer(questionID: request.id, answers: answers)

        let responses = await transport.sentEnvelopes()
            .filter { $0.type == "question.respond" }
        XCTAssertEqual(responses.count, 1)
        let encodedAnswers = responses.first?.payload["answers"]?.arrayValue
        XCTAssertEqual(encodedAnswers?.count, 3)
        XCTAssertEqual(encodedAnswers?[0]["questionID"]?.stringValue, "choice")
        XCTAssertEqual(encodedAnswers?[1]["text"]?.stringValue, "A complete answer")
        XCTAssertEqual(encodedAnswers?[2]["text"]?.stringValue, "ephemeral-secret")
        XCTAssertFalse(store.questionText.values.contains("ephemeral-secret"))
    }

    func testDetachResetsInteractionAndHistoryLatches() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        let approval = ChatTestFixtures.pendingApproval()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                approvals: [approval],
                connectionState: .streaming,
                hasOlderHistory: true,
                oldestItemID: "oldest"
            )
        )

        await coordinator.respond(to: approval.id, decisionID: "deny")
        await coordinator.loadOlderHistory()
        let commandsBeforeDetach = await transport.sentEnvelopes()
        let firstResponseID = try XCTUnwrap(
            commandsBeforeDetach
                .last { $0.type == "approval.respond" }?
                .requestID
        )
        XCTAssertTrue(store.respondingInteractionIDs.contains(approval.id))
        XCTAssertTrue(store.isLoadingOlderHistory)

        await coordinator.detach()
        XCTAssertTrue(store.respondingInteractionIDs.isEmpty)
        XCTAssertFalse(store.isLoadingOlderHistory)

        coordinator.start()
        await waitUntil {
            await transport.sentEnvelopes().filter { $0.type == "session.attach" }.count == 2
        }
        await coordinator.respond(to: approval.id, decisionID: "deny")
        await coordinator.loadOlderHistory()
        let commandsBeforeSnapshot = await transport.sentEnvelopes()
        let secondResponseID = try XCTUnwrap(
            commandsBeforeSnapshot
                .last { $0.type == "approval.respond" }?
                .requestID
        )
        XCTAssertTrue(store.respondingInteractionIDs.contains(approval.id))
        XCTAssertTrue(store.isLoadingOlderHistory)

        let commands = await transport.sentEnvelopes()
        XCTAssertEqual(commands.filter { $0.type == "approval.respond" }.count, 2)
        XCTAssertEqual(commands.filter { $0.type == "history.load" }.count, 2)
        XCTAssertNotEqual(firstResponseID, secondResponseID)
    }

    func testFreshSnapshotResetsReconnectLatchesAndIgnoresStaleResponseErrors() async throws {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        let approval = ChatTestFixtures.pendingApproval()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                approvals: [approval],
                connectionState: .streaming,
                hasOlderHistory: true,
                oldestItemID: "oldest"
            )
        )

        await coordinator.respond(to: approval.id, decisionID: "deny")
        await coordinator.loadOlderHistory()
        let commandsBeforeSnapshot = await transport.sentEnvelopes()
        let staleResponseID = try XCTUnwrap(
            commandsBeforeSnapshot
                .last { $0.type == "approval.respond" }?
                .requestID
        )
        XCTAssertTrue(store.respondingInteractionIDs.contains(approval.id))
        XCTAssertTrue(store.isLoadingOlderHistory)

        await transport.yield(
            .envelope(
                try ChatTestFixtures.snapshotEvent(
                    baseSequence: 2,
                    approvals: [approval],
                    hasOlderHistory: true
                )
            )
        )
        await waitUntil { store.state.lastAppliedSequence == 2 }
        XCTAssertTrue(store.respondingInteractionIDs.isEmpty)
        XCTAssertFalse(store.isLoadingOlderHistory)

        await coordinator.respond(to: approval.id, decisionID: "deny")
        await coordinator.loadOlderHistory()
        XCTAssertTrue(store.respondingInteractionIDs.contains(approval.id))
        XCTAssertTrue(store.isLoadingOlderHistory)

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "error",
                    sequence: 3,
                    payload: .object([
                        "requestId": .string(staleResponseID),
                        "code": .string("staleResponse"),
                        "message": .string("The pre-snapshot response was not accepted."),
                    ])
                )
            )
        )
        await waitUntil { store.state.lastAppliedSequence == 3 }
        XCTAssertTrue(
            store.respondingInteractionIDs.contains(approval.id),
            "An error for the pre-snapshot command must not unlock the new response."
        )
        let commands = await transport.sentEnvelopes()
        XCTAssertEqual(commands.filter { $0.type == "approval.respond" }.count, 2)
        XCTAssertEqual(commands.filter { $0.type == "history.load" }.count, 2)
    }

    func testExplicitRetryReconnectsWithTheLastAppliedCursor() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        store.draft = "Before disconnect"
        await coordinator.sendDraft()
        store.setInteractionResponding("stale-interaction", isResponding: true)
        store.beginLoadingOlderHistory()
        await transport.yield(
            .disconnected(
                ChatTransportFailure(
                    category: "network",
                    message: "Connection was interrupted.",
                    isRecoverable: true
                )
            )
        )
        await waitUntil { store.state.connectionState == .offlineAgentRunning }
        XCTAssertTrue(store.respondingInteractionIDs.isEmpty)
        XCTAssertFalse(store.isLoadingOlderHistory)

        coordinator.retry()
        XCTAssertEqual(store.state.connectionState, .connecting)
        XCTAssertNil(store.state.lastErrorMessage)
        await waitUntil {
            await transport.sentEnvelopes().filter { $0.type == "session.attach" }.count == 2
        }
        let attachCommands = await transport.sentEnvelopes()
            .filter { $0.type == "session.attach" }
        XCTAssertEqual(attachCommands.last?.payload["afterSeq"]?.int64Value, 1)
        XCTAssertEqual(
            attachCommands.last?.payload["snapshotGeneration"]?.stringValue,
            ChatTestFixtures.generation
        )

        store.draft = "After reconnect"
        await coordinator.sendDraft()
        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts.last?.payload["text"]?.stringValue, "After reconnect")
        await coordinator.detach()
    }

    func testRecoverableDisconnectStaysQuietWhileAutomaticRetryIsPending() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: ChatRetryPolicy(
                maximumAutomaticRetries: 1,
                initialDelayNanoseconds: 500_000_000,
                maximumDelayNanoseconds: 500_000_000
            )
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        await transport.yield(
            .disconnected(
                ChatTransportFailure(
                    category: "network",
                    message: "Connection was interrupted.",
                    isRecoverable: true
                )
            )
        )

        await waitUntil { store.state.connectionState == .connecting }
        XCTAssertNil(store.state.lastErrorMessage)
        await coordinator.detach()
    }

    func testHistoryPreviewAndRetryActionsSendTheirExactCommands() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [
                    .message(ChatMessage(id: "oldest", role: .assistant, text: "Oldest")),
                ],
                hasOlderHistory: true,
                oldestItemID: "oldest"
            )
        )

        await coordinator.loadOlderHistory()
        await coordinator.previewFile(
            ChatRepositoryLink(path: "Sources/App.swift", line: 12, column: 3)
        )
        let commands = await transport.sentEnvelopes()
        XCTAssertEqual(commands.last(where: { $0.type == "history.load" })?.payload["beforeItemId"]?.stringValue, "oldest")
        XCTAssertEqual(commands.last(where: { $0.type == "file.preview" })?.payload["path"]?.stringValue, "Sources/App.swift")
        XCTAssertEqual(commands.last(where: { $0.type == "file.preview" })?.payload["line"]?.intValue, 12)
        XCTAssertEqual(commands.last(where: { $0.type == "file.preview" })?.payload["column"]?.intValue, 3)
    }

    func testStopWaitsForAckAndRepeatedStopDoesNotSendAgain() async {
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)]) { command in
            guard command.type == "session.stop", let requestID = command.requestID else { return [] }
            return [
                ChatTestFixtures.event(
                    "ack",
                    sequence: 2,
                    payload: .object(["requestId": .string(requestID)])
                ),
            ]
        }
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        await coordinator.stop()
        XCTAssertEqual(store.state.connectionState, .stopped)
        let stopsAfterConfirmation = await transport.sentEnvelopes()
            .filter { $0.type == "session.stop" }
        XCTAssertEqual(stopsAfterConfirmation.count, 1)
        await coordinator.stop()
        let stopsAfterRepeatedAction = await transport.sentEnvelopes()
            .filter { $0.type == "session.stop" }
        XCTAssertEqual(stopsAfterRepeatedAction.count, 1)
    }

    func testUnconfirmedStopRetryReusesSameIdempotencyKey() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        await coordinator.stop()
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
        await coordinator.stop()
        let stops = await transport.sentEnvelopes().filter { $0.type == "session.stop" }
        XCTAssertEqual(stops.count, 2)
        XCTAssertEqual(stops.first?.requestID, stops.last?.requestID)
    }

    private func makeConnectedTransport() -> ChatFixtureTransport {
        ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
    }

    private func makeCoordinator(
        store: ConversationStore,
        transport: ChatFixtureTransport
    ) -> ConversationCoordinator {
        ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate,
            stopPolicy: ChatStopPolicy(
                confirmationPollCount: 50,
                pollDelayNanoseconds: 1_000_000
            )
        )
    }

    private static func hello(sequence: Int64) -> ChatEnvelope {
        ChatTestFixtures.event(
            "session.hello",
            sequence: sequence,
            payload: (try? JSONValue.encoded(ChatCapabilities(features: ["streaming"])))
                ?? .object([:])
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                XCTFail("Timed out waiting for asynchronous chat state")
                return
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
