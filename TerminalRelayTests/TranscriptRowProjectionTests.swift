import XCTest
@testable import TerminalRelay

final class TranscriptRowProjectionTests: XCTestCase {
    func testHeadAndTailStayWithinByteAndLineCapsForMaximumInputs() {
        let singleLine = String(repeating: "é", count: 256 * 1_024)
        let head = TranscriptTextProjection.make(
            singleLine,
            direction: .head,
            maximumBytes: TranscriptRowProjection.maximumDisplayBytes,
            maximumLines: TranscriptRowProjection.maximumDisplayLines,
            metrics: TranscriptTextMetrics(singleLine)
        )
        let tail = TranscriptTextProjection.make(
            singleLine,
            direction: .tail,
            maximumBytes: TranscriptRowProjection.maximumDisplayBytes,
            maximumLines: TranscriptRowProjection.maximumDisplayLines,
            metrics: TranscriptTextMetrics(singleLine)
        )

        XCTAssertLessThanOrEqual(head.text.utf8.count, 65_536)
        XCTAssertLessThanOrEqual(tail.text.utf8.count, 65_536)
        XCTAssertTrue(singleLine.hasPrefix(head.text))
        XCTAssertTrue(singleLine.hasSuffix(tail.text))
        XCTAssertEqual(head.hiddenByteCount + head.text.utf8.count, singleLine.utf8.count)
        XCTAssertEqual(tail.hiddenByteCount + tail.text.utf8.count, singleLine.utf8.count)
        XCTAssertLessThanOrEqual(head.inspectedByteCount, 65_540)
        XCTAssertLessThanOrEqual(tail.inspectedByteCount, 65_540)
        XCTAssertNoThrow(try XCTUnwrap(head.text.data(using: .utf8)))
        XCTAssertNoThrow(try XCTUnwrap(tail.text.data(using: .utf8)))
    }

    func testProjectionUsesHeadForUserAndTailForStreamingAssistant() {
        let lines = (0..<500).map { "line-\($0)" }.joined(separator: "\n")
        let user = TranscriptRowProjection.make(
            item: .message(
                ChatMessage(id: "user", role: .user, text: lines)
            ),
            contentRevision: 1
        )
        let assistant = TranscriptRowProjection.make(
            item: .message(
                ChatMessage(
                    id: "assistant",
                    role: .assistant,
                    text: lines,
                    isStreaming: true
                )
            ),
            contentRevision: 2
        )

        guard case .message(let userMessage) = user.displayItem,
              case .message(let assistantMessage) = assistant.displayItem else {
            return XCTFail("Expected projected messages")
        }
        XCTAssertTrue(userMessage.text.hasPrefix("line-0\n"))
        XCTAssertTrue(assistantMessage.text.hasSuffix("line-499"))
        XCTAssertLessThanOrEqual(userMessage.text.split(separator: "\n", omittingEmptySubsequences: false).count, 120)
        XCTAssertLessThanOrEqual(assistantMessage.text.split(separator: "\n", omittingEmptySubsequences: false).count, 120)
        XCTAssertTrue(user.isTruncated)
        XCTAssertTrue(assistant.isTruncated)
        XCTAssertEqual(user.sourceHandles.count, 1)
        XCTAssertEqual(assistant.sourceHandles.count, 1)
        XCTAssertFalse(user.sourceHandles[0].id.contains(lines))
    }

    func testProjectionCutsAtUTF8ScalarBoundariesForOneHugeGrapheme() {
        let source = "a" + String(repeating: "\u{301}", count: 40_000)
        let metrics = TranscriptTextMetrics(source)
        for direction in [TranscriptProjectionDirection.head, .tail] {
            let projection = TranscriptTextProjection.make(
                source,
                direction: direction,
                maximumBytes: TranscriptRowProjection.maximumDisplayBytes,
                maximumLines: TranscriptRowProjection.maximumDisplayLines,
                metrics: metrics
            )
            XCTAssertLessThanOrEqual(
                projection.text.utf8.count,
                TranscriptRowProjection.maximumDisplayBytes
            )
            XCTAssertLessThanOrEqual(
                projection.inspectedByteCount,
                TranscriptRowProjection.maximumDisplayBytes
            )
            XCTAssertNotNil(projection.text.data(using: .utf8))
        }
    }

    func testToolProjectionSharesOneBudgetAcrossAllSections() {
        let large = (0..<300).map { "value-\($0)" }.joined(separator: "\n")
        let tool = ToolActivity(
            id: "tool",
            turnID: "turn",
            kind: .shell,
            title: "Command",
            status: .running,
            input: large,
            output: large,
            errorMessage: large,
            durationMilliseconds: nil,
            exitCode: nil,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        )
        let projection = TranscriptRowProjection.make(
            item: .tool(tool),
            contentRevision: 1
        )

        guard case .tool(let displayed) = projection.displayItem else {
            return XCTFail("Expected projected tool")
        }
        let rendered = [displayed.title, displayed.input, displayed.output, displayed.errorMessage]
            .compactMap { $0 }
            .joined()
        XCTAssertLessThanOrEqual(rendered.utf8.count, 65_536)
        XCTAssertLessThanOrEqual(
            rendered.split(separator: "\n", omittingEmptySubsequences: false).count,
            120
        )
        XCTAssertTrue(projection.isTruncated)
        XCTAssertFalse(projection.sourceHandles.isEmpty)
    }

    func testProjectionIsStableForTheSameItemAndRevision() {
        let item = ConversationItem.diff(
            ChatDiff(
                id: "diff",
                turnID: "turn",
                path: "README.md",
                unifiedDiff: String(repeating: "+value\n", count: 500),
                occurredAt: nil,
                isTruncated: false
            )
        )
        XCTAssertEqual(
            TranscriptRowProjection.make(item: item, contentRevision: 42),
            TranscriptRowProjection.make(item: item, contentRevision: 42)
        )
    }

    @MainActor
    func testFullContentHandleResolvesExactRetainedSource() throws {
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
        let projection = store.transcriptProjection(for: item)
        let handle = try XCTUnwrap(projection.sourceHandles.first)
        store.presentFullContent(handle)

        let presented = try XCTUnwrap(store.fullContentPresentation)
        XCTAssertEqual(presented.text, source)
        XCTAssertEqual(presented.retainedByteCount, source.utf8.count)
        XCTAssertEqual(
            presented.retainedLineCount,
            source.split(separator: "\n", omittingEmptySubsequences: false).count
        )
        XCTAssertLessThanOrEqual(
            projection.displayItem.approximateProjectedByteCount,
            TranscriptRowProjection.maximumDisplayBytes
        )
    }
}

private extension ConversationItem {
    var approximateProjectedByteCount: Int {
        switch self {
        case .message(let message): message.text.utf8.count
        case .reasoning(let reasoning): reasoning.text.utf8.count
        case .tool(let tool):
            tool.title.utf8.count
                + (tool.input?.utf8.count ?? 0)
                + (tool.output?.utf8.count ?? 0)
                + (tool.errorMessage?.utf8.count ?? 0)
        case .diff(let diff): diff.unifiedDiff.utf8.count
        case .plan(let plan): plan.steps.reduce(0) { $0 + $1.title.utf8.count }
        case .generic(let item): item.title.utf8.count + (item.detail?.utf8.count ?? 0)
        }
    }
}
