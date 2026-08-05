import XCTest
@testable import TerminalRelay

final class TranscriptRowProjectionTests: XCTestCase {
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
        let original = String(repeating: "fixed-line\n", count: 240)
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
}

private enum ProjectionTestError: Error {
    case unexpectedItem
}
