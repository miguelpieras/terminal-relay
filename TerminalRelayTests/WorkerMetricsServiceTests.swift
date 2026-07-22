import XCTest
@testable import TerminalRelay

@MainActor
final class WorkerMetricsServiceTests: XCTestCase {
    func testParsesMetricsAndCalculatesPercentages() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Data(
            """
            __TERMINAL_RELAY_METRICS_V1__
            cpu|125|500
            memory|8000|2000
            disk|10000|2500
            """.utf8
        )

        let snapshot = try WorkerMetricsService.parse(output, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.cpuUsedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.memoryUsedBytes, 6_000 * 1_024)
        XCTAssertEqual(snapshot.memoryTotalBytes, 8_000 * 1_024)
        XCTAssertEqual(snapshot.memoryUsedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.diskUsedBytes, 2_500 * 1_024)
        XCTAssertEqual(snapshot.diskTotalBytes, 10_000 * 1_024)
        XCTAssertEqual(snapshot.diskUsedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testParserAllowsNoiseBeforeMarkerAndWhitespace() throws {
        let output = Data(
            """
            Welcome to worker
            __TERMINAL_RELAY_METRICS_V1__
              cpu | 1 | 3
            memory| 4 | 1
            disk | 8 | 2
            """.utf8
        )

        let snapshot = try WorkerMetricsService.parse(output)

        XCTAssertEqual(snapshot.cpuUsedPercent, 100.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(snapshot.memoryUsedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.diskUsedPercent, 25, accuracy: 0.001)
    }

    func testRejectsMalformedMetricsOutput() {
        let malformedOutputs = [
            "cpu|1|2\nmemory|4|2\ndisk|8|4",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|1|2\nmemory|4|2",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|nope|2\nmemory|4|2\ndisk|8|4",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|3|2\nmemory|4|2\ndisk|8|4",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|1|2\nmemory|4|5\ndisk|8|4",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|1|2\nmemory|4|2\ndisk|8|9",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|1|2\ncpu|1|2\nmemory|4|2\ndisk|8|4",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|1|2\nmemory|4|2\ndisk|0|0",
            "__TERMINAL_RELAY_METRICS_V1__\ncpu|1|2\nmemory|18014398509481984|0\ndisk|8|4"
        ]

        for output in malformedOutputs {
            XCTAssertThrowsError(try WorkerMetricsService.parse(Data(output.utf8))) { error in
                XCTAssertEqual(error as? WorkerMetricsError, .invalidResponse)
            }
        }
    }
}
