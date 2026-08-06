import Combine
import XCTest
@testable import TerminalRelay

@MainActor
final class ConversationStoreTests: XCTestCase {
    func testNoOpEnvelopesDoNotPublishButRealChangesDo() throws {
        let store = ConversationStore()
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 1,
                itemID: "message-1",
                turnID: "turn-1",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("Hello"),
                ])
            )
        )

        var publishCount = 0
        let subscription = store.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }

        try store.apply(
            ChatTestFixtures.event("session.heartbeat", sequence: 0)
        )
        XCTAssertEqual(
            publishCount,
            0,
            "A heartbeat that changes nothing must not invalidate the transcript."
        )

        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 2,
                itemID: "message-2",
                turnID: "turn-1",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("A real update"),
                ])
            )
        )
        XCTAssertEqual(publishCount, 1)
    }

    func testSequenceZeroHelloUpdatesCapabilitiesWithoutAdvancingReplayCursor() throws {
        let store = ConversationStore()
        let capabilities = ChatCapabilities(
            features: ["streaming", "history"],
            supportsAttachments: true
        )
        try store.apply(
            ChatTestFixtures.event(
                "session.hello",
                sequence: 0,
                payload: .object([
                    "connectionState": .string("streaming"),
                    "capabilities": try JSONValue.encoded(capabilities),
                ])
            )
        )

        XCTAssertEqual(store.state.connectionState, .streaming)
        XCTAssertEqual(store.state.capabilities, capabilities)
        XCTAssertEqual(store.state.lastAppliedSequence, 0)
    }

    func testControlEventsAdvanceCursorWithoutInvalidatingTranscriptContent() throws {
        let store = ConversationStore()
        let initialRevision = store.transcriptContentRevision
        let initialMutation = store.transcriptMutation

        try store.apply(
            ChatTestFixtures.event("session.heartbeat", sequence: 1)
        )
        try store.apply(
            ChatTestFixtures.event(
                "ack",
                sequence: 2,
                payload: .object(["commandType": .string("session.attach")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "session.state",
                sequence: 3,
                payload: .object(["connectionState": .string("streaming")])
            )
        )

        XCTAssertEqual(store.state.lastAppliedSequence, 3)
        XCTAssertEqual(store.transcriptContentRevision, initialRevision)
        XCTAssertEqual(store.transcriptMutation, initialMutation)

        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 4,
                itemID: "message-1",
                turnID: "turn-1",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("Visible update"),
                ])
            )
        )

        XCTAssertEqual(store.transcriptContentRevision, initialRevision + 1)
    }

    func testToolOutputDeltaAppendsAndAuthoritativeOutputWins() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                ])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "tool.updated",
                sequence: 2,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object(["outputDelta": .string("first ")])
            )
        )
        store.flushStreamingUpdates()
        try store.apply(
            ChatTestFixtures.event(
                "tool.updated",
                sequence: 3,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object(["outputDelta": .string("second")])
            )
        )
        store.flushStreamingUpdates()
        XCTAssertEqual(store.state.tools.first?.output, "first second")

        try store.apply(
            ChatTestFixtures.event(
                "tool.updated",
                sequence: 4,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "output": .string("authoritative"),
                    "outputDelta": .string("must-not-append"),
                ])
            )
        )
        store.flushStreamingUpdates()
        XCTAssertEqual(store.state.tools.first?.output, "authoritative")
    }

    func testTranscriptMutationReportsOneCoalescedChangedRowAndExactEviction() throws {
        let store = ConversationStore(
            reducer: ConversationReducer(
                maximumRetainedItems: 2,
                maximumRetainedContentBytes: 1_048_576
            ),
            streamingPublishNanoseconds: 1_000_000_000
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message-1",
                turnID: "turn",
                payload: .object(["role": .string("assistant")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 2,
                itemID: "message-1",
                turnID: "turn",
                payload: .object(["text": .string("a")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 3,
                itemID: "message-1",
                turnID: "turn",
                payload: .object(["text": .string("b")])
            )
        )
        store.flushStreamingUpdates()
        XCTAssertEqual(store.transcriptMutation.changedIDs, ["message-1"])
        XCTAssertTrue(store.transcriptMutation.insertions.isEmpty)
        XCTAssertTrue(store.transcriptMutation.removedIDs.isEmpty)
        XCTAssertEqual(store.state.messages.first?.text, "ab")

        for (sequence, id) in [(4, "message-2"), (5, "message-3")] {
            try store.apply(
                ChatTestFixtures.event(
                    "message.completed",
                    sequence: Int64(sequence),
                    itemID: id,
                    turnID: "turn",
                    payload: .object([
                        "role": .string("assistant"),
                        "text": .string(id),
                    ])
                )
            )
        }
        XCTAssertEqual(store.state.items.map(\.id), ["message-2", "message-3"])
        XCTAssertEqual(store.transcriptMutation.removedIDs, ["message-1"])
        XCTAssertEqual(store.transcriptMutation.insertions.map(\.id), ["message-3"])
    }

    func testStreamingProjectionResegmentsOnlyMutableTailIndependentOfPrefix() throws {
        let prefix = String(repeating: "prefix-value-0123456789\n", count: 20_000)
        let firstDelta = String(repeating: "first-delta\n", count: 80)
        let secondDelta = String(repeating: "second-delta\n", count: 80)
        let store = ConversationStore(streamingPublishNanoseconds: 1_000_000_000)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(prefix),
                ])
            )
        )
        let initialItem = try XCTUnwrap(store.state.items.first)
        let initialRows = store.transcriptProjections(for: initialItem)
        XCTAssertGreaterThan(initialRows.count, 100)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 1)

        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 2,
                itemID: "message",
                turnID: "turn",
                payload: .object(["text": .string(firstDelta)])
            )
        )
        store.flushStreamingUpdates()
        let firstRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(firstRows.map(\.sourceText).joined(), prefix + firstDelta)
        XCTAssertEqual(
            Array(initialRows.dropLast()),
            Array(firstRows.prefix(initialRows.count - 1))
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 1)
        XCTAssertEqual(store.projectionDiagnostics.incrementalTailBuilds, 1)
        XCTAssertEqual(
            store.projectionDiagnostics.lastIncrementalSourceBytes,
            try XCTUnwrap(initialRows.last).sourceText.utf8.count + firstDelta.utf8.count
        )
        XCTAssertLessThan(
            store.projectionDiagnostics.lastIncrementalSourceBytes,
            prefix.utf8.count / 10
        )

        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 3,
                itemID: "message",
                turnID: "turn",
                payload: .object(["text": .string(secondDelta)])
            )
        )
        store.flushStreamingUpdates()
        let secondRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(
            secondRows.map(\.sourceText).joined(),
            prefix + firstDelta + secondDelta
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 1)
        XCTAssertEqual(store.projectionDiagnostics.incrementalTailBuilds, 2)
        XCTAssertLessThanOrEqual(
            store.projectionDiagnostics.lastIncrementalSourceBytes,
            TranscriptRowProjection.maximumDisplayBytes + secondDelta.utf8.count
        )
    }

    func testLiveScrollingDefersStreamingPublicationAndCatchesUpOnce() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("prefix"),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let publishedMutationRevision = store.transcriptMutation.revision

        var publishCount = 0
        let subscription = store.objectWillChange.sink { publishCount += 1 }
        defer { subscription.cancel() }

        store.setTranscriptLiveScrolling(true)
        for (sequence, delta) in [(2, "-one"), (3, "-two")] {
            try store.apply(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: Int64(sequence),
                    itemID: "message",
                    turnID: "turn",
                    payload: .object(["text": .string(delta)])
                )
            )
        }

        XCTAssertEqual(store.lastAppliedSequence, 3)
        XCTAssertEqual(store.state.messages.first?.text, "prefix")
        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertEqual(store.transcriptMutation.revision, publishedMutationRevision)
        XCTAssertEqual(store.projectionDiagnostics.incrementalTailBuilds, 0)
        XCTAssertEqual(publishCount, 0)

        store.setTranscriptLiveScrolling(false)

        XCTAssertEqual(store.state.messages.first?.text, "prefix-one-two")
        XCTAssertEqual(store.state.lastAppliedSequence, 3)
        XCTAssertEqual(store.transcriptMutation.revision, publishedMutationRevision + 1)
        XCTAssertEqual(store.projectionDiagnostics.incrementalTailBuilds, 1)
        XCTAssertEqual(publishCount, 1)
    }

    func testBrowsingHistoryDefersStreamingPublicationUntilJumpToLatest() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("visible"),
                ])
            )
        )
        store.setNearBottom(false)

        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 2,
                itemID: "message",
                turnID: "turn",
                payload: .object(["text": .string("-deferred")])
            )
        )

        XCTAssertEqual(store.lastAppliedSequence, 2)
        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertEqual(store.state.messages.first?.text, "visible")

        store.jumpToLatest()

        XCTAssertTrue(store.isNearBottom)
        XCTAssertEqual(store.state.lastAppliedSequence, 2)
        XCTAssertEqual(store.state.messages.first?.text, "visible-deferred")
    }

    func testCompletionDuringLiveScrollPublishesAfterGestureEvenWhenBrowsing() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("initial"),
                ])
            )
        )
        store.setTranscriptLiveScrolling(true)
        store.setNearBottom(false)
        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 2,
                itemID: "message",
                turnID: "turn",
                payload: .object(["text": .string("-streaming")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 3,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("authoritative-final"),
                ])
            )
        )

        XCTAssertEqual(store.lastAppliedSequence, 3)
        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertEqual(store.state.messages.first?.text, "initial")

        store.setTranscriptLiveScrolling(false)

        XCTAssertFalse(store.isNearBottom)
        XCTAssertEqual(store.state.lastAppliedSequence, 3)
        XCTAssertEqual(store.state.messages.first?.text, "authoritative-final")
        XCTAssertFalse(try XCTUnwrap(store.state.messages.first).isStreaming)
    }

    func testTerminalTurnDoesNotRebuildAlreadyFinalizedItems() throws {
        let text = String(repeating: "sealed-prefix-line\n", count: 2_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(text),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 2,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(text),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let fullBuilds = store.projectionDiagnostics.fullItemBuilds
        let contentRevision = store.transcriptContentRevision
        let mutationRevision = store.transcriptMutation.revision

        try store.apply(
            ChatTestFixtures.event(
                "turn.completed",
                sequence: 3,
                turnID: "turn"
            )
        )

        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(store.state.turnState, .completed)
        XCTAssertEqual(store.transcriptContentRevision, contentRevision)
        XCTAssertEqual(store.transcriptMutation.revision, mutationRevision)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, fullBuilds)
    }

    func testTerminalTurnFinalizesOnlyStreamingTailWithoutFullProjection() throws {
        let text = String(repeating: "streaming-prefix-line\n", count: 2_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(text),
                ])
            )
        )
        let initialRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertGreaterThan(initialRows.count, 1)

        try store.apply(
            ChatTestFixtures.event(
                "turn.completed",
                sequence: 2,
                turnID: "turn"
            )
        )

        let finalMessage = try XCTUnwrap(store.state.messages.first)
        let finalRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertFalse(finalMessage.isStreaming)
        XCTAssertEqual(finalMessage.text, text)
        XCTAssertEqual(finalRows.map(\.sourceText).joined(), text)
        XCTAssertEqual(Array(initialRows.dropLast()), Array(finalRows.dropLast()))
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 1)
        XCTAssertEqual(store.projectionDiagnostics.incrementalTailBuilds, 1)
        XCTAssertLessThanOrEqual(
            store.projectionDiagnostics.lastIncrementalSourceBytes,
            TranscriptRowProjection.maximumDisplayBytes
        )
    }

    func testReasoningAndToolOutputDeltasUseTailProjectionButReplacementsRebuild() throws {
        let reasoningStore = ConversationStore(
            streamingPublishNanoseconds: 1_000_000_000
        )
        let reasoningPrefix = String(repeating: "thought\n", count: 2_000)
        try reasoningStore.apply(
            ChatTestFixtures.event(
                "reasoning.started",
                sequence: 1,
                itemID: "reasoning",
                turnID: "turn",
                payload: .object(["text": .string(reasoningPrefix)])
            )
        )
        _ = reasoningStore.transcriptProjections(
            for: try XCTUnwrap(reasoningStore.state.items.first)
        )
        try reasoningStore.apply(
            ChatTestFixtures.event(
                "reasoning.delta",
                sequence: 2,
                itemID: "reasoning",
                turnID: "turn",
                payload: .object(["text": .string("more")])
            )
        )
        reasoningStore.flushStreamingUpdates()
        let reasoningRows = reasoningStore.transcriptProjections(
            for: try XCTUnwrap(reasoningStore.state.items.first)
        )
        XCTAssertEqual(reasoningRows.map(\.sourceText).joined(), reasoningPrefix + "more")
        XCTAssertEqual(reasoningStore.projectionDiagnostics.fullItemBuilds, 1)
        XCTAssertEqual(reasoningStore.projectionDiagnostics.incrementalTailBuilds, 1)

        let toolStore = ConversationStore(streamingPublishNanoseconds: 1_000_000_000)
        let toolPrefix = String(repeating: "output\n", count: 2_000)
        try toolStore.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "output": .string(toolPrefix),
                ])
            )
        )
        _ = toolStore.transcriptProjections(
            for: try XCTUnwrap(toolStore.state.items.first)
        )
        try toolStore.apply(
            ChatTestFixtures.event(
                "tool.updated",
                sequence: 2,
                itemID: "tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "outputDelta": .string("tail"),
                ])
            )
        )
        toolStore.flushStreamingUpdates()
        let toolRows = toolStore.transcriptProjections(
            for: try XCTUnwrap(toolStore.state.items.first)
        )
        XCTAssertEqual(
            toolRows.filter { $0.section == .toolOutput }.map(\.sourceText).joined(),
            toolPrefix + "tail"
        )
        XCTAssertEqual(toolStore.projectionDiagnostics.fullItemBuilds, 1)
        XCTAssertEqual(toolStore.projectionDiagnostics.incrementalTailBuilds, 1)

        try toolStore.apply(
            ChatTestFixtures.event(
                "tool.updated",
                sequence: 3,
                itemID: "tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "output": .string("authoritative"),
                ])
            )
        )
        toolStore.flushStreamingUpdates()
        let replacedRows = toolStore.transcriptProjections(
            for: try XCTUnwrap(toolStore.state.items.first)
        )
        XCTAssertEqual(replacedRows.map(\.sourceText).joined(), "authoritative")
        XCTAssertEqual(toolStore.projectionDiagnostics.fullItemBuilds, 2)
        XCTAssertEqual(toolStore.projectionDiagnostics.incrementalTailBuilds, 1)
    }

    func testCollapsedMegabyteToolAndDiffBuildOnlyOneBoundedTile() throws {
        let nearMegabyte = String(repeating: "0123456789abcdef", count: 56_000)
        XCTAssertGreaterThan(nearMegabyte.utf8.count, 850_000)
        let diff = ConversationItem.diff(
            ChatDiff(
                id: "diff",
                turnID: "turn",
                path: "Example.swift",
                unifiedDiff: nearMegabyte,
                occurredAt: nil,
                isTruncated: false
            )
        )
        let tool = ConversationItem.tool(
            ToolActivity(
                id: "tool",
                turnID: "turn",
                kind: .shell,
                title: "Command",
                status: .completed,
                input: nil,
                output: nearMegabyte,
                errorMessage: nil,
                durationMilliseconds: nil,
                exitCode: 0,
                occurredAt: nil,
                isTruncated: false,
                originalByteCount: nil
            )
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [diff, tool]
            )
        )

        let diffFirst = try XCTUnwrap(store.transcriptFirstProjection(for: diff))
        let toolFirst = try XCTUnwrap(store.transcriptFirstProjection(for: tool))
        XCTAssertTrue(nearMegabyte.hasPrefix(diffFirst.sourceText))
        XCTAssertTrue(nearMegabyte.hasPrefix(toolFirst.sourceText))
        XCTAssertLessThanOrEqual(
            diffFirst.sourceText.utf8.count,
            TranscriptRowProjection.maximumDisplayBytes
        )
        XCTAssertLessThanOrEqual(
            toolFirst.sourceText.utf8.count,
            TranscriptRowProjection.maximumDisplayBytes
        )
        XCTAssertEqual(store.projectionDiagnostics.boundedFirstRowBuilds, 2)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)
        XCTAssertLessThanOrEqual(
            store.projectionDiagnostics.maximumFirstRowSourceBytes,
            TranscriptRowProjection.maximumDisplayBytes
        )

        _ = store.transcriptFirstProjection(for: diff)
        _ = store.transcriptFirstProjection(for: tool)
        XCTAssertEqual(store.projectionDiagnostics.boundedFirstRowBuilds, 2)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)

        let expandedDiff = store.transcriptProjections(for: diff)
        XCTAssertEqual(expandedDiff.first, diffFirst)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 1)
    }

    func testAppliesFlatSnapshotAndUsesBaseSeqCodingKey() throws {
        let flatItems: JSONValue = .array([
            .object([
                "type": .string("message.completed"),
                "turnId": .string("turn-1"),
                "itemId": .string("message-1"),
                "occurredAt": .number(10),
                "payload": .object([
                    "role": .string("assistant"),
                    "text": .string("Hello from history"),
                ]),
            ]),
            .object([
                "type": .string("tool.completed"),
                "turnId": .string("turn-1"),
                "itemId": .string("tool-1"),
                "occurredAt": .number(11),
                "payload": .object([
                    "kind": .string("shell"),
                    "title": .string("Check files"),
                    "status": .string("completed"),
                    "output": .string("done"),
                ]),
            ]),
        ])
        let payload: JSONValue = .object([
            "snapshotGeneration": .string(ChatTestFixtures.generation),
            "baseSeq": .number(12),
            "items": flatItems,
            "approvals": .array([]),
            "questions": .array([]),
            "connectionState": .string("streaming"),
            "turnState": .string("completed"),
            "activeTurnId": .null,
            "capabilities": try JSONValue.encoded(ChatCapabilities(features: ["streaming"])),
            "usage": .null,
            "hasOlderHistory": .bool(true),
            "oldestItemId": .string("message-1"),
        ])
        let store = ConversationStore()

        try store.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 12,
                payload: payload
            )
        )

        XCTAssertEqual(store.state.lastAppliedSequence, 12)
        XCTAssertEqual(store.state.messages.map(\.text), ["Hello from history"])
        XCTAssertEqual(store.state.tools.map(\.title), ["Check files"])
        XCTAssertTrue(store.state.hasOlderHistory)
        XCTAssertEqual(store.state.oldestItemID, "message-1")
    }

    func testConnectingPlaceholderSnapshotKeepsPaintedTranscript() throws {
        let store = ConversationStore()
        func snapshotPayload(
            generation: String,
            baseSequence: Int64,
            connectionState: String,
            items: JSONValue
        ) throws -> JSONValue {
            .object([
                "snapshotGeneration": .string(generation),
                "baseSeq": .number(Double(baseSequence)),
                "items": items,
                "approvals": .array([]),
                "questions": .array([]),
                "connectionState": .string(connectionState),
                "turnState": .string("idle"),
                "activeTurnId": .null,
                "capabilities": try JSONValue.encoded(
                    ChatCapabilities(features: ["streaming"])
                ),
                "usage": .null,
                "hasOlderHistory": .bool(false),
                "oldestItemId": .null,
            ])
        }
        func messageItems(_ text: String) -> JSONValue {
            .array([
                .object([
                    "type": .string("message.completed"),
                    "turnId": .string("turn-1"),
                    "itemId": .string("message-1"),
                    "occurredAt": .number(10),
                    "payload": .object([
                        "role": .string("assistant"),
                        "text": .string(text),
                    ]),
                ])
            ])
        }

        // Painted content — stands in for cache hydration or a prior attach.
        try store.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 12,
                payload: try snapshotPayload(
                    generation: ChatTestFixtures.generation,
                    baseSequence: 12,
                    connectionState: "streaming",
                    items: messageItems("Hello from history")
                )
            )
        )

        // A restarted worker admits the attach before its provider resumes
        // and answers with an empty pre-resume placeholder on a new
        // generation: the painted transcript must survive it.
        let rebuiltGeneration = "00000000-0000-4000-8000-00000000000e"
        try store.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 1,
                payload: try snapshotPayload(
                    generation: rebuiltGeneration,
                    baseSequence: 1,
                    connectionState: "connecting",
                    items: .array([])
                ),
                snapshotGeneration: rebuiltGeneration
            )
        )
        XCTAssertEqual(store.state.messages.map(\.text), ["Hello from history"])
        XCTAssertEqual(store.state.snapshotGeneration, rebuiltGeneration)
        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertEqual(store.state.connectionState, .connecting)

        // The rebuilt snapshot that follows replaces the transcript.
        try store.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 2,
                payload: try snapshotPayload(
                    generation: rebuiltGeneration,
                    baseSequence: 2,
                    connectionState: "connecting",
                    items: messageItems("Rebuilt from the worker")
                ),
                snapshotGeneration: rebuiltGeneration
            )
        )
        XCTAssertEqual(store.state.messages.map(\.text), ["Rebuilt from the worker"])
        XCTAssertEqual(store.state.lastAppliedSequence, 2)

        // A genuinely empty conversation still applies an empty placeholder.
        let freshStore = ConversationStore()
        try freshStore.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 1,
                payload: try snapshotPayload(
                    generation: rebuiltGeneration,
                    baseSequence: 1,
                    connectionState: "connecting",
                    items: .array([])
                ),
                snapshotGeneration: rebuiltGeneration
            )
        )
        XCTAssertEqual(freshStore.state.items, [])
        XCTAssertEqual(freshStore.state.connectionState, .connecting)
        XCTAssertEqual(freshStore.state.lastAppliedSequence, 1)
    }

    func testIdleResumeSnapshotInfersActiveTurnFromStreamingItemOnly() throws {
        let activeTurnID = "10000000-0000-4000-8000-000000000001"
        let streamingItem = ConversationItem.message(
            ChatMessage(
                id: "assistant-stream",
                turnID: activeTurnID,
                role: .assistant,
                text: "Partial response",
                isStreaming: true
            )
        )
        let store = ConversationStore()

        try store.apply(
            ChatTestFixtures.snapshotEvent(
                baseSequence: 1,
                items: [streamingItem],
                turnState: .idle
            )
        )

        XCTAssertEqual(store.state.turnState, .running)
        XCTAssertEqual(store.state.activeTurnID, activeTurnID)

        let completedStore = ConversationStore()
        try completedStore.apply(
            ChatTestFixtures.snapshotEvent(
                baseSequence: 1,
                items: [streamingItem],
                turnState: .completed
            )
        )
        XCTAssertEqual(completedStore.state.turnState, .completed)
        XCTAssertNil(completedStore.state.activeTurnID)
        XCTAssertFalse(completedStore.state.messages[0].isStreaming)
    }

    func testStreamingSnapshotWireStateIsAnActiveTurnBeforeItemsArrive() throws {
        let activeTurnID = "10000000-0000-4000-8000-000000000011"
        let store = ConversationStore()

        try store.apply(
            ChatTestFixtures.snapshotEvent(
                baseSequence: 1,
                turnState: .unknown("streaming"),
                activeTurnID: activeTurnID
            )
        )

        XCTAssertEqual(store.state.turnState, .running)
        XCTAssertEqual(store.state.activeTurnID, activeTurnID)
    }

    func testTurnActiveErrorReconcilesStreamingTurnAndRemovesRejectedOptimisticMessage() throws {
        let activeTurnID = "10000000-0000-4000-8000-000000000002"
        let requestID = "20000000-0000-4000-8000-000000000001"
        let store = ConversationStore(
            state: ConversationState(
                items: [
                    .message(
                        ChatMessage(
                            id: "assistant-stream",
                            turnID: activeTurnID,
                            role: .assistant,
                            text: "Still working",
                            isStreaming: true
                        )
                    ),
                ],
                connectionState: .streaming,
                turnState: .idle
            )
        )
        store.addOptimisticUserMessage(requestID: requestID, text: "Start another turn")

        try store.apply(
            ChatTestFixtures.event(
                "error",
                sequence: 1,
                payload: .object([
                    "requestId": .string(requestID),
                    "code": .string("turnActive"),
                    "message": .string("A provider turn is already active."),
                ])
            )
        )

        XCTAssertEqual(store.state.turnState, .running)
        XCTAssertEqual(store.state.activeTurnID, activeTurnID)
        XCTAssertFalse(store.state.messages.contains { $0.id == "client:\(requestID)" })
    }

    func testCoalescesRapidDeltasAndCompletionReplacesAuthoritatively() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 1_000_000_000)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message-1",
                payload: .object(["role": .string("assistant"), "text": .string("")])
            )
        )
        for sequence in 2...101 {
            try store.apply(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: Int64(sequence),
                    itemID: "message-1",
                    payload: .object(["text": .string("x")])
                )
            )
        }

        XCTAssertEqual(store.state.messages.first?.text, "")
        store.flushStreamingUpdates()
        XCTAssertEqual(store.state.messages.first?.text, String(repeating: "x", count: 100))

        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 102,
                itemID: "message-1",
                payload: .object(["text": .string("authoritative")])
            )
        )
        XCTAssertEqual(store.state.messages.first?.text, "authoritative")
        XCTAssertFalse(store.state.messages.first?.isStreaming ?? true)
    }

    func testInterruptedTurnFinishesStreamingItemsAndExpiresInteractions() throws {
        let turnID = "10000000-0000-4000-8000-000000000021"
        let approval = ApprovalRequest(
            id: "approval-1",
            turnID: turnID,
            providerConnectionGeneration: "generation-1",
            providerRequestID: .string("request-1"),
            title: "Run command",
            reason: nil,
            context: nil,
            decisions: [ApprovalDecision(id: "deny", label: "Deny")],
            status: .pending,
            occurredAt: nil
        )
        let question = QuestionRequest(
            id: "question-1",
            turnID: turnID,
            providerConnectionGeneration: "generation-1",
            providerRequestID: .string("request-2"),
            prompt: "Continue?",
            kind: .singleChoice,
            options: [QuestionOption(id: "yes", label: "Yes")],
            status: .pending
        )
        let store = ConversationStore(
            state: ConversationState(
                items: [
                    .message(
                        ChatMessage(
                            id: "message-1",
                            turnID: turnID,
                            role: .assistant,
                            text: "Partial",
                            isStreaming: true
                        )
                    ),
                    .reasoning(
                        ChatReasoning(
                            id: "reasoning-1",
                            turnID: turnID,
                            text: "Thinking",
                            isStreaming: true,
                            occurredAt: nil
                        )
                    ),
                    .tool(
                        ToolActivity(
                            id: "tool-1",
                            turnID: turnID,
                            kind: .shell,
                            title: "Run command",
                            status: .running,
                            input: nil,
                            output: nil,
                            errorMessage: nil,
                            durationMilliseconds: nil,
                            exitCode: nil,
                            occurredAt: nil,
                            isTruncated: false,
                            originalByteCount: nil
                        )
                    ),
                ],
                approvals: [approval],
                questions: [question],
                connectionState: .streaming,
                turnState: .running,
                activeTurnID: turnID
            )
        )

        try store.apply(
            ChatTestFixtures.event(
                "turn.interrupted",
                sequence: 1,
                turnID: turnID
            )
        )

        XCTAssertFalse(store.state.messages[0].isStreaming)
        guard case .reasoning(let reasoning) = store.state.items[1] else {
            return XCTFail("Expected reasoning item")
        }
        XCTAssertFalse(reasoning.isStreaming)
        XCTAssertEqual(store.state.tools[0].status, .cancelled)
        XCTAssertEqual(store.state.approvals[0].status, .expired)
        XCTAssertEqual(store.state.questions[0].status, .expired)
        XCTAssertEqual(store.state.turnState, .interrupted)
        XCTAssertNil(store.state.activeTurnID)
    }

    func testDuplicateIsHarmlessAndGapRequestsRecovery() throws {
        let initiallyGappedStore = ConversationStore()
        XCTAssertThrowsError(
            try initiallyGappedStore.apply(
                ChatTestFixtures.event(
                    "message.completed",
                    sequence: 3,
                    itemID: "message-before-snapshot",
                    payload: .object(["role": .string("assistant"), "text": .string("Missed")])
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationReducerError,
                .sequenceGap(expected: 1, received: 3)
            )
        }

        let store = ConversationStore()
        let first = ChatTestFixtures.event(
            "message.completed",
            sequence: 1,
            itemID: "message-1",
            payload: .object(["role": .string("assistant"), "text": .string("One")])
        )
        try store.apply(first)
        let revisionAfterFirstApply = store.transcriptContentRevision
        let mutationAfterFirstApply = store.transcriptMutation
        try store.apply(first)
        XCTAssertEqual(store.state.messages.count, 1)
        XCTAssertEqual(store.transcriptContentRevision, revisionAfterFirstApply)
        XCTAssertEqual(store.transcriptMutation, mutationAfterFirstApply)

        XCTAssertThrowsError(
            try store.apply(
                ChatTestFixtures.event(
                    "message.completed",
                    sequence: 3,
                    itemID: "message-2",
                    payload: .object(["role": .string("assistant"), "text": .string("Three")])
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ConversationReducerError,
                .sequenceGap(expected: 2, received: 3)
            )
        }
    }

    func testToolNullErrorCompletesSuccessfully() throws {
        let store = ConversationStore()
        try store.apply(
            ChatTestFixtures.event(
                "tool.completed",
                sequence: 1,
                itemID: "tool-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Build"),
                    "error": .null,
                    "output": .string("ok"),
                ])
            )
        )
        XCTAssertEqual(store.state.tools.first?.status, .completed)
        XCTAssertNil(store.state.tools.first?.errorMessage)
    }

    func testApprovalQuestionAndUnknownInteractionTransitions() throws {
        let store = ConversationStore()
        try store.apply(
            ChatTestFixtures.event(
                "approval.requested",
                sequence: 1,
                itemID: "approval-1",
                turnID: "turn-1",
                payload: .object([
                    "displayId": .string("approval-1"),
                    "providerConnectionGeneration": .string("generation-1"),
                    "providerRequestId": .number(7),
                    "title": .string("Allow edit?"),
                    "decisions": .array([
                        .object(["id": .string("approve"), "label": .string("Approve")]),
                        .object(["id": .string("deny"), "label": .string("Deny")]),
                    ]),
                ])
            )
        )
        XCTAssertEqual(store.state.connectionState, .awaitingApproval)
        XCTAssertEqual(store.state.pendingApprovals.map(\.id), ["approval-1"])

        try store.apply(
            ChatTestFixtures.event(
                "approval.resolved",
                sequence: 2,
                itemID: "approval-1",
                payload: .object([
                    "displayId": .string("approval-1"),
                    "decision": .string("approve"),
                ])
            )
        )
        XCTAssertEqual(store.state.approvals.first?.status, .approved)
        XCTAssertEqual(store.state.connectionState, .streaming)

        try store.apply(
            ChatTestFixtures.event(
                "future.interaction",
                sequence: 3,
                payload: .object([
                    "blocking": .bool(true),
                    "message": .string("Use terminal"),
                ])
            )
        )
        XCTAssertEqual(
            store.state.lastErrorMessage,
            "This agent interaction is not supported in native chat."
        )
        XCTAssertEqual(store.state.connectionState, .failed)
        XCTAssertFalse(store.state.items.contains { item in
            if case .generic = item { return true }
            return false
        })

        let fallbackStore = ConversationStore(
            state: ConversationState(connectionState: .streaming)
        )
        try fallbackStore.apply(
            ChatTestFixtures.event(
                "session.terminalFallbackRequired",
                sequence: 1,
                payload: .object(["message": .string("Open a terminal")])
            )
        )
        XCTAssertEqual(fallbackStore.state.connectionState, .failed)
        XCTAssertEqual(
            fallbackStore.state.lastErrorMessage,
            "This agent interaction is not supported in native chat."
        )
    }

    func testHistoryPagePrependsWithoutDuplicates() throws {
        let current = ConversationItem.message(
            ChatMessage(id: "current", role: .assistant, text: "Current")
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [current],
                hasOlderHistory: true,
                oldestItemID: "current"
            )
        )
        let older = ConversationItem.message(
            ChatMessage(id: "older", role: .assistant, text: "Older")
        )
        try store.apply(
            ChatTestFixtures.event(
                "history.page",
                sequence: 2,
                payload: .object([
                    "items": .array([
                        try JSONValue.encoded(older),
                        try JSONValue.encoded(current),
                    ]),
                    "hasOlderHistory": .bool(false),
                    "oldestItemId": .string("older"),
                ])
            )
        )
        XCTAssertEqual(store.state.items.map(\.id), ["older", "current"])
        XCTAssertFalse(store.state.hasOlderHistory)
    }

    func testRetainsOneThousandItemsAndRapidDeltasWithoutLosingFinalText() throws {
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let initialItems = (0..<1_000).map { index in
            ConversationItem.message(
                ChatMessage(id: "message-\(index)", role: .assistant, text: "\(index)")
            )
        }
        let store = ConversationStore(
            reducer: ConversationReducer(maximumRetainedItems: 1_000),
            streamingPublishNanoseconds: 1_000_000_000
        )
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: initialItems
            )
        )

        for sequence in 2...501 {
            try store.apply(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: Int64(sequence),
                    itemID: "message-999",
                    payload: .object(["text": .string("x")])
                )
            )
        }
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 502,
                itemID: "message-999",
                payload: .object(["text": .string("final")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 503,
                itemID: "message-new",
                payload: .object(["role": .string("assistant"), "text": .string("new")])
            )
        )

        XCTAssertEqual(store.state.items.count, 1_000)
        XCTAssertEqual(store.state.messages.first(where: { $0.id == "message-999" })?.text, "final")
        XCTAssertEqual(store.state.messages.last?.text, "new")
        XCTAssertTrue(store.state.didTruncateHistory)
        let elapsedSeconds = Double(
            DispatchTime.now().uptimeNanoseconds - startedAt
        ) / 1_000_000_000
        XCTAssertLessThan(elapsedSeconds, 2.0)
    }

    func testIncrementalContentAccountingEnforcesByteLimitAfterStreamingGrowth() throws {
        let store = ConversationStore(
            reducer: ConversationReducer(
                maximumRetainedItems: 10,
                maximumRetainedContentBytes: 6
            ),
            streamingPublishNanoseconds: 1_000_000_000
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 1,
                itemID: "message-1",
                payload: .object(["text": .string("1234")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 2,
                itemID: "message-2",
                payload: .object(["text": .string("5")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "message.delta",
                sequence: 3,
                itemID: "message-2",
                payload: .object(["text": .string("6789")])
            )
        )

        XCTAssertEqual(store.state.items.map(\.id), ["message-1", "message-2"])
        store.flushStreamingUpdates()
        XCTAssertEqual(store.state.items.map(\.id), ["message-2"])
        XCTAssertEqual(store.state.messages.last?.text, "56789")
        XCTAssertTrue(store.state.didTruncateHistory)
    }

    func testGroupedQuestionParsingAndFilePreviewLifecycle() throws {
        let store = ConversationStore()
        try store.apply(
            ChatTestFixtures.event(
                "question.requested",
                sequence: 1,
                itemID: "question-group",
                payload: .object([
                    "displayId": .string("question-group"),
                    "providerConnectionGeneration": .string("provider-generation"),
                    "providerRequestId": .number(9),
                    "questions": .array([
                        .object([
                            "id": .string("choice"),
                            "question": .string("Choose one"),
                            "options": .array([
                                .object([
                                    "label": .string("A"),
                                    "description": .string("First option"),
                                ]),
                            ]),
                        ]),
                        .object([
                            "id": .string("multiple"),
                            "prompt": .string("Choose several"),
                            "allowsMultiple": .bool(true),
                            "options": .array([.string("X"), .string("Y")]),
                        ]),
                        .object([
                            "id": .string("secret"),
                            "header": .string("Enter securely"),
                            "isSecret": .bool(true),
                        ]),
                    ]),
                ])
            )
        )

        let request = try XCTUnwrap(store.state.questions.first)
        XCTAssertEqual(request.prompt, "Agent needs 3 answers")
        XCTAssertEqual(request.resolvedFields.map(\.kind), [
            .singleChoice,
            .multipleChoice,
            .secret,
        ])
        XCTAssertEqual(request.resolvedFields[0].options.first?.detail, "First option")

        let secretKey = request.draftKey(for: request.resolvedFields[2])
        store.updateQuestionText(questionID: secretKey, text: "must-not-persist")
        XCTAssertNil(store.questionText[secretKey])

        try store.apply(
            ChatTestFixtures.event(
                "file.preview",
                sequence: 2,
                itemID: "preview",
                payload: .object([
                    "path": .string("Sources/App.swift"),
                    "content": .string("let value = 42"),
                    "line": .number(1),
                    "column": .number(5),
                    "truncated": .bool(false),
                    "originalByteCount": .number(14),
                ])
            )
        )
        XCTAssertEqual(store.state.filePreview?.path, "Sources/App.swift")
        XCTAssertEqual(store.state.filePreview?.content, "let value = 42")
        store.dismissFilePreview()
        XCTAssertNil(store.state.filePreview)
    }

    func testEveryPresentationInteractionStateIsDeterministicAndSecretTextIsNotRetained() {
        let secretQuestion = ChatTestFixtures.pendingQuestion(id: "secret", kind: .secret)
        let choiceQuestion = ChatTestFixtures.pendingQuestion(id: "choice", kind: .multipleChoice)
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                questions: [secretQuestion, choiceQuestion]
            )
        )

        store.toggleExpanded(itemID: "tool")
        XCTAssertTrue(store.expandedItemIDs.contains("tool"))
        store.toggleExpanded(itemID: "tool")
        XCTAssertFalse(store.expandedItemIDs.contains("tool"))

        store.toggleCodeBlock(itemID: "code")
        XCTAssertTrue(store.expandedCodeBlockIDs.contains("code"))
        store.markCopied(itemID: "code")
        XCTAssertEqual(store.copiedItemID, "code")

        store.requestDestructiveApprovalConfirmation(
            approvalID: "approval",
            decisionID: "delete"
        )
        XCTAssertEqual(
            store.pendingDestructiveApprovalConfirmation,
            DestructiveApprovalConfirmation(
                approvalID: "approval",
                decisionID: "delete"
            )
        )
        store.clearDestructiveApprovalConfirmation()
        XCTAssertNil(store.pendingDestructiveApprovalConfirmation)

        store.toggleQuestionOption(questionID: "choice", optionID: "a", allowsMultiple: true)
        store.toggleQuestionOption(questionID: "choice", optionID: "b", allowsMultiple: true)
        XCTAssertEqual(store.selectedQuestionOptions["choice"], Set(["a", "b"]))
        store.toggleQuestionOption(questionID: "choice", optionID: "a", allowsMultiple: true)
        XCTAssertEqual(store.selectedQuestionOptions["choice"], Set(["b"]))

        store.updateQuestionText(questionID: "choice", text: "stored")
        store.updateQuestionText(questionID: "secret", text: "must-not-be-stored")
        XCTAssertEqual(store.questionText["choice"], "stored")
        XCTAssertNil(store.questionText["secret"])

        store.setInteractionResponding("choice", isResponding: true)
        XCTAssertTrue(store.respondingInteractionIDs.contains("choice"))
        store.setInteractionResponding("choice", isResponding: false)
        XCTAssertFalse(store.respondingInteractionIDs.contains("choice"))

        store.attachments = [
            ChatAttachmentReference(id: "attachment", path: "/workspace/example/a.png", displayName: "a.png"),
        ]
        store.removeAttachment(id: "attachment")
        XCTAssertTrue(store.attachments.isEmpty)

        store.setNearBottom(false)
        XCTAssertFalse(store.isNearBottom)
        store.jumpToLatest()
        XCTAssertTrue(store.isNearBottom)
        XCTAssertEqual(store.unreadCount, 0)
    }
}
