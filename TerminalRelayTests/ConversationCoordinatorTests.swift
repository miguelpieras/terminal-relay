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

    func testAttachmentOnlySendUsesCallerRequestIdentityAndFileMetadata() async {
        let capabilities = ChatCapabilities(
            features: ["file-attachments-v1", "streaming"]
        )
        let transport = ChatFixtureTransport(
            initialEvents: [
                ChatTestFixtures.event(
                    "session.hello",
                    sequence: 1,
                    payload: (try? JSONValue.encoded(capabilities)) ?? .object([:])
                )
            ]
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        let requestID = "12345678-1234-4234-8234-123456789abc"
        let attachment = ChatAttachmentReference(
            id: "abcdefab-cdef-4abc-8def-abcdefabcdef",
            path: "/worker/private/attachment.pdf",
            displayName: "Attachment.pdf",
            mediaType: "application/pdf",
            kind: .file,
            byteCount: 4_096
        )

        let wasSent = await coordinator.send(
            text: "",
            attachments: [attachment],
            requestID: requestID
        )

        XCTAssertTrue(wasSent)
        let start = await transport.sentEnvelopes().last { $0.type == "turn.start" }
        XCTAssertEqual(start?.requestID, requestID)
        XCTAssertEqual(start?.payload["text"]?.stringValue, "")
        let encodedAttachment = start?.payload["attachments"]?.arrayValue?.first
        XCTAssertEqual(encodedAttachment?["kind"]?.stringValue, "file")
        XCTAssertEqual(encodedAttachment?["byteCount"]?.int64Value, 4_096)
    }

    func testCodexFileAttachmentsDoNotDependOnTransientCapabilitiesAndRespectByteLimits() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        let file = ChatAttachmentReference(
            id: "abcdefab-cdef-4abc-8def-abcdefabcdef",
            path: "/worker/private/attachment.txt",
            displayName: "Attachment.txt",
            mediaType: "text/plain",
            kind: .file,
            byteCount: 10
        )

        let fileWasSent = await coordinator.send(
            text: "Inspect",
            attachments: [file]
        )
        XCTAssertTrue(fileWasSent)

        let oversizedImage = ChatAttachmentReference(
            id: "fedcbafe-dcba-4fed-8cba-fedcbafedcba",
            path: "/worker/private/image.png",
            displayName: "image.png",
            mediaType: "image/png",
            kind: .image,
            byteCount: ChatAttachmentPolicy.maximumFileBytes + 1
        )
        let oversizedWasSent = await coordinator.send(
            text: "Inspect",
            attachments: [oversizedImage]
        )
        XCTAssertFalse(oversizedWasSent)
        XCTAssertEqual(
            store.state.lastErrorMessage,
            ConversationCoordinatorError.attachmentsTooLarge.localizedDescription
        )
        let starts = await transport.sentEnvelopes().filter { $0.type == "turn.start" }
        XCTAssertEqual(starts.count, 1)
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

    func testConnectingWatchdogFailsAnAttachThatNeverProgresses() async {
        // The broker heartbeats "connecting" while a provider resume is in
        // flight, so a hung resume keeps the transport alive with no
        // disconnect for the retry loop to react to. Because events ARE
        // arriving, this is the wedged-broker case: the watchdog must wait
        // out the full connecting grace, then fail honestly.
        let transport = ChatFixtureTransport(
            initialEvents: [Self.hello(sequence: 1, connectionState: "connecting")]
        )
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: ChatRetryPolicy(
                maximumAutomaticRetries: 0,
                initialDelayNanoseconds: 0,
                maximumDelayNanoseconds: 0,
                attachResponseGraceNanoseconds: 10_000_000,
                connectingGraceNanoseconds: 200_000_000
            )
        )
        coordinator.start()
        // Probe strictly between the two graces: with envelopes arriving,
        // the banner must wait for the FULL connecting grace — firing at the
        // short response grace would reintroduce the terminal-failure-on-
        // slow-resume bug this watchdog split exists to prevent.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(store.state.connectionState, .connecting)
        XCTAssertNil(store.state.lastErrorMessage)
        await waitUntil { store.state.connectionState == .failed }
        XCTAssertNotNil(store.state.lastErrorMessage)
        await coordinator.detach()
    }

    func testAttachThatDeliversNothingReconnectsSilently() async {
        // A transport reports "connected" once its process spawns and the
        // attach write reaches a local pipe — neither proves the worker got
        // anything. When no envelope at all comes back, the watchdog must
        // tear the transport down and reconnect through the retry loop
        // instead of surfacing a failure: a fresh connection almost always
        // succeeds immediately.
        let attachAttempts = AttachAttemptCounter()
        let hello = Self.hello(sequence: 1)
        let transport = ChatFixtureTransport { command in
            guard command.type == "session.attach" else { return [] }
            return attachAttempts.next() >= 2 ? [hello] : []
        }
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: ChatRetryPolicy(
                maximumAutomaticRetries: 2,
                initialDelayNanoseconds: 1_000_000,
                maximumDelayNanoseconds: 1_000_000,
                attachResponseGraceNanoseconds: 20_000_000,
                connectingGraceNanoseconds: 10_000_000_000
            )
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        XCTAssertNil(store.state.lastErrorMessage)
        await coordinator.detach()
    }

    func testAttachesThatDeliverNothingExhaustTheRetryBudget() async {
        // Undelivered attaches must consume the retry budget — the send
        // "succeeding" into a local pipe must not refresh it — so a truly
        // unreachable worker still ends in an honest retryable failure
        // instead of reconnecting forever.
        let transport = ChatFixtureTransport()
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: ChatRetryPolicy(
                maximumAutomaticRetries: 1,
                initialDelayNanoseconds: 1_000_000,
                maximumDelayNanoseconds: 1_000_000,
                attachResponseGraceNanoseconds: 20_000_000,
                connectingGraceNanoseconds: 10_000_000_000
            )
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .offlineAgentRunning }
        XCTAssertNotNil(store.state.lastErrorMessage)
        await coordinator.detach()
    }

    func testConnectingWatchdogStaysQuietOnceTheConversationProgresses() async {
        let transport = makeConnectedTransport()
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: ChatRetryPolicy(
                maximumAutomaticRetries: 0,
                initialDelayNanoseconds: 0,
                maximumDelayNanoseconds: 0,
                connectingGraceNanoseconds: 50_000_000
            )
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(store.state.connectionState, .streaming)
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

    func testDetachDisconnectsBeforeAwaitingASuspendedConnect() async {
        let transport = LifecycleRegressionTransport(
            initialEnvelope: nil,
            suspendsConnectUntilDisconnect: true
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { await transport.isConnectSuspended(call: 1) }

        let detachTask = Task { @MainActor in
            await coordinator.detach()
        }
        let disconnectedWithoutReleasingConnect = await conditionBecomesTrue {
            await transport.disconnectCallCount() == 1
        }
        if !disconnectedWithoutReleasingConnect {
            await transport.releasePendingConnectForCleanup()
        }
        await detachTask.value

        XCTAssertTrue(
            disconnectedWithoutReleasingConnect,
            "Detach must disconnect the transport before awaiting a connect call that only disconnect can resume."
        )
        let disconnectCalls = await transport.disconnectCallCount()
        XCTAssertEqual(disconnectCalls, 1)
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testAttachedDetachUsesAtomicBestEffortCloseInsteadOfAwaitingSend() async {
        let transport = LifecycleRegressionTransport(
            initialEnvelope: Self.hello(sequence: 1),
            suspendsConnectUntilDisconnect: false,
            suspendsDetachSendUntilDisconnect: true
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        let detachTask = Task { @MainActor in
            await coordinator.detach()
        }
        let disconnected = await conditionBecomesTrue {
            await transport.disconnectCallCount() == 1
        }
        if !disconnected {
            await transport.releasePendingDetachSendForCleanup()
        }
        await detachTask.value

        XCTAssertTrue(
            disconnected,
            "Detach must enqueue its final record and close without awaiting an ordinary transport send."
        )
        let ordinaryDetachSends = await transport.ordinaryDetachSendCallCount()
        let bestEffortDetaches = await transport.bestEffortDetachCallCount()
        XCTAssertEqual(ordinaryDetachSends, 0)
        XCTAssertEqual(bestEffortDetaches, 1)
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testExplicitRetryDisconnectsBeforeAwaitingASuspendedConnect() async {
        let transport = LifecycleRegressionTransport(
            initialEnvelope: nil,
            suspendsConnectUntilDisconnect: true
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { await transport.isConnectSuspended(call: 1) }

        coordinator.retry()
        let disconnectedWithoutReleasingConnect = await conditionBecomesTrue {
            await transport.disconnectCallCount() == 1
        }
        if !disconnectedWithoutReleasingConnect {
            await transport.releasePendingConnectForCleanup()
        }
        let reconnected = await conditionBecomesTrue {
            await transport.isConnectSuspended(call: 2)
        }

        XCTAssertTrue(
            disconnectedWithoutReleasingConnect,
            "Retry must disconnect the transport before awaiting a connect call that only disconnect can resume."
        )
        XCTAssertTrue(reconnected, "Retry must start a fresh connection after the old lifecycle exits.")

        await coordinator.detach()
        let disconnectCalls = await transport.disconnectCallCount()
        XCTAssertEqual(disconnectCalls, 2)
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testDetachDuringUnconfirmedStopIsReplayedAndDisconnectsExactlyOnce() async {
        let transport = LifecycleRegressionTransport(
            initialEnvelope: Self.hello(sequence: 1),
            suspendsConnectUntilDisconnect: false
        )
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate,
            stopPolicy: ChatStopPolicy(
                confirmationPollCount: 1,
                pollDelayNanoseconds: 200_000_000
            )
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        let stopTask = Task { @MainActor in
            await coordinator.stop()
        }
        await waitUntil { await transport.sentCommandCount(type: "session.stop") == 1 }
        await coordinator.detach()
        await stopTask.value
        await waitUntil { await transport.disconnectCallCount() == 1 }
        try? await Task.sleep(nanoseconds: 20_000_000)

        let disconnectCalls = await transport.disconnectCallCount()
        let detachCommands = await transport.sentCommandCount(type: "session.detach")
        XCTAssertEqual(disconnectCalls, 1)
        XCTAssertEqual(detachCommands, 1)
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testDetachDefersAConcurrentStartUntilTheOldTransportIsDisconnected() async {
        let transport = LifecycleGateTransport(
            initialEnvelope: Self.hello(sequence: 1),
            heldDisconnectCalls: [1]
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        let detachTask = Task { @MainActor in
            await coordinator.detach()
        }
        await waitUntil { await transport.disconnectCallCount() == 1 }

        coordinator.start()
        await Task.yield()
        let connectCallsWhileDetaching = await transport.connectCallCount()
        XCTAssertEqual(
            connectCallsWhileDetaching,
            1,
            "A new connection must not start while the prior disconnect is suspended."
        )

        await transport.releaseDisconnect(call: 1)
        await detachTask.value
        await waitUntil { await transport.connectCallCount() == 2 }
        await coordinator.detach()
    }

    func testStopIgnoresAConcurrentStartUntilItsDisconnectCompletes() async {
        let transport = LifecycleGateTransport(
            initialEnvelope: Self.hello(sequence: 1),
            heldDisconnectCalls: [1],
            acknowledgesStop: true
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        let stopTask = Task { @MainActor in
            await coordinator.stop()
        }
        await waitUntil { await transport.disconnectCallCount() == 1 }

        coordinator.start()
        await Task.yield()
        let connectCallsWhileStopping = await transport.connectCallCount()
        XCTAssertEqual(
            connectCallsWhileStopping,
            1,
            "A stopped session must not reconnect through a start racing its disconnect."
        )

        await transport.releaseDisconnect(call: 1)
        await stopTask.value
        XCTAssertEqual(store.state.connectionState, .stopped)
        let connectCallsAfterStop = await transport.connectCallCount()
        XCTAssertEqual(connectCallsAfterStop, 1)
    }

    func testStaleConnectFailureCannotPublishConnectingAfterDetachInvalidatesIt() async {
        let transport = LifecycleGateTransport(
            initialEnvelope: nil,
            heldDisconnectCalls: [1, 2],
            connectShouldFail: true
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { await transport.disconnectCallCount() == 1 }

        store.setInteractionResponding("detach-started", isResponding: true)
        let detachTask = Task { @MainActor in
            await coordinator.detach()
        }
        await waitUntil { !store.respondingInteractionIDs.contains("detach-started") }
        store.setConnectionState(.failed, message: "Detached lifecycle marker")

        await transport.releaseDisconnect(call: 1)
        await waitUntil { await transport.disconnectCallCount() == 2 }
        XCTAssertEqual(
            store.state.connectionState,
            .failed,
            "The invalidated connection loop must not publish after its awaited disconnect."
        )

        await transport.releaseDisconnect(call: 2)
        await detachTask.value
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testSequenceGapDisconnectFinishesBeforeExplicitRetryReconnects() async {
        let transport = LifecycleGateTransport(
            initialEnvelope: Self.hello(sequence: 1),
            heldDisconnectCalls: [1]
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "turn.started",
                    sequence: 3,
                    turnID: "gap-turn",
                    payload: .object(["turnId": .string("gap-turn")])
                )
            )
        )
        await waitUntil { await transport.disconnectCallCount() == 1 }

        coordinator.retry()
        await Task.yield()
        let connectCallsWhileResolvingGap = await transport.connectCallCount()
        XCTAssertEqual(
            connectCallsWhileResolvingGap,
            1,
            "Retry must wait for the sequence-gap lifecycle to finish disconnecting."
        )

        await transport.releaseDisconnect(call: 1)
        await waitUntil { await transport.connectCallCount() == 2 }
        await coordinator.detach()
    }

    func testDetachDuringConfirmedStopDoesNotReplayFromFrozenPublishedState() async {
        let transport = LifecycleGateTransport(
            initialEnvelope: Self.hello(sequence: 1),
            heldDisconnectCalls: [1],
            acknowledgesStop: true
        )
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.setTranscriptLiveScrolling(true)

        let stopTask = Task { @MainActor in
            await coordinator.stop()
        }
        await waitUntil { await transport.disconnectCallCount() == 1 }
        await coordinator.detach()
        await transport.releaseDisconnect(call: 1)
        await stopTask.value
        try? await Task.sleep(nanoseconds: 20_000_000)

        let disconnectCalls = await transport.disconnectCallCount()
        let detachCommands = await transport.sentCommandCount(type: "session.detach")
        XCTAssertEqual(
            disconnectCalls,
            1,
            "A confirmed stop is complete even when publication is frozen by live scrolling."
        )
        XCTAssertEqual(detachCommands, 0)
        XCTAssertEqual(
            store.state.connectionState,
            .streaming,
            "The published state remains frozen until the live scroll gesture ends."
        )
        store.setTranscriptLiveScrolling(false)
        XCTAssertEqual(store.state.connectionState, .stopped)
    }

    func testPreviewHydrationCannotPublishAfterDetachInvalidatesIt() async throws {
        let cachedStore = ConversationStore()
        try cachedStore.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 1,
                itemID: "cached-message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(String(repeating: "cached line\n", count: 2_000)),
                ])
            )
        )
        let cache = ControlledConversationStateCache()
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate,
            stopPolicy: .immediate,
            cache: cache
        )

        coordinator.hydrateForPreview()
        await cache.waitUntilLoadStarts()
        await coordinator.detach()
        await cache.releaseLoad(returning: cachedStore.state)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(store.state.items.isEmpty)
        XCTAssertEqual(store.lastAppliedSequence, 0)
        XCTAssertEqual(store.state.connectionState, .offlineAgentRunning)
    }

    func testCacheSaveUsesWorkingStateWhileLiveScrollFreezesPublication() async throws {
        let cache = ControlledConversationStateCache(
            loadResult: nil,
            suspendsLoad: false
        )
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate,
            stopPolicy: .immediate,
            cache: cache
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.setTranscriptLiveScrolling(true)
        let text = "latest reduced content"
        let snapshot = try ChatTestFixtures.snapshotEvent(
            baseSequence: 2,
            items: [
                .message(
                    ChatMessage(
                        id: "cached-latest",
                        turnID: "turn",
                        role: .assistant,
                        text: text
                    )
                ),
            ]
        )

        await transport.yield(.envelope(snapshot))
        await waitUntil { await cache.savedStates().count == 1 }

        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertTrue(store.state.items.isEmpty)
        let savedStates = await cache.savedStates()
        let saved = try XCTUnwrap(savedStates.last)
        XCTAssertEqual(saved.lastAppliedSequence, 2)
        XCTAssertEqual(saved.messages.first?.text, text)

        store.setTranscriptLiveScrolling(false)
        XCTAssertEqual(store.state.lastAppliedSequence, 2)
        await coordinator.detach()
    }

    func testConnectingPlaceholderSuppressesScheduledAndDetachCacheWrites() async throws {
        let cache = ControlledConversationStateCache(
            loadResult: nil,
            suspendsLoad: false
        )
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate,
            stopPolicy: .immediate,
            cache: cache
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        let painted = ConversationItem.message(
            ChatMessage(id: "painted", role: .assistant, text: "painted history")
        )
        await transport.yield(.envelope(
            try Self.snapshotEnvelope(
                generation: ChatTestFixtures.generation,
                baseSequence: 2,
                items: [painted],
                connectionState: .streaming
            )
        ))
        await waitUntil { await cache.savedStates().count == 1 }

        let rebuiltGeneration = "00000000-0000-4000-8000-00000000000e"
        await transport.yield(.envelope(
            try Self.snapshotEnvelope(
                generation: rebuiltGeneration,
                baseSequence: 1,
                items: [],
                connectionState: .connecting
            )
        ))
        await waitUntil {
            store.state.snapshotGeneration == rebuiltGeneration
                && store.state.connectionState == .connecting
        }
        await transport.yield(.envelope(
            ChatTestFixtures.event(
                "session.heartbeat",
                sequence: 2,
                snapshotGeneration: rebuiltGeneration
            )
        ))
        try? await Task.sleep(nanoseconds: 30_000_000)
        let savesAfterHeartbeat = await cache.savedStates().count
        XCTAssertEqual(savesAfterHeartbeat, 1)

        await coordinator.detach()
        let savesAfterDetach = await cache.savedStates().count
        XCTAssertEqual(
            savesAfterDetach,
            1,
            "Detach must not persist old painted rows under a placeholder generation/cursor."
        )
    }

    func testAuthoritativeSnapshotResumesCacheWritesAfterPlaceholder() async throws {
        let cache = ControlledConversationStateCache(
            loadResult: nil,
            suspendsLoad: false
        )
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate,
            stopPolicy: .immediate,
            cache: cache
        )
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        await transport.yield(.envelope(
            try Self.snapshotEnvelope(
                generation: ChatTestFixtures.generation,
                baseSequence: 2,
                items: [
                    .message(ChatMessage(
                        id: "painted",
                        role: .assistant,
                        text: "painted history"
                    )),
                ],
                connectionState: .streaming
            )
        ))
        await waitUntil { await cache.savedStates().count == 1 }

        let rebuiltGeneration = "00000000-0000-4000-8000-00000000000f"
        await transport.yield(.envelope(
            try Self.snapshotEnvelope(
                generation: rebuiltGeneration,
                baseSequence: 1,
                items: [],
                connectionState: .connecting
            )
        ))
        let rebuilt = ConversationItem.message(
            ChatMessage(id: "rebuilt", role: .assistant, text: "rebuilt history")
        )
        await transport.yield(.envelope(
            try Self.snapshotEnvelope(
                generation: rebuiltGeneration,
                baseSequence: 2,
                items: [rebuilt],
                connectionState: .streaming
            )
        ))
        await waitUntil { await cache.savedStates().count == 2 }

        let savedStates = await cache.savedStates()
        let saved = try XCTUnwrap(savedStates.last)
        XCTAssertEqual(saved.snapshotGeneration, rebuiltGeneration)
        XCTAssertEqual(saved.lastAppliedSequence, 2)
        XCTAssertEqual(saved.items, [rebuilt])
        await coordinator.detach()
    }

    func testFirstMessageAndReasoningDeltasArePreparedBeforePublication() async throws {
        try await assertFirstDeltaIsPreparedOffMain(
            type: "message.delta",
            itemID: "message-from-delta",
            payload: .object([
                "role": .string("assistant"),
                "text": .string(String(repeating: "delta message line\n", count: 4_000)),
            ]),
            expectedTextPrefix: "delta message line"
        )
        try await assertFirstDeltaIsPreparedOffMain(
            type: "reasoning.delta",
            itemID: "reasoning-from-delta",
            payload: .object([
                "text": .string(String(repeating: "delta reasoning line\n", count: 4_000)),
            ]),
            expectedTextPrefix: "delta reasoning line"
        )
    }

    func testStartedMessageStreamsThroughStagedRowsDuringLiveScroll() async throws {
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        store.setTranscriptLiveScrolling(true)
        let prefix = String(repeating: "prepared prefix line\n", count: 4_000)
        let firstDelta = String(repeating: "first delta line\n", count: 500)
        let secondDelta = String(repeating: "second delta line\n", count: 500)

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "message.started",
                    sequence: 2,
                    itemID: "live-scroll-stream",
                    turnID: "turn",
                    payload: .object([
                        "role": .string("assistant"),
                        "text": .string(prefix),
                    ])
                )
            )
        )
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: 3,
                    itemID: "live-scroll-stream",
                    turnID: "turn",
                    payload: .object(["text": .string(firstDelta)])
                )
            )
        )
        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: 4,
                    itemID: "live-scroll-stream",
                    turnID: "turn",
                    payload: .object(["text": .string(secondDelta)])
                )
            )
        )
        await waitUntil { store.lastAppliedSequence == 4 }

        XCTAssertTrue(store.state.items.isEmpty)
        store.setTranscriptLiveScrolling(false)
        let item = try XCTUnwrap(store.state.items.first)
        let rows = store.transcriptProjections(for: item)

        XCTAssertEqual(
            rows.map(\.sourceText).joined(),
            prefix + firstDelta + secondDelta
        )
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            0,
            "Prepared unpublished rows must advance through every streamed tail before catch-up publication."
        )
        await coordinator.detach()
    }

    func testMaximumOptimisticPromptIsProjectedBeforePublication() async throws {
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
        let store = ConversationStore()
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }
        let text = String(repeating: "x", count: 256 * 1_024)

        await coordinator.send(text: text)

        let item = try XCTUnwrap(
            store.state.items.first { $0.id.hasPrefix("client:") }
        )
        let rows = store.transcriptProjections(for: item)
        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(rows.map(\.sourceText).joined(), text)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)
        let sent = await transport.sentEnvelopes()
        XCTAssertEqual(sent.filter { $0.type == "turn.start" }.count, 1)
        await coordinator.detach()
    }

    private func assertFirstDeltaIsPreparedOffMain(
        type: String,
        itemID: String,
        payload: JSONValue,
        expectedTextPrefix: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let transport = ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        let coordinator = makeCoordinator(store: store, transport: transport)
        coordinator.start()
        await waitUntil { store.state.connectionState == .streaming }

        await transport.yield(
            .envelope(
                ChatTestFixtures.event(
                    type,
                    sequence: 2,
                    itemID: itemID,
                    turnID: "turn",
                    payload: payload
                )
            )
        )
        await waitUntil {
            store.flushStreamingUpdates()
            return store.state.items.contains { $0.id == itemID }
        }
        let item = try XCTUnwrap(
            store.state.items.first { $0.id == itemID },
            file: file,
            line: line
        )
        let rows = store.transcriptProjections(for: item)

        XCTAssertTrue(
            rows.map(\.sourceText).joined().hasPrefix(expectedTextPrefix),
            file: file,
            line: line
        )
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            0,
            "The coordinator must prepare first-delta projection rebuilds off-main before publishing.",
            file: file,
            line: line
        )
    }

    private final class AttachAttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            count += 1
            return count
        }
    }

    private func makeConnectedTransport() -> ChatFixtureTransport {
        ChatFixtureTransport(initialEvents: [Self.hello(sequence: 1)])
    }

    private func makeCoordinator(
        store: ConversationStore,
        transport: any ChatTransport
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

    private static func hello(
        sequence: Int64,
        connectionState: String? = nil
    ) -> ChatEnvelope {
        var payload = (try? JSONValue.encoded(ChatCapabilities(features: ["streaming"])))
            ?? .object([:])
        if let connectionState, case .object(var members) = payload {
            members["connectionState"] = .string(connectionState)
            payload = .object(members)
        }
        return ChatTestFixtures.event(
            "session.hello",
            sequence: sequence,
            payload: payload
        )
    }

    private static func snapshotEnvelope(
        generation: String,
        baseSequence: Int64,
        items: [ConversationItem],
        connectionState: ChatConnectionState
    ) throws -> ChatEnvelope {
        let snapshot = ConversationSnapshot(
            snapshotGeneration: generation,
            baseSequence: baseSequence,
            items: items,
            connectionState: connectionState
        )
        return ChatTestFixtures.event(
            "conversation.snapshot",
            sequence: baseSequence,
            payload: try JSONValue.encoded(snapshot),
            snapshotGeneration: generation
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

    private func conditionBecomesTrue(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await condition()) {
            if DispatchTime.now().uptimeNanoseconds - start > timeoutNanoseconds {
                return false
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
}

private actor ControlledConversationStateCache: ConversationStateCaching {
    private var loadContinuation:
        CheckedContinuation<ConversationState?, Never>?
    private var loadStartedContinuations:
        [CheckedContinuation<Void, Never>] = []
    private var didStartLoad = false
    private var saved: [ConversationState] = []
    private let loadResult: ConversationState?
    private let suspendsLoad: Bool

    init(
        loadResult: ConversationState? = nil,
        suspendsLoad: Bool = true
    ) {
        self.loadResult = loadResult
        self.suspendsLoad = suspendsLoad
    }

    func load(
        for identity: ChatConversationIdentity
    ) async -> ConversationState? {
        didStartLoad = true
        let waiters = loadStartedContinuations
        loadStartedContinuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        guard suspendsLoad else { return loadResult }
        return await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func save(
        _ state: ConversationState,
        for identity: ChatConversationIdentity
    ) async {
        saved.append(state)
    }

    func waitUntilLoadStarts() async {
        guard !didStartLoad else { return }
        await withCheckedContinuation { continuation in
            loadStartedContinuations.append(continuation)
        }
    }

    func releaseLoad(returning state: ConversationState?) {
        loadContinuation?.resume(returning: state)
        loadContinuation = nil
    }

    func savedStates() -> [ConversationState] {
        saved
    }
}

private actor LifecycleRegressionTransport: ChatTransport {
    private let stream: AsyncStream<ChatTransportEvent>
    private let continuation: AsyncStream<ChatTransportEvent>.Continuation
    private let initialEnvelope: ChatEnvelope?
    private let suspendsConnectUntilDisconnect: Bool
    private let suspendsDetachSendUntilDisconnect: Bool
    private var pendingConnect: CheckedContinuation<Void, Error>?
    private var pendingDetachSend: CheckedContinuation<Void, Never>?
    private var connectCalls = 0
    private var disconnectCalls = 0
    private var sentCommandTypes: [String] = []
    private var ordinaryDetachSends = 0
    private var bestEffortDetaches = 0
    private var isConnected = false

    init(
        initialEnvelope: ChatEnvelope?,
        suspendsConnectUntilDisconnect: Bool,
        suspendsDetachSendUntilDisconnect: Bool = false
    ) {
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        stream = pair.stream
        continuation = pair.continuation
        self.initialEnvelope = initialEnvelope
        self.suspendsConnectUntilDisconnect = suspendsConnectUntilDisconnect
        self.suspendsDetachSendUntilDisconnect = suspendsDetachSendUntilDisconnect
    }

    func connect() async throws {
        connectCalls += 1
        if suspendsConnectUntilDisconnect {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                pendingConnect = continuation
            }
        } else {
            isConnected = true
        }
    }

    func send(_ envelope: ChatEnvelope) async throws {
        guard isConnected else {
            throw ChatTransportFailure(
                category: "not_connected",
                message: "The lifecycle regression transport is disconnected.",
                isRecoverable: true
            )
        }
        sentCommandTypes.append(envelope.type)
        if envelope.type == "session.detach" {
            ordinaryDetachSends += 1
            if suspendsDetachSendUntilDisconnect {
                await withCheckedContinuation { continuation in
                    pendingDetachSend = continuation
                }
            }
        }
        if envelope.type == "session.attach", let initialEnvelope {
            continuation.yield(.envelope(initialEnvelope))
        }
    }

    func disconnect(sendingBestEffort envelope: ChatEnvelope?) async {
        if let envelope, isConnected {
            sentCommandTypes.append(envelope.type)
            if envelope.type == "session.detach" {
                bestEffortDetaches += 1
            }
        }
        disconnectCalls += 1
        isConnected = false
        resumePendingConnect()
        resumePendingDetachSend()
    }

    func events() async -> AsyncStream<ChatTransportEvent> {
        stream
    }

    func isConnectSuspended(call: Int) -> Bool {
        connectCalls == call && pendingConnect != nil
    }

    func connectCallCount() -> Int {
        connectCalls
    }

    func disconnectCallCount() -> Int {
        disconnectCalls
    }

    func sentCommandCount(type: String) -> Int {
        sentCommandTypes.count { $0 == type }
    }

    func ordinaryDetachSendCallCount() -> Int {
        ordinaryDetachSends
    }

    func bestEffortDetachCallCount() -> Int {
        bestEffortDetaches
    }

    func releasePendingConnectForCleanup() {
        resumePendingConnect()
    }

    func releasePendingDetachSendForCleanup() {
        resumePendingDetachSend()
    }

    private func resumePendingConnect() {
        guard let continuation = pendingConnect else { return }
        pendingConnect = nil
        continuation.resume(
            throwing: ChatTransportFailure(
                category: "cancelled",
                message: "The lifecycle regression connection was closed.",
                isRecoverable: true
            )
        )
    }

    private func resumePendingDetachSend() {
        pendingDetachSend?.resume()
        pendingDetachSend = nil
    }
}

private actor LifecycleGateTransport: ChatTransport {
    private let stream: AsyncStream<ChatTransportEvent>
    private let continuation: AsyncStream<ChatTransportEvent>.Continuation
    private let initialEnvelope: ChatEnvelope?
    private let acknowledgesStop: Bool
    private let connectShouldFail: Bool
    private var heldDisconnectCalls: Set<Int>
    private var disconnectContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var connectCalls = 0
    private var sentCommandTypes: [String] = []
    private var disconnectCalls = 0
    private var isConnected = false

    init(
        initialEnvelope: ChatEnvelope?,
        heldDisconnectCalls: Set<Int>,
        acknowledgesStop: Bool = false,
        connectShouldFail: Bool = false
    ) {
        let pair = AsyncStream.makeStream(of: ChatTransportEvent.self)
        stream = pair.stream
        continuation = pair.continuation
        self.initialEnvelope = initialEnvelope
        self.heldDisconnectCalls = heldDisconnectCalls
        self.acknowledgesStop = acknowledgesStop
        self.connectShouldFail = connectShouldFail
    }

    func connect() async throws {
        connectCalls += 1
        if connectShouldFail {
            throw ChatTransportFailure(
                category: "test_connect_failure",
                message: "Controlled connection failure.",
                isRecoverable: true
            )
        }
        isConnected = true
    }

    func send(_ envelope: ChatEnvelope) async throws {
        guard isConnected else {
            throw ChatTransportFailure(
                category: "not_connected",
                message: "The controlled transport is disconnected.",
                isRecoverable: true
            )
        }
        sentCommandTypes.append(envelope.type)
        if envelope.type == "session.attach", let initialEnvelope {
            continuation.yield(.envelope(initialEnvelope))
        }
        if acknowledgesStop,
           envelope.type == "session.stop",
           let requestID = envelope.requestID {
            continuation.yield(
                .envelope(
                    ChatTestFixtures.event(
                        "ack",
                        sequence: 2,
                        payload: .object(["requestId": .string(requestID)])
                    )
                )
            )
        }
    }

    func disconnect(sendingBestEffort envelope: ChatEnvelope?) async {
        if let envelope, isConnected {
            sentCommandTypes.append(envelope.type)
        }
        disconnectCalls += 1
        let call = disconnectCalls
        if heldDisconnectCalls.contains(call) {
            await withCheckedContinuation { continuation in
                disconnectContinuations[call] = continuation
            }
        }
        isConnected = false
    }

    func events() async -> AsyncStream<ChatTransportEvent> {
        stream
    }

    func yield(_ event: ChatTransportEvent) {
        continuation.yield(event)
    }

    func releaseDisconnect(call: Int) {
        heldDisconnectCalls.remove(call)
        disconnectContinuations.removeValue(forKey: call)?.resume()
    }

    func connectCallCount() -> Int {
        connectCalls
    }

    func disconnectCallCount() -> Int {
        disconnectCalls
    }

    func sentCommandCount(type: String) -> Int {
        sentCommandTypes.count { $0 == type }
    }
}
