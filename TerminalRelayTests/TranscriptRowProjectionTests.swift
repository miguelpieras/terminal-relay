import XCTest
@testable import TerminalRelay

final class TranscriptRowProjectionTests: XCTestCase {
    func testProductionTileBudgetsStayViewportSized() {
        XCTAssertEqual(TranscriptRowProjection.maximumDisplayBytes, 1 * 1_024)
        XCTAssertEqual(TranscriptRowProjection.maximumDisplayLines, 128)
    }

    func testNewlineDenseTextUsesABoundedNumberOfRows() {
        let lineCount = 20_000
        let source = String(repeating: "x\n", count: lineCount - 1) + "x"
        let segments = TranscriptTextProjection.segments(of: source)

        XCTAssertEqual(
            segments.count,
            Int(ceil(
                Double(lineCount)
                    / Double(TranscriptRowProjection.maximumDisplayLines - 1)
            ))
        )
        XCTAssertEqual(segments.map(\.text).joined(), source)
    }

    func testSegmentsPreserveEveryByteWithinRenderingBudgets() {
        let source = (0..<2_000)
            .map { "line-\($0) café ☕️" }
            .joined(separator: "\n")
        let segments = TranscriptTextProjection.segments(
            of: source,
            maximumBytes: 1_024,
            maximumLines: 17
        )

        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertEqual(segments.map(\.index), Array(segments.indices))
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.text.utf8.count, 1_024)
            XCTAssertLessThanOrEqual(
                segment.text.utf8.filter { $0 == 0x0A }.count,
                16
            )
            XCTAssertLessThanOrEqual(
                segment.text.split(
                    separator: "\n",
                    omittingEmptySubsequences: false
                ).count,
                17
            )
            XCTAssertNotNil(segment.text.data(using: .utf8))
        }
    }

    func testSegmentsCutOneHugeGraphemeOnlyAtUTF8ScalarBoundaries() {
        let source = "a" + String(repeating: "\u{301}", count: 40_000)
        let segments = TranscriptTextProjection.segments(
            of: source,
            maximumBytes: 1_001,
            maximumLines: 120
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertTrue(segments.allSatisfy { $0.text.utf8.count <= 1_001 })
        XCTAssertTrue(segments.allSatisfy { $0.text.data(using: .utf8) != nil })
    }

    func testMarkdownSegmentsKeepLargeFencedCodeRenderedAsCode() {
        let source = "Before\n```swift\n"
            + String(repeating: "let value = 1\n", count: 300)
            + "```\nAfter"
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 1_024,
            maximumLines: 40
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertGreaterThan(segments.count, 2)
        for segment in segments.dropFirst().dropLast() {
            XCTAssertTrue(segment.renderedText.hasPrefix("```\n"))
            XCTAssertTrue(segment.renderedText.hasSuffix("\n```"))
            XCTAssertLessThanOrEqual(segment.renderedText.utf8.count, 1_024)
            XCTAssertLessThanOrEqual(
                segment.renderedText.utf8.filter { $0 == 0x0A }.count,
                40
            )
        }
    }

    func testLongerMarkdownFenceIgnoresShortAndSuffixedFenceLikeContent() {
        let source = """
        Before
        ````swift
        first
        ```
        # still literal
        ````not-a-close
        * also literal
        ````
        closed
        closed-again
        After
        """
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 160,
            maximumLines: 6
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertGreaterThan(segments.count, 2)
        guard let literalHeading = segments.first(where: {
            $0.text.contains("# still literal")
        }) else {
            return XCTFail("Expected literal heading segment")
        }
        XCTAssertEqual(literalHeading.markdownContinuation?.openFence, "````")
        XCTAssertTrue(literalHeading.renderedText.hasPrefix("````\n"))
        guard let after = segments.first(where: { $0.text.contains("After") }) else {
            return XCTFail("Expected post-fence segment")
        }
        XCTAssertNil(after.markdownContinuation?.openFence)
    }

    func testSubstantiallyLongFenceContinuesAcrossRowsWithinRenderedBudget() throws {
        let fence = String(repeating: "`", count: 80)
        let body = (0..<80).map { "value-\($0)\n" }.joined()
        let source = "Before\n\(fence)\n\(body)\(fence)\nAfter"
        let maximumBytes = 256
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: maximumBytes,
            maximumLines: 8
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertGreaterThan(segments.count, 4)
        XCTAssertTrue(segments.allSatisfy {
            $0.renderedText.utf8.count <= maximumBytes
        })

        let opening = try XCTUnwrap(segments.first(where: {
            $0.text == fence + "\n"
                && $0.markdownContinuation?.openFence == nil
        }))
        XCTAssertTrue(opening.renderedText.hasSuffix(fence))

        let continuation = try XCTUnwrap(segments.first(where: {
            $0.markdownContinuation?.openFence == fence
                && $0.text.contains("value-")
                && !$0.text.contains(fence)
        }))
        XCTAssertTrue(continuation.renderedText.hasPrefix(fence + "\n"))
        XCTAssertTrue(continuation.renderedText.hasSuffix(fence))

        let closing = try XCTUnwrap(segments.first(where: {
            $0.markdownContinuation?.openFence == fence
                && $0.text == fence + "\n"
        }))
        XCTAssertTrue(closing.renderedText.hasPrefix(fence + "\n"))
        XCTAssertFalse(closing.renderedText.hasSuffix(fence))

        let after = try XCTUnwrap(segments.first(where: { $0.text == "After" }))
        XCTAssertNil(after.markdownContinuation?.openFence)
        XCTAssertEqual(after.renderedText, "After")
    }

    func testSplitFenceLikeLineInsideCodeCannotCloseTheRealFence() async throws {
        let fence = "````"
        let splitCandidate = String(repeating: "`", count: 400)
            + "not-a-close\n"
        let source = fence + "\n"
            + splitCandidate
            + "still-code\n"
            + fence + "\n"
            + "After\nDone"
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 1_024,
            maximumLines: 4
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertTrue(segments.allSatisfy { $0.renderedText.utf8.count <= 1_024 })

        let candidateSegments = segments.filter {
            $0.text.contains("not-a-close")
                || (!$0.endsAtPhysicalLineEnd && $0.text.allSatisfy { $0 == "`" })
        }
        XCTAssertGreaterThan(candidateSegments.count, 1)
        for segment in candidateSegments {
            XCTAssertEqual(segment.markdownContinuation?.openFence, fence)
            let preparedValue = await PreparedMarkdownRenderer.prepareOffMain(
                segment.renderedText
            )
            let prepared = try XCTUnwrap(preparedValue)
            let exactPayload = segment.text.trimmingCharacters(in: .newlines)
            XCTAssertTrue(
                prepared.plainText.contains(exactPayload),
                "A partial delimiter line must render literally, not close the synthetic tile fence."
            )
        }

        let body = try XCTUnwrap(segments.first { $0.text == "still-code\n" })
        XCTAssertEqual(body.markdownContinuation?.openFence, fence)
        let closing = try XCTUnwrap(segments.first {
            $0.text == fence + "\n"
                && $0.markdownContinuation?.openFence == fence
        })
        XCTAssertEqual(closing.markdownContinuation?.openFence, fence)
        let after = try XCTUnwrap(segments.first { $0.text == "After\nDone" })
        XCTAssertNil(after.markdownContinuation?.openFence)
    }

    func testOverBudgetPhysicalFenceLineRendersLiterallyWithoutOpeningFence() async throws {
        let splitFence = String(repeating: "`", count: 400) + "\n"
        let source = splitFence + "ordinary"
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 1_024,
            maximumLines: 4
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertTrue(segments.allSatisfy { $0.renderedText.utf8.count <= 1_024 })

        let delimiterSegments = segments.dropLast()
        XCTAssertGreaterThan(delimiterSegments.count, 1)
        for segment in delimiterSegments {
            XCTAssertNil(segment.markdownContinuation?.openFence)
            let preparedValue = await PreparedMarkdownRenderer.prepareOffMain(
                segment.renderedText
            )
            let prepared = try XCTUnwrap(preparedValue)
            XCTAssertTrue(
                prepared.plainText.contains(
                    segment.text.trimmingCharacters(in: .newlines)
                ),
                "An over-budget physical fence line uses the documented literal fallback."
            )
        }

        let ordinary = try XCTUnwrap(segments.last)
        XCTAssertEqual(ordinary.text, "ordinary")
        XCTAssertNil(ordinary.markdownContinuation?.openFence)
        XCTAssertEqual(ordinary.renderedText, "ordinary")
    }

    func testOverBudgetInfoStringOpensFenceForFollowingRows() async throws {
        let openingLine = "```swift " + String(repeating: "x", count: 400) + "\n"
        let source = openingLine + "# must be code\n```\nAfter\nDone"
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 1_024,
            maximumLines: 4
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        let body = try XCTUnwrap(segments.first { $0.text == "# must be code\n" })
        XCTAssertEqual(body.markdownContinuation?.openFence, "```")
        let preparedBodyValue = await PreparedMarkdownRenderer.prepareOffMain(
            body.renderedText
        )
        let preparedBody = try XCTUnwrap(preparedBodyValue)
        XCTAssertTrue(preparedBody.plainText.contains("# must be code"))

        let after = try XCTUnwrap(segments.first { $0.text == "After\nDone" })
        XCTAssertNil(after.markdownContinuation?.openFence)
        XCTAssertEqual(after.renderedText, "After\nDone")
    }

    func testOverBudgetWhitespaceCloserClosesFenceForFollowingRows() async throws {
        let closer = "```" + String(repeating: " ", count: 400) + "\n"
        let source = "```swift\ninside\n" + closer + "After"
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 1_024,
            maximumLines: 4
        )

        XCTAssertEqual(segments.map(\.text).joined(), source)
        let afterIndex = try XCTUnwrap(
            segments.firstIndex { $0.text == "After" }
        )
        let closerSegments = segments[..<afterIndex].suffix(2)
        XCTAssertEqual(closerSegments.map(\.text).joined(), closer)
        XCTAssertTrue(closerSegments.allSatisfy {
            $0.markdownContinuation?.openFence == "```"
        })

        let after = segments[afterIndex]
        XCTAssertNil(after.markdownContinuation?.openFence)
        XCTAssertEqual(after.renderedText, "After")
        let preparedAfterValue = await PreparedMarkdownRenderer.prepareOffMain(
            after.renderedText
        )
        let preparedAfter = try XCTUnwrap(preparedAfterValue)
        XCTAssertEqual(preparedAfter.plainText, "After")
    }

    func testHalfMegabyteNewlineFreeMessageHasStrictlyBoundedTiles() throws {
        let source = String(repeating: "abcdefghijklmnopqrstuvwxyz012345", count: 16_384)
        XCTAssertEqual(source.utf8.count, 512 * 1_024)

        let rows = TranscriptRowProjection.makeRows(
            item: .message(
                ChatMessage(id: "newline-free", role: .assistant, text: source)
            )
        )

        XCTAssertGreaterThan(rows.count, 100)
        XCTAssertEqual(try messageText(in: rows), source)
        try assertEveryTileIsBounded(rows)
    }

    func testHugeUnicodeSourceLinesSplitAtScalarBoundariesWithinBudgets() throws {
        let hugeLine = String(repeating: "café-☕️-", count: 2_000)
        let source = [hugeLine, hugeLine + "tail", hugeLine].joined(separator: "\n")
        let rows = TranscriptRowProjection.makeRows(
            item: .message(
                ChatMessage(id: "huge-lines", role: .assistant, text: source)
            )
        )

        XCTAssertGreaterThan(rows.count, 3)
        XCTAssertEqual(try messageText(in: rows), source)
        XCTAssertTrue(rows.allSatisfy { $0.sourceText.data(using: .utf8) != nil })
        try assertEveryTileIsBounded(rows)
    }

    func testTwentyThousandLineDiffAndToolOutputRemainCompleteAndBounded() throws {
        let source = (0..<20_000)
            .map { "line-\($0) " + String(repeating: "x", count: $0 % 41) }
            .joined(separator: "\n")
        let diffRows = TranscriptRowProjection.makeRows(
            item: .diff(
                ChatDiff(
                    id: "large-diff",
                    turnID: nil,
                    path: "Sources/Example.swift",
                    unifiedDiff: source,
                    occurredAt: nil,
                    isTruncated: false
                )
            )
        )
        let toolRows = TranscriptRowProjection.makeRows(
            item: .tool(
                ToolActivity(
                    id: "large-tool",
                    turnID: "turn",
                    kind: .shell,
                    title: "Command",
                    status: .completed,
                    input: nil,
                    output: source,
                    errorMessage: nil,
                    durationMilliseconds: nil,
                    exitCode: 0,
                    occurredAt: nil,
                    isTruncated: false,
                    originalByteCount: nil
                )
            )
        )

        XCTAssertGreaterThan(diffRows.count, 100)
        XCTAssertGreaterThan(toolRows.count, 100)
        XCTAssertEqual(try diffText(in: diffRows), source)
        XCTAssertEqual(try toolText(in: toolRows, section: .toolOutput), source)
        try assertEveryTileIsBounded(diffRows)
        try assertEveryTileIsBounded(toolRows)
    }

    func testFencedMarkdownSyntheticDelimitersFitProductionTileBudgets() throws {
        let source = "Before\n```swift\n"
            + String(repeating: "let value = 1234567890\n", count: 2_000)
            + String(repeating: "z", count: 32_000)
            + "\n```\nAfter"
        let rows = TranscriptRowProjection.makeRows(
            item: .message(
                ChatMessage(id: "fenced", role: .assistant, text: source)
            )
        )

        XCTAssertEqual(try messageText(in: rows), source)
        XCTAssertGreaterThan(rows.count, 10)
        try assertEveryTileIsBounded(rows)
        for row in rows.dropFirst().dropLast() {
            guard case .message(let message) = row.displayItem else {
                return XCTFail("Expected message projection")
            }
            XCTAssertTrue(message.text.hasPrefix("```\n"))
            XCTAssertTrue(message.text.hasSuffix("\n```"))
        }
    }

    func testLongMessageProjectsEveryLineIntoStableConsecutiveRows() throws {
        let source = (0..<500).map { "line-\($0)" }.joined(separator: "\n")
        let item = ConversationItem.message(
            ChatMessage(id: "assistant", role: .assistant, text: source)
        )
        let rows = TranscriptRowProjection.makeRows(item: item)

        XCTAssertGreaterThan(rows.count, 1)
        XCTAssertEqual(try messageText(in: rows), source)
        XCTAssertTrue(rows[0].isFirstInItem)
        XCTAssertTrue(rows[rows.count - 1].isLastInItem)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        XCTAssertTrue(rows.allSatisfy { row in
            guard case .message(let message) = row.displayItem else { return false }
            return message.text.utf8.count <= TranscriptRowProjection.maximumDisplayBytes
                && message.text.utf8.filter { $0 == 0x0A }.count
                    <= TranscriptRowProjection.maximumDisplayLines
        })
    }

    func testStreamingAppendOnlyRevisesFormerTailAndNewRows() throws {
        let original = String(repeating: "fixed-line\n", count: 800)
        let appended = String(repeating: "new-line\n", count: 240)
        let before = TranscriptRowProjection.makeRows(
            item: .message(
                ChatMessage(
                    id: "assistant",
                    role: .assistant,
                    text: original,
                    isStreaming: true
                )
            )
        )
        let after = TranscriptRowProjection.makeRows(
            item: .message(
                ChatMessage(
                    id: "assistant",
                    role: .assistant,
                    text: original + appended,
                    isStreaming: true
                )
            )
        )

        XCTAssertEqual(try messageText(in: after), original + appended)
        XCTAssertEqual(before.dropLast().map(\.id), after.prefix(before.count - 1).map(\.id))
        XCTAssertEqual(
            before.dropLast().map(\.contentRevision),
            after.prefix(before.count - 1).map(\.contentRevision),
            "Completed prefix rows must not remount for a tail append."
        )
        for (index, row) in after.enumerated() {
            guard case .message(let message) = row.displayItem else {
                return XCTFail("Expected message projection")
            }
            XCTAssertEqual(message.isStreaming, index == after.count - 1)
        }
    }

    func testIncrementalMarkdownAppendResegmentsTailWithFenceContinuation() throws {
        let original = "Before\n```swift\n"
            + String(repeating: "let value = 1\n", count: 900)
        let delta = String(repeating: "let next = 2\n", count: 400)
            + "```\nAfter"
        let beforeItem = ConversationItem.message(
            ChatMessage(
                id: "assistant",
                role: .assistant,
                text: original,
                isStreaming: true
            )
        )
        let afterItem = ConversationItem.message(
            ChatMessage(
                id: "assistant",
                role: .assistant,
                text: original + delta,
                isStreaming: true
            )
        )
        let before = TranscriptRowProjection.makeRows(item: beforeItem)

        let result = try XCTUnwrap(
            TranscriptRowProjection.appendingToTail(
                .message(contentID: "assistant:content:0", text: delta),
                item: afterItem,
                previousRows: before
            )
        )
        let rebuilt = TranscriptRowProjection.makeRows(item: afterItem)

        XCTAssertEqual(result.rows, rebuilt)
        XCTAssertEqual(try messageText(in: result.rows), original + delta)
        XCTAssertEqual(
            Array(before.dropLast()),
            Array(result.rows.prefix(before.count - 1)),
            "Rows before the mutable tail must remain sealed."
        )
        XCTAssertEqual(
            result.resegmentedSourceBytes,
            try XCTUnwrap(before.last).sourceText.utf8.count + delta.utf8.count
        )
        XCTAssertLessThan(
            result.resegmentedSourceBytes,
            original.utf8.count + delta.utf8.count
        )
    }

    func testIncrementalAppendResumesFenceCandidateSplitAcrossPriorTile() throws {
        let original = "```swift " + String(repeating: "x", count: 500)
        let delta = String(repeating: "y", count: 100)
            + "\n# body\n```\n"
            + String(repeating: "post\n", count: 130)
        let beforeItem = ConversationItem.message(
            ChatMessage(
                id: "assistant",
                role: .assistant,
                text: original,
                isStreaming: true
            )
        )
        let afterItem = ConversationItem.message(
            ChatMessage(
                id: "assistant",
                role: .assistant,
                text: original + delta,
                isStreaming: true
            )
        )
        let before = TranscriptRowProjection.makeRows(item: beforeItem)
        XCTAssertGreaterThan(before.count, 1)

        let result = try XCTUnwrap(
            TranscriptRowProjection.appendingToTail(
                .message(contentID: "assistant:content:0", text: delta),
                item: afterItem,
                previousRows: before
            )
        )
        let rebuilt = TranscriptRowProjection.makeRows(item: afterItem)

        XCTAssertEqual(result.rows, rebuilt)
        XCTAssertEqual(try messageText(in: result.rows), original + delta)
        let body = try XCTUnwrap(result.rows.first {
            $0.sourceText.contains("# body")
        })
        XCTAssertEqual(body.markdownContinuation?.openFence, "```")
        XCTAssertNil(result.rows.last?.markdownContinuation?.openFence)
        XCTAssertEqual(
            Array(before.dropLast()),
            Array(result.rows.prefix(before.count - 1))
        )
    }

    func testToolSectionsProjectAllRetainedContentWithoutRepeatingSectionStarts() throws {
        let input = String(repeating: "input\n", count: 300)
        let output = String(repeating: "output\n", count: 300)
        let error = String(repeating: "error\n", count: 300)
        let rows = TranscriptRowProjection.makeRows(
            item: .tool(
                ToolActivity(
                    id: "tool",
                    turnID: "turn",
                    kind: .shell,
                    title: "Command",
                    status: .completed,
                    input: input,
                    output: output,
                    errorMessage: error,
                    durationMilliseconds: nil,
                    exitCode: 1,
                    occurredAt: nil,
                    isTruncated: false,
                    originalByteCount: nil
                )
            )
        )

        XCTAssertEqual(try toolText(in: rows, section: .toolInput), input)
        XCTAssertEqual(try toolText(in: rows, section: .toolOutput), output)
        XCTAssertEqual(try toolText(in: rows, section: .toolError), error)
        for section in [
            TranscriptRowProjection.Section.toolInput,
            .toolOutput,
            .toolError,
        ] {
            let sectionRows = rows.filter { $0.section == section }
            XCTAssertGreaterThan(sectionRows.count, 1)
            XCTAssertEqual(sectionRows.filter(\.isFirstInSection).count, 1)
            XCTAssertEqual(sectionRows.filter(\.isLastInSection).count, 1)
        }
    }

    func testAllTextBearingItemKindsRemainCompleteInline() throws {
        let large = String(repeating: "value\n", count: 500)
        let reasoningRows = TranscriptRowProjection.makeRows(
            item: .reasoning(
                ChatReasoning(
                    id: "reasoning",
                    turnID: nil,
                    text: large,
                    isStreaming: false,
                    occurredAt: nil
                )
            )
        )
        let diffRows = TranscriptRowProjection.makeRows(
            item: .diff(
                ChatDiff(
                    id: "diff",
                    turnID: nil,
                    path: "README.md",
                    unifiedDiff: large,
                    occurredAt: nil,
                    isTruncated: false
                )
            )
        )
        let genericRows = TranscriptRowProjection.makeRows(
            item: .generic(
                ChatGenericItem(
                    id: "generic",
                    turnID: nil,
                    type: "activity",
                    title: "Activity",
                    detail: large,
                    occurredAt: nil
                )
            )
        )

        XCTAssertEqual(try reasoningText(in: reasoningRows), large)
        XCTAssertEqual(try diffText(in: diffRows), large)
        XCTAssertEqual(try genericText(in: genericRows), large)
        XCTAssertTrue(reasoningRows.count > 1 && diffRows.count > 1 && genericRows.count > 1)
    }

    @MainActor
    func testStoreCachesCompleteProjectionRowsForUnchangedItem() throws {
        let source = String(repeating: "café ☕️\n", count: 20_000)
        let store = ConversationStore()
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 1,
                itemID: "message",
                turnID: "turn",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(source),
                ])
            )
        )
        let item = try XCTUnwrap(store.state.items.first)
        let first = store.transcriptProjections(for: item)
        let second = store.transcriptProjections(for: item)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try messageText(in: first), source)
        XCTAssertGreaterThan(first.count, 1)
    }

    private func messageText(in rows: [TranscriptRowProjection]) throws -> String {
        try rows.map { row in
            guard case .message(let message) = row.displayItem else {
                throw ProjectionTestError.unexpectedItem
            }
            XCTAssertFalse(message.contents.isEmpty)
            return row.sourceText
        }.joined()
    }

    private func reasoningText(in rows: [TranscriptRowProjection]) throws -> String {
        try rows.map { row in
            guard case .reasoning(let reasoning) = row.displayItem else {
                throw ProjectionTestError.unexpectedItem
            }
            XCTAssertEqual(reasoning.text, row.sourceText)
            return row.sourceText
        }.joined()
    }

    private func diffText(in rows: [TranscriptRowProjection]) throws -> String {
        try rows.map { row in
            guard case .diff(let diff) = row.displayItem else {
                throw ProjectionTestError.unexpectedItem
            }
            XCTAssertEqual(diff.unifiedDiff, row.sourceText)
            return row.sourceText
        }.joined()
    }

    private func genericText(in rows: [TranscriptRowProjection]) throws -> String {
        try rows.map { row in
            guard case .generic(let item) = row.displayItem else {
                throw ProjectionTestError.unexpectedItem
            }
            XCTAssertEqual(item.detail ?? "", row.sourceText)
            return row.sourceText
        }.joined()
    }

    private func toolText(
        in rows: [TranscriptRowProjection],
        section: TranscriptRowProjection.Section
    ) throws -> String {
        try rows.filter { $0.section == section }.map { row in
            guard case .tool(let tool) = row.displayItem else {
                throw ProjectionTestError.unexpectedItem
            }
            switch section {
            case .toolInput:
                XCTAssertEqual(tool.input ?? "", row.sourceText)
                return row.sourceText
            case .toolOutput:
                XCTAssertEqual(tool.output ?? "", row.sourceText)
                return row.sourceText
            case .toolError:
                XCTAssertEqual(tool.errorMessage ?? "", row.sourceText)
                return row.sourceText
            default: throw ProjectionTestError.unexpectedItem
            }
        }.joined()
    }

    private func assertEveryTileIsBounded(
        _ rows: [TranscriptRowProjection],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for row in rows {
            XCTAssertLessThanOrEqual(
                row.sourceText.utf8.count,
                TranscriptRowProjection.maximumDisplayBytes,
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                logicalLineCount(row.sourceText),
                TranscriptRowProjection.maximumDisplayLines,
                file: file,
                line: line
            )

            let renderedText: String
            switch row.displayItem {
            case .message(let message): renderedText = message.text
            case .reasoning(let reasoning): renderedText = reasoning.text
            case .tool(let tool):
                renderedText = tool.input ?? tool.output ?? tool.errorMessage ?? ""
            case .diff(let diff): renderedText = diff.unifiedDiff
            case .plan(let plan):
                renderedText = plan.title ?? plan.steps.first?.title ?? ""
            case .generic(let generic): renderedText = generic.detail ?? ""
            }
            XCTAssertLessThanOrEqual(
                renderedText.utf8.count,
                TranscriptRowProjection.maximumDisplayBytes,
                file: file,
                line: line
            )
            XCTAssertLessThanOrEqual(
                logicalLineCount(renderedText),
                TranscriptRowProjection.maximumDisplayLines,
                file: file,
                line: line
            )
        }
    }

    private func logicalLineCount(_ text: String) -> Int {
        1 + text.utf8.reduce(into: 0) { count, byte in
            if byte == 0x0A { count += 1 }
        }
    }
}

private enum ProjectionTestError: Error {
    case unexpectedItem
}
