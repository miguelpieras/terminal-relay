import XCTest
@testable import TerminalRelayIOS

final class WorkerOverviewTests: XCTestCase {
    func testParsesWorkerResources() throws {
        let snapshot = try WorkerOverviewParser.resources(
            Data(
                """
                Welcome to the worker
                __TERMINAL_RELAY_METRICS_V1__
                  cpu | 125 | 500
                memory|8000|2000
                disk|10000|2500
                """.utf8
            )
        )

        XCTAssertEqual(snapshot.cpuUsedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.memoryUsedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.diskUsedPercent, 25, accuracy: 0.001)
    }

    func testWorkerResourceCommandUsesPrivateNodeExporter() {
        XCTAssertTrue(
            WorkerRemoteCommand.resources.contains("http://$exporter_address:9100/metrics")
        )
        XCTAssertTrue(WorkerRemoteCommand.resources.contains("node_cpu_seconds_total"))
        XCTAssertTrue(WorkerRemoteCommand.resources.contains(#"$1 !~ /mode="guest"/"#))
        XCTAssertFalse(WorkerRemoteCommand.resources.contains("cpu_before=$(read_cpu)"))
    }

    func testParsesCodexAccountAndLimits() throws {
        let snapshot = try WorkerOverviewParser.codexAccount(
            Data(
                """
                {"id":2,"result":{"account":{"email":"codex@example.com","planType":"pro"}}}
                {"method":"account/rateLimits/updated","params":{}}
                {"id":1,"result":{"rateLimits":{"primary":{"usedPercent":89,"windowDurationMins":10080},"secondary":{"usedPercent":20,"windowDurationMins":300},"planType":"pro"}}}
                """.utf8
            )
        )

        XCTAssertEqual(snapshot.account, "codex@example.com")
        XCTAssertEqual(snapshot.plan, "pro")
        XCTAssertEqual(snapshot.limits.map(\.name), ["Weekly", "5-hour"])
        XCTAssertEqual(snapshot.limits[0].remainingPercent, 11)
        XCTAssertEqual(snapshot.limits[1].remainingPercent, 80)
    }

    func testParsesClaudeAccountAndLimits() throws {
        let snapshot = try WorkerOverviewParser.claudeAccount(
            Data(
                """
                __TERMINAL_RELAY_CLAUDE_AUTH__
                {"loggedIn":true,"email":"claude@example.com","subscriptionType":"max"}
                __TERMINAL_RELAY_CLAUDE_USAGE__
                Current session: 12.5% used
                Current week (all models): 37% used · resets tomorrow
                """.utf8
            )
        )

        XCTAssertEqual(snapshot.account, "claude@example.com")
        XCTAssertEqual(snapshot.plan, "max")
        XCTAssertEqual(snapshot.limits.map(\.name), ["Session", "Weekly"])
        XCTAssertEqual(snapshot.limits[0].remainingPercent, 87.5)
        XCTAssertEqual(snapshot.limits[1].remainingPercent, 63)
    }

    func testRejectsMissingUsageData() {
        XCTAssertThrowsError(
            try WorkerOverviewParser.codexAccount(Data("{}".utf8))
        )
        XCTAssertThrowsError(
            try WorkerOverviewParser.claudeAccount(Data("Not signed in".utf8))
        )
    }
}
