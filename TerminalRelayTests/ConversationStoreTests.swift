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

    func testSameTextMessageCompletionSealsOnlyTheMutableTail() async throws {
        let source = String(repeating: "sealed-prefix-line\n", count: 2_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(source),
                ])
            )
        )
        let streamingRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let fullBuilds = store.projectionDiagnostics.fullItemBuilds
        let incrementalBuilds = store.projectionDiagnostics.incrementalTailBuilds
        XCTAssertGreaterThan(streamingRows.count, 1)

        let completion = ChatTestFixtures.event(
            "message.completed",
            sequence: 2,
            itemID: "message",
            turnID: "turn",
            payload: .object([
                "role": .string("assistant"),
                "text": .string(source),
            ])
        )
        let reducerPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: completion,
                retaining: store.itemsForTranscriptProjectionPreparation.first
            )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: completion,
            retaining: store.itemsForTranscriptProjectionPreparation,
            preparedReducerPayload: reducerPayload
        )
        XCTAssertTrue(
            prepared.isEmpty,
            "A metadata-only completion must preserve the incremental tail path."
        )
        try store.apply(
            completion,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: reducerPayload
        )

        let completedRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(completedRows.map(\.sourceText).joined(), source)
        XCTAssertEqual(Array(streamingRows.dropLast()), Array(completedRows.dropLast()))
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, fullBuilds)
        XCTAssertEqual(
            store.projectionDiagnostics.incrementalTailBuilds,
            incrementalBuilds + 1
        )
        XCTAssertLessThanOrEqual(
            store.projectionDiagnostics.lastIncrementalSourceBytes,
            TranscriptRowProjection.maximumDisplayBytes
        )
        XCTAssertEqual(
            store.projectionDiagnostics.preparedCompletionAdoptions,
            1
        )
    }

    func testAuthoritativeMessageCompletionAdoptsPreparedRowsWithoutMainActorBuild() async throws {
        let streamingSource = String(repeating: "streaming-line\n", count: 2_000)
        let authoritativeSource = String(streamingSource.dropLast()) + "X"
        XCTAssertEqual(authoritativeSource.utf8.count, streamingSource.utf8.count)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(streamingSource),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let fullBuilds = store.projectionDiagnostics.fullItemBuilds
        let completion = ChatTestFixtures.event(
            "message.completed",
            sequence: 2,
            itemID: "message",
            turnID: "turn",
            payload: .object([
                "role": .string("assistant"),
                "text": .string(authoritativeSource),
            ])
        )
        let reducerPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: completion,
                retaining: store.itemsForTranscriptProjectionPreparation.first
            )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: completion,
            retaining: store.itemsForTranscriptProjectionPreparation,
            preparedReducerPayload: reducerPayload
        )

        try store.apply(
            completion,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: reducerPayload
        )

        let completedRows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(completedRows.map(\.sourceText).joined(), authoritativeSource)
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            fullBuilds,
            "The first published final rows must use the off-main prepared artifact."
        )
        XCTAssertEqual(
            store.projectionDiagnostics.preparedCompletionAdoptions,
            1,
            "The main actor must adopt the detached completion without comparing full text again."
        )
    }

    func testAuthoritativeCompletionPreservesExactUnicodeBytes() async throws {
        let prefix = String(repeating: "unicode-line\n", count: 2_000)
        let streamingSource = prefix + "\u{00E9}"
        let authoritativeSource = prefix + "e\u{0301}"
        XCTAssertEqual(streamingSource, authoritativeSource)
        XCTAssertNotEqual(Array(streamingSource.utf8), Array(authoritativeSource.utf8))

        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "unicode-message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(streamingSource),
                ])
            )
        )
        let completion = ChatTestFixtures.event(
            "message.completed",
            sequence: 2,
            itemID: "unicode-message",
            turnID: "turn",
            payload: .object([
                "role": .string("assistant"),
                "text": .string(authoritativeSource),
            ])
        )
        let reducerPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: completion,
                retaining: store.itemsForTranscriptProjectionPreparation.first
            )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: completion,
            retaining: store.itemsForTranscriptProjectionPreparation,
            preparedReducerPayload: reducerPayload
        )
        XCTAssertNotNil(prepared["unicode-message"])

        try store.apply(
            completion,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: reducerPayload
        )
        let completed = try XCTUnwrap(store.state.messages.first)
        let rows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(Array(completed.text.utf8), Array(authoritativeSource.utf8))
        XCTAssertEqual(
            Array(rows.map(\.sourceText).joined().utf8),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(store.projectionDiagnostics.preparedCompletionAdoptions, 1)
    }

    func testAuthoritativeReasoningCompletionAdoptsPreparedItemAndRows() async throws {
        let chunk = String(repeating: "reasoning-0123456789", count: 220) + "\n"
        let chunkCount = 128
        let streamedSource = String(repeating: chunk, count: chunkCount) + "\u{00E9}"
        let authoritativeSource = String(repeating: chunk, count: chunkCount)
            + "e\u{0301}"
        XCTAssertEqual(streamedSource, authoritativeSource)
        XCTAssertNotEqual(Array(streamedSource.utf8), Array(authoritativeSource.utf8))

        let store = ConversationStore(streamingPublishNanoseconds: 0)
        store.setTranscriptLiveScrolling(true)
        try store.apply(
            ChatTestFixtures.event(
                "reasoning.started",
                sequence: 1,
                itemID: "large-reasoning",
                turnID: "turn",
                payload: .object(["text": .string("")])
            )
        )
        for offset in 0..<chunkCount {
            try store.apply(
                ChatTestFixtures.event(
                    "reasoning.delta",
                    sequence: Int64(offset + 2),
                    itemID: "large-reasoning",
                    turnID: "turn",
                    payload: .object(["text": .string(chunk)])
                )
            )
        }
        try store.apply(
            ChatTestFixtures.event(
                "reasoning.delta",
                sequence: Int64(chunkCount + 2),
                itemID: "large-reasoning",
                turnID: "turn",
                payload: .object(["text": .string("\u{00E9}")])
            )
        )
        guard case .reasoning(let capturedReasoning)? = store
            .itemsForTranscriptProjectionPreparation.first else {
            return XCTFail("Expected chunked reasoning before completion")
        }
        XCTAssertEqual(capturedReasoning.textUTF8Count, streamedSource.utf8.count)
        XCTAssertFalse(capturedReasoning.isTextStorageMaterialized)

        let completion = ChatTestFixtures.event(
            "reasoning.completed",
            sequence: Int64(chunkCount + 3),
            itemID: "large-reasoning",
            turnID: "turn",
            payload: .object(["text": .string(authoritativeSource)])
        )
        let reducerPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: completion,
                retaining: .reasoning(capturedReasoning)
            )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: completion,
            retaining: store.itemsForTranscriptProjectionPreparation,
            preparedReducerPayload: reducerPayload
        )
        XCTAssertNotNil(prepared["large-reasoning"])

        try store.apply(
            completion,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: reducerPayload
        )
        store.setTranscriptLiveScrolling(false)

        guard case .reasoning(let completedReasoning)? = store.state.items.first else {
            return XCTFail("Expected completed reasoning")
        }
        let rows = store.transcriptProjections(for: store.state.items[0])
        XCTAssertFalse(completedReasoning.isStreaming)
        XCTAssertEqual(
            Array(completedReasoning.text.utf8),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(
            Array(rows.map(\.sourceText).joined().utf8),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)
        XCTAssertEqual(store.projectionDiagnostics.preparedCompletionAdoptions, 1)
        XCTAssertFalse(
            capturedReasoning.isTextStorageMaterialized,
            "Detached completion must not flatten the previous streamed storage."
        )
    }

    func testAuthoritativeToolCompletionAdoptsPreparedItemAndRows() async throws {
        let chunk = String(repeating: "tool-output-0123456789", count: 190) + "\n"
        let chunkCount = 128
        let streamedSource = String(repeating: chunk, count: chunkCount) + "\u{00E9}"
        let authoritativeSource = String(repeating: chunk, count: chunkCount)
            + "e\u{0301}"

        let store = ConversationStore(streamingPublishNanoseconds: 0)
        store.setTranscriptLiveScrolling(true)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "large-tool-completion",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Original command"),
                    "status": .string("running"),
                    "input": .string("original input"),
                    "output": .string(""),
                ])
            )
        )
        for offset in 0..<chunkCount {
            try store.apply(
                ChatTestFixtures.event(
                    "tool.updated",
                    sequence: Int64(offset + 2),
                    itemID: "large-tool-completion",
                    turnID: "turn",
                    payload: .object([
                        "kind": .string("shell"),
                        "title": .string("Original command"),
                        "status": .string("running"),
                        "outputDelta": .string(chunk),
                    ])
                )
            )
        }
        try store.apply(
            ChatTestFixtures.event(
                "tool.updated",
                sequence: Int64(chunkCount + 2),
                itemID: "large-tool-completion",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Original command"),
                    "status": .string("running"),
                    "outputDelta": .string("\u{00E9}"),
                ])
            )
        )
        guard case .tool(let capturedTool)? = store
            .itemsForTranscriptProjectionPreparation.first else {
            return XCTFail("Expected chunked tool before completion")
        }
        XCTAssertEqual(capturedTool.outputUTF8Count, streamedSource.utf8.count)
        XCTAssertFalse(capturedTool.isOutputStorageMaterialized)

        let completion = ChatTestFixtures.event(
            "tool.completed",
            sequence: Int64(chunkCount + 3),
            itemID: "large-tool-completion",
            turnID: "turn",
            payload: .object([
                "title": .string("Completed command"),
                "output": .string(authoritativeSource),
                "error": .string("command failed"),
                "durationMs": .number(42),
                "exitCode": .number(7),
            ])
        )
        let reducerPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: completion,
                retaining: .tool(capturedTool)
            )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: completion,
            retaining: store.itemsForTranscriptProjectionPreparation,
            preparedReducerPayload: reducerPayload
        )
        XCTAssertNotNil(prepared["large-tool-completion"])

        try store.apply(
            completion,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: reducerPayload
        )
        store.setTranscriptLiveScrolling(false)

        let completedTool = try XCTUnwrap(store.state.tools.first)
        let rows = store.transcriptProjections(for: store.state.items[0])
        XCTAssertEqual(completedTool.kind, .shell)
        XCTAssertEqual(completedTool.title, "Completed command")
        XCTAssertEqual(completedTool.status, .failed)
        XCTAssertEqual(completedTool.input, "original input")
        XCTAssertEqual(completedTool.durationMilliseconds, 42)
        XCTAssertEqual(completedTool.exitCode, 7)
        XCTAssertEqual(
            Array(try XCTUnwrap(completedTool.output).utf8),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(
            Array(
                rows.filter { $0.section == .toolOutput }
                    .map(\.sourceText).joined().utf8
            ),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)
        XCTAssertEqual(store.projectionDiagnostics.preparedCompletionAdoptions, 1)
        XCTAssertFalse(
            capturedTool.isOutputStorageMaterialized,
            "Detached completion must not flatten the previous streamed output."
        )
    }

    func testCumulativeToolUpdateAdoptsPreparedItemWithReducerDefaults() async throws {
        let chunk = String(repeating: "compat-output-0123456789", count: 175) + "\n"
        let chunkCount = 128
        let streamedSource = String(repeating: chunk, count: chunkCount)
        let authoritativeSource = streamedSource + "authoritative replacement"

        let store = ConversationStore(streamingPublishNanoseconds: 0)
        store.setTranscriptLiveScrolling(true)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "compat-tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("search"),
                    "title": .string("Original search"),
                    "status": .string("running"),
                    "input": .string("search input"),
                    "output": .string(""),
                ])
            )
        )
        for offset in 0..<chunkCount {
            try store.apply(
                ChatTestFixtures.event(
                    "tool.updated",
                    sequence: Int64(offset + 2),
                    itemID: "compat-tool",
                    turnID: "turn",
                    payload: .object([
                        "kind": .string("search"),
                        "title": .string("Original search"),
                        "status": .string("running"),
                        "outputDelta": .string(chunk),
                    ])
                )
            )
        }
        guard case .tool(let capturedTool)? = store
            .itemsForTranscriptProjectionPreparation.first else {
            return XCTFail("Expected chunked compatibility tool")
        }
        XCTAssertEqual(capturedTool.outputUTF8Count, streamedSource.utf8.count)
        XCTAssertFalse(capturedTool.isOutputStorageMaterialized)

        let deltaOnly = ChatTestFixtures.event(
            "tool.updated",
            sequence: Int64(chunkCount + 1),
            itemID: "compat-tool",
            turnID: "turn",
            payload: .object(["outputDelta": .string("ordinary delta")])
        )
        let deltaOnlyPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: deltaOnly,
                retaining: .tool(capturedTool)
            )
        XCTAssertNil(
            deltaOnlyPayload,
            "Output deltas must remain on the bounded incremental path."
        )

        let update = ChatTestFixtures.event(
            "tool.updated",
            sequence: Int64(chunkCount + 2),
            itemID: "compat-tool",
            turnID: "turn",
            payload: .object([
                "output": .string(authoritativeSource),
                "outputDelta": .string("must not override cumulative output"),
            ])
        )
        let reducerPayload = await ConversationStore
            .prepareAuthoritativeReducerPayload(
                for: update,
                retaining: .tool(capturedTool)
            )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: update,
            retaining: store.itemsForTranscriptProjectionPreparation,
            preparedReducerPayload: reducerPayload
        )
        XCTAssertNotNil(prepared["compat-tool"])

        try store.apply(
            update,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: reducerPayload
        )
        store.setTranscriptLiveScrolling(false)

        let updatedTool = try XCTUnwrap(store.state.tools.first)
        let rows = store.transcriptProjections(for: store.state.items[0])
        XCTAssertEqual(updatedTool.kind, .search)
        XCTAssertEqual(updatedTool.title, "Agent activity")
        XCTAssertEqual(updatedTool.status, .running)
        XCTAssertEqual(updatedTool.input, "search input")
        XCTAssertEqual(
            Array(try XCTUnwrap(updatedTool.output).utf8),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(
            Array(
                rows.filter { $0.section == .toolOutput }
                    .map(\.sourceText).joined().utf8
            ),
            Array(authoritativeSource.utf8)
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)
        XCTAssertEqual(store.projectionDiagnostics.preparedCompletionAdoptions, 1)
        XCTAssertFalse(
            capturedTool.isOutputStorageMaterialized,
            "Cumulative compatibility adoption must not flatten streamed output."
        )
    }

    func testInvalidPreparedTranscriptAuthorityDoesNotAdvanceSequence() throws {
        let events: [ChatEnvelope] = [
            ChatTestFixtures.event(
                "reasoning.completed",
                sequence: 2,
                itemID: "item",
                payload: .object(["text": .string("authoritative")])
            ),
            ChatTestFixtures.event(
                "tool.completed",
                sequence: 2,
                itemID: "item",
                payload: .object(["output": .string("authoritative")])
            ),
            ChatTestFixtures.event(
                "tool.updated",
                sequence: 2,
                itemID: "item",
                payload: .object(["output": .string("authoritative")])
            ),
        ]

        for event in events {
            let original = ConversationItem.message(
                ChatMessage(id: "item", role: .assistant, text: "original")
            )
            let store = ConversationStore()
            store.replaceWithSnapshot(
                ConversationSnapshot(
                    snapshotGeneration: ChatTestFixtures.generation,
                    baseSequence: 1,
                    items: [original]
                )
            )

            XCTAssertThrowsError(
                try store.apply(event, preparedReducerPayload: .invalid),
                "\(event.type) must reject failed detached preparation."
            )
            XCTAssertEqual(store.lastAppliedSequence, 1)
            XCTAssertEqual(store.state.items, [original])
        }
    }

    func testLargeStartedAndReplacementEventsPublishPreparedRowsWithoutMainActorBuild() async throws {
        let source = String(repeating: "prepared-event-line-0123456789\n", count: 4_000)
        let fixtures: [(ChatEnvelope, String)] = [
            (
                ChatTestFixtures.event(
                    "message.started",
                    sequence: 1,
                    itemID: "message",
                    turnID: "turn",
                    payload: .object([
                        "role": .string("assistant"),
                        "text": .string(source),
                    ])
                ),
                "message"
            ),
            (
                ChatTestFixtures.event(
                    "tool.started",
                    sequence: 1,
                    itemID: "tool",
                    turnID: "turn",
                    payload: .object([
                        "kind": .string("shell"),
                        "title": .string("Command"),
                        "status": .string("running"),
                        "input": .string(source),
                    ])
                ),
                "tool"
            ),
            (
                ChatTestFixtures.event(
                    "diff.updated",
                    sequence: 1,
                    itemID: "diff",
                    turnID: "turn",
                    payload: .object([
                        "path": .string("Example.swift"),
                        "diff": .string(source),
                    ])
                ),
                "diff"
            ),
        ]

        for (envelope, expectedID) in fixtures {
            let store = ConversationStore(streamingPublishNanoseconds: 0)
            let prepared = await ConversationStore.prepareTranscriptProjections(
                for: envelope,
                retaining: store.itemsForTranscriptProjectionPreparation,
                currentState: store.stateForTranscriptProjectionPreparation
            )
            XCTAssertNotNil(
                prepared[expectedID],
                "Every large start/replacement event must be projected off-main."
            )

            try store.apply(
                envelope,
                preparedTranscriptProjections: prepared
            )
            let item = try XCTUnwrap(store.state.items.first)
            let rows = store.transcriptProjections(for: item)

            XCTAssertEqual(item.id, expectedID)
            XCTAssertGreaterThan(rows.count, 1)
            XCTAssertEqual(rows.map(\.sourceText).joined(), source)
            XCTAssertEqual(
                store.projectionDiagnostics.fullItemBuilds,
                0,
                "The first visible request must adopt the detached projection."
            )
        }
    }

    func testAuthoritativeToolReplacementPublishesPreparedRowsWithoutMainActorBuild() async throws {
        let initial = String(repeating: "initial-output\n", count: 2_000)
        let replacement = String(repeating: "replacement-output\n", count: 4_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "output": .string(initial),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let fullBuilds = store.projectionDiagnostics.fullItemBuilds
        let update = ChatTestFixtures.event(
            "tool.updated",
            sequence: 2,
            itemID: "tool",
            turnID: "turn",
            payload: .object([
                "kind": .string("shell"),
                "title": .string("Command"),
                "status": .string("running"),
                "output": .string(replacement),
            ])
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: update,
            retaining: store.itemsForTranscriptProjectionPreparation,
            currentState: store.stateForTranscriptProjectionPreparation
        )

        try store.apply(update, preparedTranscriptProjections: prepared)
        store.flushStreamingUpdates()
        let rows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )

        XCTAssertEqual(rows.map(\.sourceText).joined(), replacement)
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, fullBuilds)
    }

    func testPureToolOutputDeltaKeepsIncrementalTailProjectionPath() async throws {
        let prefix = String(repeating: "sealed-output\n", count: 2_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "output": .string(prefix),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let update = ChatTestFixtures.event(
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
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: update,
            retaining: store.itemsForTranscriptProjectionPreparation,
            currentState: store.stateForTranscriptProjectionPreparation
        )

        XCTAssertTrue(
            prepared.isEmpty,
            "A compatible append must preserve the bounded mutable-tail path."
        )
        try store.apply(update, preparedTranscriptProjections: prepared)
        store.flushStreamingUpdates()
        let rows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        XCTAssertEqual(
            rows.filter { $0.section == .toolOutput }.map(\.sourceText).joined(),
            prefix + "tail"
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 1)
        XCTAssertEqual(store.projectionDiagnostics.incrementalTailBuilds, 1)
    }

    func testTerminalFailurePreparesLargeToolWithoutOutputBeforePublication() async throws {
        let input = String(repeating: "long-command-argument\n", count: 4_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(input),
                ])
            )
        )
        _ = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )
        let fullBuilds = store.projectionDiagnostics.fullItemBuilds
        let terminal = ChatTestFixtures.event(
            "turn.failed",
            sequence: 2,
            turnID: "turn",
            payload: .object(["message": .string("Failed")])
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: terminal,
            retaining: store.itemsForTranscriptProjectionPreparation,
            currentState: store.stateForTranscriptProjectionPreparation
        )
        XCTAssertNotNil(prepared["tool"])

        try store.apply(terminal, preparedTranscriptProjections: prepared)
        let rows = store.transcriptProjections(
            for: try XCTUnwrap(store.state.items.first)
        )

        XCTAssertEqual(store.state.tools.first?.status, .failed)
        XCTAssertEqual(rows.map(\.sourceText).joined(), input)
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            fullBuilds,
            "Terminal metadata must not rebuild a large tool on the main actor."
        )
    }

    func testSnapshotProjectionIsPreparedBeforePublishedRowsAreRequested() async throws {
        let source = String(repeating: "snapshot-line-0123456789\n", count: 20_000)
        let item = ConversationItem.message(
            ChatMessage(id: "large-snapshot", role: .assistant, text: source)
        )
        let store = ConversationStore()

        let envelope = try ChatTestFixtures.snapshotEvent(
            baseSequence: 1,
            items: [item]
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope
        )
        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared
        )

        let publishedItem = try XCTUnwrap(store.state.items.first)
        let rows = store.transcriptProjections(for: publishedItem)
        XCTAssertGreaterThan(rows.count, 100)
        XCTAssertEqual(rows.map(\.sourceText).joined(), source)
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            0,
            "The first SwiftUI section evaluation must hit off-main prepared rows."
        )
    }

    func testPreparingReplacementSnapshotLeavesPublishedProjectionCacheIntact() async throws {
        let oldSource = String(repeating: "old\n", count: 80_000)
        let newSource = String(repeating: "new\n", count: 100_000)
        let oldItem = ConversationItem.message(
            ChatMessage(id: "old-snapshot", role: .assistant, text: oldSource)
        )
        let newItem = ConversationItem.message(
            ChatMessage(id: "new-snapshot", role: .assistant, text: newSource)
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [oldItem]
            )
        )
        let publishedOldItem = try XCTUnwrap(store.state.items.first)
        XCTAssertEqual(
            store.transcriptProjections(for: publishedOldItem).map(\.sourceText).joined(),
            oldSource
        )
        let buildsBeforePreparation = store.projectionDiagnostics.fullItemBuilds

        let envelope = try ChatTestFixtures.snapshotEvent(
            baseSequence: 2,
            items: [newItem]
        )
        let preparation = Task {
            await ConversationStore.prepareTranscriptProjections(for: envelope)
        }
        await Task.yield()
        store.jumpToLatest()
        XCTAssertEqual(
            store.transcriptProjections(for: publishedOldItem).map(\.sourceText).joined(),
            oldSource
        )
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            buildsBeforePreparation,
            "Preparing B must not invalidate the still-published projection cache for A."
        )

        let prepared = await preparation.value
        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared
        )
        let publishedNewItem = try XCTUnwrap(store.state.items.first)
        XCTAssertEqual(
            store.transcriptProjections(for: publishedNewItem).map(\.sourceText).joined(),
            newSource
        )
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            buildsBeforePreparation
        )
    }

    func testPreparedHistoryCannotReplaceAnExistingIDWithConflictingContent() async throws {
        let kept = ConversationItem.message(
            ChatMessage(id: "kept", role: .assistant, text: "authoritative-current")
        )
        let conflicting = ConversationItem.message(
            ChatMessage(id: "kept", role: .assistant, text: "stale-history-copy")
        )
        let older = ConversationItem.message(
            ChatMessage(id: "older", role: .assistant, text: "older")
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [kept],
                hasOlderHistory: true,
                oldestItemID: "kept"
            )
        )
        _ = store.transcriptProjections(for: kept)
        let buildsBefore = store.projectionDiagnostics.fullItemBuilds
        let envelope = ChatTestFixtures.event(
            "history.page",
            sequence: 2,
            payload: .object([
                "items": .array([
                    try JSONValue.encoded(older),
                    try JSONValue.encoded(conflicting),
                ]),
                "hasOlderHistory": .bool(false),
                "oldestItemId": .string("older"),
            ])
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope,
            retaining: store.state.items
        )

        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared
        )

        XCTAssertEqual(store.state.items.map(\.id), ["older", "kept"])
        let retained = try XCTUnwrap(store.state.items.last)
        XCTAssertEqual(
            store.transcriptProjections(for: retained).map(\.sourceText).joined(),
            "authoritative-current"
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, buildsBefore)
    }

    func testPreparedSnapshotUsesTheReducersFirstDuplicateItem() async throws {
        let first = ConversationItem.message(
            ChatMessage(id: "duplicate", role: .assistant, text: "first")
        )
        let last = ConversationItem.message(
            ChatMessage(id: "duplicate", role: .assistant, text: "last")
        )
        let store = ConversationStore()
        let envelope = try ChatTestFixtures.snapshotEvent(
            baseSequence: 1,
            items: [first, last]
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope
        )

        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared
        )

        let adopted = try XCTUnwrap(store.state.items.first)
        XCTAssertEqual(store.state.items.count, 1)
        XCTAssertEqual(
            store.transcriptProjections(for: adopted).map(\.sourceText).joined(),
            "first"
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, 0)
    }

    func testPreparedAuthoritativePayloadsApplyWithoutMainActorJSONDecode() throws {
        let snapshotItem = ConversationItem.message(
            ChatMessage(id: "prepared-snapshot", role: .assistant, text: "snapshot")
        )
        let snapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 1,
            items: [snapshotItem]
        )
        let snapshotStore = ConversationStore()
        try snapshotStore.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 1,
                payload: .string("intentionally not a snapshot")
            ),
            preparedReducerPayload: .conversationSnapshot(snapshot)
        )
        XCTAssertEqual(snapshotStore.state.items, [snapshotItem])
        let preservedRevision = snapshotStore.transcriptItemContentRevision(
            for: snapshotItem.id
        )
        let repeatedSnapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 2,
            items: [snapshotItem]
        )
        try snapshotStore.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 2,
                payload: .string("prepared repeated snapshot")
            ),
            preparedReducerPayload: .conversationSnapshot(repeatedSnapshot),
            preservedSnapshotItemIDs: [snapshotItem.id]
        )
        XCTAssertEqual(
            snapshotStore.transcriptItemContentRevision(for: snapshotItem.id),
            preservedRevision
        )

        let current = ConversationItem.message(
            ChatMessage(id: "current", role: .assistant, text: "current")
        )
        let older = ConversationItem.message(
            ChatMessage(id: "older", role: .assistant, text: "older")
        )
        let historyStore = ConversationStore()
        historyStore.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [current],
                hasOlderHistory: true,
                oldestItemID: current.id
            )
        )
        try historyStore.apply(
            ChatTestFixtures.event(
                "history.page",
                sequence: 2,
                payload: .object([
                    "items": .string("intentionally not an item array"),
                    "hasOlderHistory": .bool(false),
                    "oldestItemId": .string(older.id),
                ])
            ),
            preparedReducerPayload: .historyPage([older])
        )
        XCTAssertEqual(historyStore.state.items.map(\.id), [older.id, current.id])
        XCTAssertFalse(historyStore.state.hasOlderHistory)
    }

    func testInvalidPreparedHistoryDoesNotAdvanceDurableCursor() throws {
        let current = ConversationItem.message(
            ChatMessage(id: "current", role: .assistant, text: "current")
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [current]
            )
        )

        XCTAssertThrowsError(
            try store.apply(
                ChatTestFixtures.event(
                    "history.page",
                    sequence: 2,
                    payload: .object(["items": .string("invalid")])
                ),
                preparedReducerPayload: .invalid
            )
        )
        XCTAssertEqual(store.lastAppliedSequence, 1)
        XCTAssertEqual(store.snapshotGeneration, ChatTestFixtures.generation)
        XCTAssertEqual(store.state.items, [current])
    }

    func testPreparedSnapshotDoesNotCompareOrMaterializePreviousLargeText() throws {
        let chunk = String(repeating: "z", count: 1_024)
        let deltaCount = 8
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        store.setTranscriptLiveScrolling(true)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "large-message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(""),
                ])
            )
        )
        for sequence in 2...(deltaCount + 1) {
            try store.apply(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: Int64(sequence),
                    itemID: "large-message",
                    turnID: "turn",
                    payload: .object(["text": .string(chunk)])
                )
            )
        }
        guard case .message(let previousMessage)? = store
            .stateForTranscriptProjectionPreparation.items.first,
              let previousContent = previousMessage.contents.first else {
            return XCTFail("Expected the working streaming message")
        }
        XCTAssertFalse(previousContent.isTextStorageMaterialized)

        let replacement = ConversationItem.message(
            ChatMessage(
                id: "large-message",
                turnID: "turn",
                role: .assistant,
                text: String(repeating: chunk, count: deltaCount),
                occurredAt: 1,
                isStreaming: true
            )
        )
        let snapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: Int64(deltaCount + 1),
            items: [replacement],
            connectionState: .streaming,
            turnState: .running,
            activeTurnID: "turn"
        )
        try store.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: snapshot.baseSequence,
                payload: .string("prepared payload must bypass this JSON")
            ),
            preparedReducerPayload: .conversationSnapshot(snapshot),
            preservedSnapshotItemIDs: ["large-message"]
        )

        XCTAssertFalse(
            previousContent.isTextStorageMaterialized,
            "Adopting an authoritative snapshot must not compare its text with the old transcript."
        )
    }

    func testPreparedSnapshotDoesNotPreserveCanonicallyEqualDifferentBytes() async throws {
        let oldText = "\u{00E9}"
        let authoritativeText = "e\u{0301}"
        let oldItem = ConversationItem.message(
            ChatMessage(id: "unicode-message", role: .assistant, text: oldText)
        )
        let authoritativeItem = ConversationItem.message(
            ChatMessage(
                id: "unicode-message",
                role: .assistant,
                text: authoritativeText
            )
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [oldItem]
            )
        )
        _ = store.transcriptProjections(for: oldItem)
        let oldRevision = store.transcriptItemContentRevision(for: oldItem.id)
        // The cursor jump keeps this snapshot on the authoritative-replace
        // path instead of the continuous no-op path.
        let snapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 3,
            items: [authoritativeItem]
        )
        let payload = PreparedConversationReducerPayload.conversationSnapshot(snapshot)
        let preserved = await ConversationStore.preparePreservedSnapshotItemIDs(
            for: payload,
            retaining: store.state.items,
            currentState: store.stateForTranscriptProjectionPreparation
        )
        XCTAssertFalse(preserved.contains(oldItem.id))

        let envelope = ChatTestFixtures.event(
            "conversation.snapshot",
            sequence: 3,
            payload: .string("prepared payload must bypass this JSON")
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope,
            retaining: store.state.items,
            currentState: store.stateForTranscriptProjectionPreparation,
            preparedReducerPayload: payload,
            preservingSnapshotItemIDs: preserved
        )
        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: payload,
            preservedSnapshotItemIDs: preserved
        )

        let applied = try XCTUnwrap(store.state.items.first)
        guard case .message(let appliedMessage) = applied else {
            return XCTFail("Expected authoritative message")
        }
        let appliedText = appliedMessage.text
        let projectedText = store.transcriptProjections(for: applied)
            .map(\.sourceText)
            .joined()
        XCTAssertEqual(Array(appliedText.utf8), Array(authoritativeText.utf8))
        XCTAssertEqual(Array(projectedText.utf8), Array(authoritativeText.utf8))
        XCTAssertNotEqual(
            store.transcriptItemContentRevision(for: oldItem.id),
            oldRevision
        )
    }

    func testPreparedSnapshotDoesNotPreserveGenericCanonicalByteChange() async throws {
        let oldText = "\u{00E9}"
        let authoritativeText = "e\u{0301}"
        let oldItem = ConversationItem.generic(
            ChatGenericItem(
                id: "unicode-generic",
                turnID: nil,
                type: "activity",
                title: "Status",
                detail: oldText,
                occurredAt: nil
            )
        )
        let authoritativeItem = ConversationItem.generic(
            ChatGenericItem(
                id: "unicode-generic",
                turnID: nil,
                type: "activity",
                title: "Status",
                detail: authoritativeText,
                occurredAt: nil
            )
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [oldItem]
            )
        )
        _ = store.transcriptProjections(for: oldItem)
        // The cursor jump keeps this snapshot on the authoritative-replace
        // path instead of the continuous no-op path.
        let snapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 3,
            items: [authoritativeItem]
        )
        let payload = PreparedConversationReducerPayload.conversationSnapshot(snapshot)
        let preserved = await ConversationStore.preparePreservedSnapshotItemIDs(
            for: payload,
            retaining: store.state.items,
            currentState: store.stateForTranscriptProjectionPreparation
        )
        XCTAssertFalse(preserved.contains(oldItem.id))

        let envelope = ChatTestFixtures.event(
            "conversation.snapshot",
            sequence: 3,
            payload: .string("prepared payload must bypass this JSON")
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope,
            retaining: store.state.items,
            currentState: store.stateForTranscriptProjectionPreparation,
            preparedReducerPayload: payload,
            preservingSnapshotItemIDs: preserved
        )
        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: payload,
            preservedSnapshotItemIDs: preserved
        )

        let applied = try XCTUnwrap(store.state.items.first)
        guard case .generic(let generic) = applied else {
            return XCTFail("Expected authoritative generic item")
        }
        let projectedText = store.transcriptProjections(for: applied)
            .map(\.sourceText)
            .joined()
        XCTAssertEqual(Array(generic.detail?.utf8 ?? "".utf8), Array(authoritativeText.utf8))
        XCTAssertEqual(Array(projectedText.utf8), Array(authoritativeText.utf8))
    }

    func testContinuousCoveringSnapshotKeepsPaintedTranscriptWithoutReset() async throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        for (sequence, text) in [(Int64(1), "First"), (2, "Second")] {
            try store.apply(
                ChatTestFixtures.event(
                    "message.completed",
                    sequence: sequence,
                    itemID: "message-\(sequence)",
                    turnID: "turn-1",
                    payload: .object([
                        "role": .string("assistant"),
                        "text": .string(text),
                    ])
                )
            )
        }
        let optimistic = ConversationStore.optimisticUserMessage(
            requestID: "00000000-0000-4000-8000-0000000000aa",
            text: "Pending send",
            occurredAt: 3
        )
        store.addOptimisticUserMessage(
            optimistic,
            preparedTranscriptProjections: await ConversationStore
                .prepareTranscriptProjections(for: [optimistic])
        )
        let paintedItems = store.state.items
        let mutationBefore = store.transcriptMutation
        let revisionBefore = store.transcriptContentRevision
        let itemRevisionBefore = store.transcriptItemContentRevision(
            for: "message-1"
        )

        // A peer attach without a valid replay cursor broadcasts this rebuilt
        // snapshot into every attached client. It may restate older items this
        // client no longer retains and cannot contain the optimistic message.
        let olderItem = ConversationItem.message(
            ChatMessage(id: "older-history", role: .assistant, text: "older")
        )
        let snapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 3,
            items: [olderItem, paintedItems[0], paintedItems[1]]
        )
        let payload = PreparedConversationReducerPayload
            .conversationSnapshot(snapshot)
        let currentState = store.stateForTranscriptProjectionPreparation
        let preserved = await ConversationStore.preparePreservedSnapshotItemIDs(
            for: payload,
            retaining: currentState.items,
            currentState: currentState
        )
        XCTAssertEqual(preserved, Set(paintedItems.map(\.id)))
        let envelope = ChatTestFixtures.event(
            "conversation.snapshot",
            sequence: 3,
            payload: .string("prepared payload must bypass this JSON")
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope,
            retaining: currentState.items,
            currentState: currentState,
            preparedReducerPayload: payload,
            preservingSnapshotItemIDs: preserved
        )
        XCTAssertTrue(prepared.isEmpty)

        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: payload,
            preservedSnapshotItemIDs: preserved
        )

        XCTAssertEqual(store.state.lastAppliedSequence, 3)
        XCTAssertEqual(store.state.items, paintedItems)
        XCTAssertEqual(store.transcriptContentRevision, revisionBefore)
        XCTAssertEqual(
            store.transcriptItemContentRevision(for: "message-1"),
            itemRevisionBefore
        )
        XCTAssertEqual(
            store.transcriptMutation,
            mutationBefore,
            "A continuous covering snapshot must not rebuild the transcript."
        )

        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 4,
                itemID: "message-4",
                turnID: "turn-1",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("Third"),
                ])
            )
        )
        XCTAssertEqual(store.state.lastAppliedSequence, 4)
        XCTAssertTrue(store.state.items.contains { $0.id == "message-4" })
    }

    func testSnapshotThatShedsAPaintedItemStillResetsAuthoritatively() async throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        for (sequence, text) in [(Int64(1), "First"), (2, "Second")] {
            try store.apply(
                ChatTestFixtures.event(
                    "message.completed",
                    sequence: sequence,
                    itemID: "message-\(sequence)",
                    turnID: "turn-1",
                    payload: .object([
                        "role": .string("assistant"),
                        "text": .string(text),
                    ])
                )
            )
        }
        let kept = store.state.items[1]
        let mutationBefore = store.transcriptMutation

        // Continuous cursor, but the broadcast shed "message-1" to fit the
        // record limit: the rebuild must stay an authoritative reset.
        let snapshot = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 3,
            items: [kept],
            hasOlderHistory: true,
            oldestItemID: kept.id
        )
        let payload = PreparedConversationReducerPayload
            .conversationSnapshot(snapshot)
        let currentState = store.stateForTranscriptProjectionPreparation
        let preserved = await ConversationStore.preparePreservedSnapshotItemIDs(
            for: payload,
            retaining: currentState.items,
            currentState: currentState
        )
        try store.apply(
            ChatTestFixtures.event(
                "conversation.snapshot",
                sequence: 3,
                payload: .string("prepared payload must bypass this JSON")
            ),
            preparedReducerPayload: payload,
            preservedSnapshotItemIDs: preserved
        )

        XCTAssertEqual(store.state.items, [kept])
        XCTAssertTrue(store.state.hasOlderHistory)
        XCTAssertNotEqual(store.transcriptMutation, mutationBefore)
        XCTAssertTrue(store.transcriptMutation.isAuthoritativeReset)
    }

    func testSnapshotWithCursorJumpOrForeignGenerationResetsAuthoritatively() async throws {
        for (baseSequence, generation) in [
            (Int64(4), ChatTestFixtures.generation),
            (3, "00000000-0000-4000-8000-0000000000ff"),
        ] {
            let store = ConversationStore(streamingPublishNanoseconds: 0)
            for (sequence, text) in [(Int64(1), "First"), (2, "Second")] {
                try store.apply(
                    ChatTestFixtures.event(
                        "message.completed",
                        sequence: sequence,
                        itemID: "message-\(sequence)",
                        turnID: "turn-1",
                        payload: .object([
                            "role": .string("assistant"),
                            "text": .string(text),
                        ])
                    )
                )
            }
            let snapshot = ConversationSnapshot(
                snapshotGeneration: generation,
                baseSequence: baseSequence,
                items: store.state.items
            )
            let payload = PreparedConversationReducerPayload
                .conversationSnapshot(snapshot)
            try store.apply(
                ChatTestFixtures.event(
                    "conversation.snapshot",
                    sequence: baseSequence,
                    payload: .string("prepared payload must bypass this JSON"),
                    snapshotGeneration: generation
                ),
                preparedReducerPayload: payload
            )
            XCTAssertTrue(
                store.transcriptMutation.isAuthoritativeReset,
                "A non-continuous snapshot must remain an authoritative reset."
            )
            XCTAssertEqual(store.state.lastAppliedSequence, baseSequence)
            XCTAssertEqual(store.state.snapshotGeneration, generation)
        }
    }

    func testMessageCompletionDoesNotMaterializeChunkedStreamingText() throws {
        let chunk = String(repeating: "z", count: 1_024)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        store.setTranscriptLiveScrolling(true)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn"
            )
        )
        for sequence in 2...9 {
            try store.apply(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: Int64(sequence),
                    itemID: "message",
                    turnID: "turn",
                    payload: .object(["text": .string(chunk)])
                )
            )
        }
        guard case .message(let streaming)? = store
            .stateForTranscriptProjectionPreparation.items.first,
              let capturedContent = streaming.contents.first else {
            return XCTFail("Expected a streaming message")
        }
        XCTAssertFalse(capturedContent.isTextStorageMaterialized)

        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 10,
                itemID: "message",
                turnID: "turn"
            )
        )
        XCTAssertFalse(capturedContent.isTextStorageMaterialized)
    }

    func testConnectingPlaceholderPreservesPublishedRowsWithoutReprojection() async throws {
        let source = String(repeating: "painted\n", count: 10_000)
        let item = ConversationItem.message(
            ChatMessage(id: "painted", role: .assistant, text: source)
        )
        let store = ConversationStore()
        store.replaceWithSnapshot(
            ConversationSnapshot(
                snapshotGeneration: ChatTestFixtures.generation,
                baseSequence: 1,
                items: [item]
            )
        )
        _ = store.transcriptProjections(for: item)
        let buildsBefore = store.projectionDiagnostics.fullItemBuilds
        let placeholder = ConversationSnapshot(
            snapshotGeneration: ChatTestFixtures.generation,
            baseSequence: 2,
            items: [],
            connectionState: .connecting
        )
        let envelope = ChatTestFixtures.event(
            "conversation.snapshot",
            sequence: 2,
            payload: try JSONValue.encoded(placeholder)
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: envelope,
            retaining: store.state.items,
            preparedReducerPayload: .conversationSnapshot(placeholder),
            preservingSnapshotItemIDs: [item.id]
        )
        let contentRevisionBefore = store.transcriptContentRevision
        let mutationBefore = store.transcriptMutation
        let itemRevisionBefore = store.transcriptItemContentRevision(for: item.id)
        XCTAssertTrue(prepared.isEmpty)

        try store.apply(
            envelope,
            preparedTranscriptProjections: prepared,
            preparedReducerPayload: .conversationSnapshot(placeholder),
            preservedSnapshotItemIDs: [item.id]
        )

        let retained = try XCTUnwrap(store.state.items.first)
        XCTAssertEqual(
            store.transcriptProjections(for: retained).map(\.sourceText).joined(),
            source
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, buildsBefore)
        XCTAssertEqual(store.transcriptContentRevision, contentRevisionBefore)
        XCTAssertEqual(store.transcriptMutation, mutationBefore)
        XCTAssertEqual(
            store.transcriptItemContentRevision(for: item.id),
            itemRevisionBefore
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

    func testPreparedReplacementCannotGetAheadOfPublishedRowsDuringLiveScroll() async throws {
        let oldSource = String(repeating: "published-before-scroll\n", count: 2_000)
        let newSource = String(repeating: "prepared-during-scroll\n", count: 3_000)
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(oldSource),
                ])
            )
        )
        let oldItem = try XCTUnwrap(store.state.items.first)
        XCTAssertEqual(
            store.transcriptProjections(for: oldItem).map(\.sourceText).joined(),
            oldSource
        )
        let fullBuilds = store.projectionDiagnostics.fullItemBuilds

        store.setTranscriptLiveScrolling(true)
        let completion = ChatTestFixtures.event(
            "message.completed",
            sequence: 2,
            itemID: "message",
            turnID: "turn",
            payload: .object([
                "role": .string("assistant"),
                "text": .string(newSource),
            ])
        )
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: completion,
            retaining: store.itemsForTranscriptProjectionPreparation,
            currentState: store.stateForTranscriptProjectionPreparation
        )
        try store.apply(
            completion,
            preparedTranscriptProjections: prepared
        )

        XCTAssertEqual(store.state.lastAppliedSequence, 1)
        XCTAssertEqual(store.state.messages.first?.text, oldSource)
        XCTAssertEqual(
            store.transcriptProjections(for: oldItem).map(\.sourceText).joined(),
            oldSource,
            "Prepared rows for working state must not replace the frozen published cache."
        )
        XCTAssertEqual(store.projectionDiagnostics.fullItemBuilds, fullBuilds)

        store.setTranscriptLiveScrolling(false)

        let newItem = try XCTUnwrap(store.state.items.first)
        XCTAssertEqual(store.state.lastAppliedSequence, 2)
        XCTAssertEqual(
            store.transcriptProjections(for: newItem).map(\.sourceText).joined(),
            newSource
        )
        XCTAssertEqual(
            store.projectionDiagnostics.fullItemBuilds,
            fullBuilds,
            "The catch-up publication must atomically adopt its detached rows."
        )
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
        let optimisticItem = ConversationStore.optimisticUserMessage(
            requestID: requestID,
            text: "Start another turn",
            occurredAt: 0
        )
        store.addOptimisticUserMessage(
            optimisticItem,
            preparedTranscriptProjections: [:]
        )

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

    func testNearLimitStreamsAppendChunksWithoutMaterializingAccumulatedText() throws {
        let chunk = String(repeating: "z", count: 1_024)
        let deltaCount = 900
        let expectedUTF8Count = chunk.utf8.count * deltaCount
        let maximumChunkCount = (expectedUTF8Count + (4 * 1_024) - 1) / (4 * 1_024)

        let messageStore = ConversationStore(streamingPublishNanoseconds: 0)
        messageStore.setTranscriptLiveScrolling(true)
        try messageStore.apply(
            ChatTestFixtures.event(
                "message.started",
                sequence: 1,
                itemID: "chunked-message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(""),
                ])
            )
        )
        for sequence in 2...(deltaCount + 1) {
            try messageStore.apply(
                ChatTestFixtures.event(
                    "message.delta",
                    sequence: Int64(sequence),
                    itemID: "chunked-message",
                    turnID: "turn",
                    payload: .object(["text": .string(chunk)])
                )
            )
        }
        guard case .message(let message)? = messageStore
            .stateForTranscriptProjectionPreparation.items.first,
              let content = message.contents.first else {
            return XCTFail("Expected the working streaming message")
        }
        XCTAssertEqual(content.textUTF8Count, expectedUTF8Count)
        XCTAssertLessThanOrEqual(content.textStorageChunkCount, maximumChunkCount)
        XCTAssertFalse(
            content.isTextStorageMaterialized,
            "Applying deltas must not rebuild the accumulated String on the main actor."
        )
        XCTAssertEqual(content.text, String(repeating: chunk, count: deltaCount))

        let toolStore = ConversationStore(streamingPublishNanoseconds: 0)
        toolStore.setTranscriptLiveScrolling(true)
        try toolStore.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "chunked-tool",
                turnID: "turn",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "output": .string(""),
                ])
            )
        )
        for sequence in 2...(deltaCount + 1) {
            try toolStore.apply(
                ChatTestFixtures.event(
                    "tool.updated",
                    sequence: Int64(sequence),
                    itemID: "chunked-tool",
                    turnID: "turn",
                    payload: .object([
                        "kind": .string("shell"),
                        "title": .string("Command"),
                        "status": .string("running"),
                        "outputDelta": .string(chunk),
                    ])
                )
            )
        }
        guard case .tool(let tool)? = toolStore
            .stateForTranscriptProjectionPreparation.items.first else {
            return XCTFail("Expected the working streaming tool")
        }
        XCTAssertEqual(tool.outputUTF8Count, expectedUTF8Count)
        XCTAssertLessThanOrEqual(tool.outputStorageChunkCount, maximumChunkCount)
        XCTAssertFalse(
            tool.isOutputStorageMaterialized,
            "Tool output deltas must remain immutable chunks until exact text is requested."
        )
        XCTAssertEqual(tool.output, String(repeating: chunk, count: deltaCount))
    }

    func testPersistentChatTextCoalescesManySmallDeltasExactly() throws {
        let delta = "🙂"
        let deltaCount = 5_000
        let expectedText = String(repeating: delta, count: deltaCount)
        let expectedUTF8Count = delta.utf8.count * deltaCount
        let maximumChunkCount = (expectedUTF8Count + (4 * 1_024) - 1) / (4 * 1_024)

        var content = MessageContent(id: "small-delta-message", text: "")
        var tool = ToolActivity(
            id: "small-delta-tool",
            turnID: "turn",
            kind: .shell,
            title: "Command",
            status: .running,
            input: nil,
            output: "",
            errorMessage: nil,
            durationMilliseconds: nil,
            exitCode: nil,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        )

        for _ in 0..<deltaCount {
            content.appendText(delta)
            tool.appendOutput(delta)
        }

        XCTAssertEqual(content.textUTF8Count, expectedUTF8Count)
        XCTAssertLessThanOrEqual(content.textStorageChunkCount, maximumChunkCount)
        XCTAssertFalse(content.isTextStorageMaterialized)
        XCTAssertEqual(tool.outputUTF8Count, expectedUTF8Count)
        XCTAssertLessThanOrEqual(tool.outputStorageChunkCount, maximumChunkCount)
        XCTAssertFalse(tool.isOutputStorageMaterialized)

        XCTAssertEqual(content.text, expectedText)
        XCTAssertEqual(tool.output, expectedText)
        XCTAssertTrue(content.isTextStorageMaterialized)
        XCTAssertTrue(tool.isOutputStorageMaterialized)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(MessageContent.self, from: encoder.encode(content)),
            content
        )
        XCTAssertEqual(
            try decoder.decode(ToolActivity.self, from: encoder.encode(tool)),
            tool
        )
    }

    func testPersistentChatTextKeepsLargeInitialValueAsOneMaterializedChunk() {
        let initialText = String(repeating: "initial🙂", count: 1_024)
        let content = MessageContent(id: "initial-message", text: initialText)

        XCTAssertGreaterThan(content.textUTF8Count, 4 * 1_024)
        XCTAssertEqual(content.textStorageChunkCount, 1)
        XCTAssertTrue(content.isTextStorageMaterialized)
        XCTAssertEqual(content.text, initialText)
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
