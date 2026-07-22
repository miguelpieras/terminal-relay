import XCTest
@testable import TerminalRelay

@MainActor
final class AccountUsageServiceTests: XCTestCase {
    func testParsesCodexRateLimitsAmidNotifications() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Data(
            """
            {"id":0,"result":{"userAgent":"terminal_relay/1.0"}}
            {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
            {"id":2,"result":{"account":{"type":"chatgpt","email":"codex@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
            {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":89,"windowDurationMins":10080,"resetsAt":1785258135},"secondary":null,"planType":"pro"}}}
            """.utf8
        )

        let snapshot = try AccountUsageService.parseCodex(output, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.account, "codex@example.com")
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertEqual(snapshot.limits.count, 1)
        XCTAssertEqual(snapshot.limits[0].name, "Weekly limit")
        XCTAssertEqual(snapshot.limits[0].usedPercent, 89)
        XCTAssertEqual(snapshot.limits[0].remainingPercent, 11)
        XCTAssertEqual(
            snapshot.limits[0].resetsAt,
            Date(timeIntervalSince1970: 1_785_258_135)
        )
    }

    func testCodexWindowLabelsComeFromActualDuration() {
        XCTAssertEqual(AccountUsageService.codexWindowName(minutes: 300, index: 0), "5-hour limit")
        XCTAssertEqual(AccountUsageService.codexWindowName(minutes: 10_080, index: 0), "Weekly limit")
        XCTAssertEqual(AccountUsageService.codexWindowName(minutes: 2_880, index: 1), "2-day limit")
        XCTAssertEqual(AccountUsageService.codexWindowName(minutes: nil, index: 1), "Secondary limit")
    }

    func testParsesClaudeAuthAndSubscriptionUsage() throws {
        let output = Data(
            """
            __TERMINAL_RELAY_CLAUDE_AUTH__
            {
              "loggedIn": true,
              "email": "claude@example.com",
              "subscriptionType": "max"
            }
            __TERMINAL_RELAY_CLAUDE_USAGE__
            You are currently using your subscription to power your Claude Code usage

            Current session: 12.5% used
            Current week (all models): 37% used · resets Jul 26, 1:59am (UTC)
            Current week (Fable): 8% used
            """.utf8
        )

        let snapshot = try AccountUsageService.parseClaude(output)

        XCTAssertEqual(snapshot.account, "claude@example.com")
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.limits.map(\.name), [
            "Current session",
            "Weekly · all models",
            "Weekly · Fable"
        ])
        XCTAssertEqual(snapshot.limits[0].usedPercent, 12.5)
        XCTAssertEqual(snapshot.limits[0].remainingPercentText, "87.5")
        XCTAssertEqual(snapshot.limits[1].resetText, "Jul 26, 1:59am (UTC)")
        XCTAssertNil(snapshot.limits[2].resetText)
    }

    func testClaudeParserUsesWorkerLabelWhenAuthMetadataIsAbsent() throws {
        let output = Data(
            """
            Current session: 0% used
            Current week (all models): 0% used
            """.utf8
        )

        let snapshot = try AccountUsageService.parseClaude(
            output,
            fallbackAccount: "Worker Claude"
        )

        XCTAssertEqual(snapshot.account, "Worker Claude")
        XCTAssertEqual(snapshot.limits.count, 2)
    }

    func testRejectsOutputWithoutUsageLimits() {
        XCTAssertThrowsError(
            try AccountUsageService.parseClaude(Data("Not logged in".utf8))
        ) { error in
            XCTAssertEqual(error as? AccountUsageError, .invalidResponse(.claude))
        }
        XCTAssertThrowsError(
            try AccountUsageService.parseCodex(Data("{}".utf8))
        ) { error in
            XCTAssertEqual(error as? AccountUsageError, .invalidResponse(.codex))
        }
    }
}
