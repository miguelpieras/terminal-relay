import XCTest

@MainActor
final class ConversationScrollingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false

        app = XCUIApplication()
        app.launchArguments = [
            "--terminal-relay-ui-test-scroll",
        ]
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Read-only local demo"].waitForExistence(timeout: 5),
            "The local conversation fixture did not open."
        )
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    func testRestoredConversationAnchorsLatestAndRespectsManualScroll() {
        let transcript = element(identifier: "conversation.transcript")
        let restoredTail = element(
            identifier: "conversation.item.scroll-test-tail"
        )
        let historyRow = element(
            identifier: "conversation.item.scroll-row-090"
        )
        let lateUpdate = element(
            identifier: "conversation.item.scroll-test-late-update"
        )
        let jumpToLatest = element(
            identifier: "conversation.jump-to-latest"
        )
        let appendUpdate = element(identifier: "conversation.test.append")

        XCTAssertTrue(
            transcript.waitForExistence(timeout: 5),
            "The conversation transcript did not become accessible."
        )
        XCTAssertTrue(
            waitUntilHittable(restoredTail),
            "A restored conversation should open at its latest content."
        )
        XCTAssertTrue(waitUntilValue("latest", on: transcript))
        XCTAssertFalse(jumpToLatest.exists)

        for _ in 0..<5 where !isFullyVisible(historyRow, in: transcript) {
            transcript.swipeDown()
        }

        XCTAssertTrue(
            jumpToLatest.waitForExistence(timeout: 3),
            "A real scroll gesture should leave the latest position and reveal the jump control."
        )
        XCTAssertTrue(
            waitUntilFullyVisible(historyRow, in: transcript),
            "The gesture did not reveal the stable history anchor."
        )
        XCTAssertTrue(waitUntilValue("history", on: transcript))
        XCTAssertTrue(
            appendUpdate.waitForExistence(timeout: 2) && appendUpdate.isHittable,
            "The deterministic update trigger is unavailable."
        )
        let historyRowMinY = historyRow.frame.minY

        appendUpdate.tap()

        XCTAssertTrue(
            lateUpdate.waitForExistence(timeout: 5),
            "The appended conversation update did not arrive."
        )
        XCTAssertFalse(
            isFullyVisible(lateUpdate, in: transcript),
            "New content must not steal the viewport after a user scrolls."
        )
        assertViewportRemainsStable(
            historyRow: historyRow,
            expectedMinY: historyRowMinY,
            transcript: transcript,
            jumpToLatest: jumpToLatest,
            for: 0.75
        )

        jumpToLatest.tap()

        XCTAssertTrue(
            waitUntilValue("latest", on: transcript),
            "Jump to latest should restore latest-following state."
        )
        XCTAssertTrue(
            waitUntilFullyVisible(lateUpdate, in: transcript),
            "Jump to latest should restore the newest content."
        )
        XCTAssertTrue(
            waitUntilGone(jumpToLatest),
            "The jump control should disappear after returning to the latest content."
        )
    }

    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: identifier)
            .firstMatch
    }

    private func waitUntilHittable(
        _ element: XCUIElement,
        timeout: TimeInterval = 5
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntilFullyVisible(
        _ element: XCUIElement,
        in container: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if isFullyVisible(element, in: container) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
        return isFullyVisible(element, in: container)
    }

    private func isFullyVisible(
        _ element: XCUIElement,
        in container: XCUIElement
    ) -> Bool {
        guard element.exists, container.exists else { return false }
        let frame = element.frame
        let containerFrame = container.frame
        return !frame.isEmpty
            && frame.minY >= containerFrame.minY
            && frame.maxY <= containerFrame.maxY
    }

    private func waitUntilValue(
        _ expectedValue: String,
        on element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", expectedValue),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitUntilGone(
        _ element: XCUIElement,
        timeout: TimeInterval = 3
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func assertViewportRemainsStable(
        historyRow: XCUIElement,
        expectedMinY: CGFloat,
        transcript: XCUIElement,
        jumpToLatest: XCUIElement,
        for duration: TimeInterval
    ) {
        let deadline = Date().addingTimeInterval(duration)
        repeat {
            XCTAssertEqual(transcript.value as? String, "history")
            XCTAssertTrue(isFullyVisible(historyRow, in: transcript))
            XCTAssertEqual(historyRow.frame.minY, expectedMinY, accuracy: 4)
            XCTAssertTrue(
                jumpToLatest.exists && jumpToLatest.isHittable,
                "Late layout must not steal the viewport after a user scrolls."
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        } while Date() < deadline
    }
}
