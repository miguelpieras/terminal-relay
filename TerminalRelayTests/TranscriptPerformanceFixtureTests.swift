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
}
