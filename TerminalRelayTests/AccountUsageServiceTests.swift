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
            {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":89,"windowDurationMins":10080,"resetsAt":1785258135},"secondary":null,"planType":"pro"},"rateLimitResetCredits":{"availableCount":2,"credits":[{"id":"reset-credit-1","resetType":"codexRateLimits","status":"available","grantedAt":1785000000,"expiresAt":1786000000,"title":"Weekly reset","description":"Earned for active Codex use"},{"id":"reset-credit-2","resetType":"unknown","status":"redeemed","grantedAt":1784000000,"expiresAt":null,"title":null,"description":null}]}}}
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

        let resetCredits = try XCTUnwrap(snapshot.codexResetCredits)
        XCTAssertEqual(resetCredits.availableCount, 2)
        let credits = try XCTUnwrap(resetCredits.credits)
        XCTAssertEqual(credits.count, 2)

        XCTAssertEqual(credits[0].id, "reset-credit-1")
        XCTAssertEqual(credits[0].resetType, "codexRateLimits")
        XCTAssertEqual(credits[0].status, "available")
        XCTAssertEqual(credits[0].grantedAt, Date(timeIntervalSince1970: 1_785_000_000))
        XCTAssertEqual(credits[0].expiresAt, Date(timeIntervalSince1970: 1_786_000_000))
        XCTAssertEqual(credits[0].title, "Weekly reset")
        XCTAssertEqual(credits[0].description, "Earned for active Codex use")
        XCTAssertTrue(credits[0].isAvailable)

        XCTAssertEqual(credits[1].id, "reset-credit-2")
        XCTAssertEqual(credits[1].resetType, "unknown")
        XCTAssertEqual(credits[1].status, "redeemed")
        XCTAssertEqual(credits[1].grantedAt, Date(timeIntervalSince1970: 1_784_000_000))
        XCTAssertNil(credits[1].expiresAt)
        XCTAssertNil(credits[1].title)
        XCTAssertNil(credits[1].description)
        XCTAssertFalse(credits[1].isAvailable)
    }

    func testParsesCodexResetCountWithoutCreditDetails() throws {
        let output = Data(
            """
            {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":null},"secondary":null,"planType":"plus"},"rateLimitResetCredits":{"availableCount":3,"credits":null}}}
            """.utf8
        )

        let snapshot = try AccountUsageService.parseCodex(output)

        let resetCredits = try XCTUnwrap(snapshot.codexResetCredits)
        XCTAssertEqual(resetCredits.availableCount, 3)
        XCTAssertNil(resetCredits.credits)
    }

    func testRecognizesCodexSignInRequiredForNewSession() {
        let output = Data(
            """
            {"id":0,"result":{"userAgent":"terminal_relay/1.0"}}
            {"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}
            """.utf8
        )

        XCTAssertThrowsError(
            try AccountUsageService.parseCodex(output)
        ) { error in
            XCTAssertEqual(error as? AccountUsageError, .signInRequired(.codex))
        }
    }

    func testKeepsCodexAccountWhenRateLimitsAreTemporarilyUnavailable() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Data(
            """
            {"id":1,"error":{"code":-32603,"message":"rate limits unavailable"}}
            {"id":2,"result":{"account":{"type":"chatgpt","email":"codex@example.com","planType":"pro"},"requiresOpenaiAuth":true}}
            """.utf8
        )

        let snapshot = try AccountUsageService.parseCodex(
            output,
            fallbackAccount: "Worker Codex",
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(snapshot.account, "codex@example.com")
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertTrue(snapshot.limits.isEmpty)
        XCTAssertNil(snapshot.codexResetCredits)
    }

    func testParsesEveryCodexResetConsumeOutcomeAmidNotifications() throws {
        let cases: [(rawValue: String, outcome: CodexResetConsumeOutcome)] = [
            ("reset", .reset),
            ("alreadyRedeemed", .alreadyRedeemed),
            ("nothingToReset", .nothingToReset),
            ("noCredit", .noCredit)
        ]

        for testCase in cases {
            let output = Data(
                """
                {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
                {"id":0,"result":{"userAgent":"terminal_relay/1.0"}}
                {"id":999,"result":{"outcome":"noCredit"}}
                {"id":2,"result":{"outcome":"\(testCase.rawValue)"}}
                {"method":"account/rateLimits/updated","params":{"rateLimits":{}}}
                """.utf8
            )

            XCTAssertEqual(
                try AccountUsageService.parseCodexResetConsume(output),
                testCase.outcome,
                "Failed to parse \(testCase.rawValue)"
            )
        }
    }

    func testRejectsInvalidCodexResetConsumeResponse() {
        let output = Data(
            """
            {"id":0,"result":{"userAgent":"terminal_relay/1.0"}}
            {"method":"remoteControl/status/changed","params":{"status":"disabled"}}
            {"id":1,"result":{"outcome":"reset"}}
            {"id":2,"result":{"outcome":"futureOutcome"}}
            """.utf8
        )

        XCTAssertThrowsError(
            try AccountUsageService.parseCodexResetConsume(output)
        ) { error in
            XCTAssertEqual(error as? AccountUsageError, .resetRedemptionFailed)
        }
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
        XCTAssertNil(snapshot.codexResetCredits)
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
