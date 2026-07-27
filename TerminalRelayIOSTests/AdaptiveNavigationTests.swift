import XCTest
@testable import TerminalRelayIOS

final class AdaptiveNavigationTests: XCTestCase {
    func testProjectSelectionKeepsAValidDetailAndFallsBackWhenItDisappears() {
        let workerID = UUID()
        let first = ProjectSelection(workerID: workerID, repositoryName: "alpha")
        let second = ProjectSelection(workerID: workerID, repositoryName: "beta")

        XCTAssertEqual(
            AdaptiveSelectionPolicy.project(current: second, available: [first, second]),
            second
        )
        XCTAssertEqual(
            AdaptiveSelectionPolicy.project(current: second, available: [first]),
            first
        )
        XCTAssertNil(
            AdaptiveSelectionPolicy.project(current: second, available: [])
        )
    }

    func testWorkerSelectionKeepsAValidDetailAndFallsBackWhenItDisappears() {
        let first = UUID()
        let second = UUID()

        XCTAssertEqual(
            AdaptiveSelectionPolicy.worker(current: second, available: [first, second]),
            second
        )
        XCTAssertEqual(
            AdaptiveSelectionPolicy.worker(current: second, available: [first]),
            first
        )
        XCTAssertNil(
            AdaptiveSelectionPolicy.worker(current: second, available: [])
        )
    }
}
