import XCTest
@testable import TerminalRelay

final class MarkdownTableProjectionContinuityTests: XCTestCase {
    func testLongTableKeepsEveryTileSemanticBoundedAndUniquelyAuthored() throws {
        let header = "| Name | Status | Detail |\n"
        let delimiter = "| --- | --- | --- |\n"
        let authoredRows = (0..<600).map { index in
            "| row-\(index) | ready | detail-\(index)-abcdefghij |\n"
        }
        let source = header + delimiter + authoredRows.joined()
        let segments = TranscriptTextProjection.markdownSegments(of: source)

        XCTAssertGreaterThan(segments.count, 3)
        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertEqual(
            segments.flatMap { segment in
                segment.text.split(separator: "\n").filter {
                    $0.hasPrefix("| row-")
                }
            }.count,
            authoredRows.count,
            "Synthetic headers must never enter authoritative source text."
        )

        for (index, segment) in segments.enumerated() {
            XCTAssertLessThanOrEqual(
                segment.renderedText.utf8.count,
                TranscriptRowProjection.maximumDisplayBytes
            )
            XCTAssertLessThanOrEqual(
                TranscriptTextProjection.logicalLineCount(segment.renderedText),
                TranscriptRowProjection.maximumDisplayLines
            )
            XCTAssertTrue(
                MarkdownSafety.containsTableCandidate(segment.renderedText),
                "Table tile \(index) was flattened into pipe-delimited prose."
            )
            if index > 0 {
                XCTAssertEqual(
                    segment.markdownContinuation?.openTablePrefix,
                    header + delimiter
                )
                XCTAssertTrue(segment.renderedText.hasPrefix(header + delimiter))
            }
        }

        let projections = TranscriptRowProjection.makeRows(
            item: .message(
                ChatMessage(id: "long-table", role: .assistant, text: source)
            )
        )
        XCTAssertEqual(projections.count, segments.count)
        XCTAssertEqual(projections.map(\.sourceText).joined(), source)
        for (projection, segment) in zip(projections, segments) {
            guard case .message(let displayed) = projection.displayItem,
                  let content = displayed.contents.first else {
                return XCTFail("Expected one bounded displayed message tile.")
            }
            XCTAssertEqual(projection.sourceText, segment.text)
            XCTAssertEqual(content.text, segment.renderedText)
            XCTAssertLessThanOrEqual(
                content.text.utf8.count,
                TranscriptRowProjection.maximumDisplayBytes
            )
        }
    }

    func testHeaderDelimiterCrossingTileBoundarySynthesizesOnlyTheHeader() throws {
        let prelude = String(repeating: "p", count: 45) + "\n"
        let header = "| A | B |\n"
        let delimiter = "| --- | --- |\n"
        let body = (0..<40).map { "| \($0) | value-\($0) |\n" }.joined()
        let source = prelude + header + delimiter + body
        let segments = TranscriptTextProjection.markdownSegments(
            of: source,
            maximumBytes: 192,
            maximumLines: 12
        )

        XCTAssertGreaterThan(segments.count, 2)
        XCTAssertEqual(segments.map(\.text).joined(), source)
        XCTAssertTrue(try XCTUnwrap(segments.first).text.hasSuffix(header))

        let delimiterTile = try XCTUnwrap(
            segments.first { $0.text.hasPrefix(delimiter) }
        )
        XCTAssertEqual(
            delimiterTile.markdownContinuation?.pendingTableHeader,
            String(header.dropLast())
        )
        XCTAssertFalse(delimiterTile.text.contains(header))
        XCTAssertTrue(delimiterTile.renderedText.hasPrefix(header + delimiter))
        XCTAssertTrue(
            MarkdownSafety.containsTableCandidate(delimiterTile.renderedText)
        )

        for segment in segments {
            XCTAssertLessThanOrEqual(segment.renderedText.utf8.count, 192)
            XCTAssertLessThanOrEqual(
                TranscriptTextProjection.logicalLineCount(segment.renderedText),
                12
            )
        }
    }
}
