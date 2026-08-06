import XCTest
@testable import TerminalRelay

final class TranscriptPerformanceFixtureTests: XCTestCase {
    func testMaximumFixturesAreDeterministicAndWithinRetainedBounds() {
        let oneMiB = TranscriptPerformanceFixtures.messages(
            count: 100,
            totalBytes: 1_048_576
        )
        let eightMiB = TranscriptPerformanceFixtures.messages(
            count: 1_000,
            totalBytes: 8 * 1_048_576
        )

        XCTAssertEqual(oneMiB.count, 100)
        XCTAssertEqual(eightMiB.count, 1_000)
        XCTAssertEqual(contentBytes(oneMiB), 1_048_576)
        XCTAssertEqual(contentBytes(eightMiB), 8 * 1_048_576)
        let mixed = TranscriptPerformanceFixtures.mixedMaximumTranscript
        XCTAssertEqual(mixed.count, 1_000)
        XCTAssertEqual(allContentBytes(mixed), 8 * 1_048_576)
        XCTAssertEqual(mixed.filter { if case .tool = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(mixed.filter { if case .diff = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(
            Set(mixed.prefix(20).compactMap { item -> String? in
                guard case .message(let message) = item else { return nil }
                return String(message.text.prefix(40))
            }).count,
            20,
            "Cold rows must not collapse onto one shared Markdown cache key."
        )
        XCTAssertEqual(
            TranscriptPerformanceFixtures.newlineFree512KiB.utf8.count,
            512 * 1_024
        )
        XCTAssertLessThan(
            TranscriptPerformanceFixtures.nearMaximumDiff.utf8.count,
            1_048_576
        )
        XCTAssertLessThan(
            TranscriptPerformanceFixtures.nearMaximumToolOutput.utf8.count,
            1_048_576
        )
        XCTAssertEqual(TranscriptPerformanceFixtures.historyPrepend.count, 100)
        XCTAssertEqual(TranscriptPerformanceFixtures.tenSecondDeltas.count, 304)
        XCTAssertTrue(
            TranscriptPerformanceFixtures.tenSecondDeltas.allSatisfy {
                $0.utf8.count == 1_024
            }
        )
    }

    private func contentBytes(_ items: [ConversationItem]) -> Int {
        items.reduce(into: 0) { result, item in
            guard case .message(let message) = item else { return }
            result += message.text.utf8.count
        }
    }

    private func allContentBytes(_ items: [ConversationItem]) -> Int {
        items.reduce(into: 0) { result, item in
            switch item {
            case .message(let message):
                result += message.text.utf8.count
            case .reasoning(let reasoning):
                result += reasoning.text.utf8.count
            case .tool(let tool):
                result += tool.input?.utf8.count ?? 0
                result += tool.output?.utf8.count ?? 0
                result += tool.errorMessage?.utf8.count ?? 0
            case .diff(let diff):
                result += diff.unifiedDiff.utf8.count
            case .plan(let plan):
                result += plan.title?.utf8.count ?? 0
                result += plan.steps.reduce(0) { $0 + $1.title.utf8.count }
            case .generic(let generic):
                result += generic.detail?.utf8.count ?? 0
            }
        }
    }
}
