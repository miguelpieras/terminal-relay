import XCTest
@testable import TerminalRelay

@MainActor
final class WorkerMetricsServiceTests: XCTestCase {
    func testParsesMetricsAndCalculatesPercentages() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let output = Data(
            """
            # HELP node_cpu_seconds_total Seconds the CPUs spent in each mode.
            node_cpu_seconds_total{cpu="0",mode="idle"} 4
            node_cpu_seconds_total{cpu="0",mode="user"} 3.5
            node_cpu_seconds_total{cpu="1",mode="idle"} 4
            node_cpu_seconds_total{cpu="1",mode="system"} 3.5
            node_memory_MemTotal_bytes 8192000
            node_memory_MemAvailable_bytes 2048000
            node_filesystem_size_bytes{device="/dev/sda1",mountpoint="/"} 10240000
            node_filesystem_free_bytes{device="/dev/sda1",mountpoint="/"} 7680000
            """.utf8
        )
        let previousReading = WorkerMetricsReading(
            cpuTotalCentiseconds: 1_000,
            cpuIdleCentiseconds: 425,
            memoryTotalKiB: 8_000,
            memoryAvailableKiB: 2_000,
            diskTotalKiB: 10_000,
            diskUsedKiB: 2_500
        )

        let snapshot = try WorkerMetricsService.parse(
            output,
            previousReading: previousReading,
            fetchedAt: fetchedAt
        )

        XCTAssertEqual(try XCTUnwrap(snapshot.cpuUsedPercent), 25, accuracy: 0.001)
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
            # exporter comments and unrelated metrics are ignored
            go_gc_duration_seconds 0.5
            node_cpu_seconds_total{cpu="0",mode="idle"} 3
            node_cpu_seconds_total{cpu="0",mode="user"} 1
            node_memory_MemTotal_bytes 4096
            node_memory_MemAvailable_bytes 1024
            node_filesystem_size_bytes{device="/dev/sda1",mountpoint="/"} 8192
            node_filesystem_free_bytes{device="/dev/sda1",mountpoint="/"} 6144
            """.utf8
        )

        let snapshot = try WorkerMetricsService.parse(output)

        XCTAssertNil(snapshot.cpuUsedPercent)
        XCTAssertEqual(snapshot.memoryUsedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.diskUsedPercent, 25, accuracy: 0.001)
    }

    func testRejectsMalformedMetricsOutput() {
        let malformedOutputs = [
            "node_cpu_seconds_total{cpu=\"0\",mode=\"idle\"} 1",
            """
            node_cpu_seconds_total{cpu="0",mode="idle"} nope
            node_memory_MemTotal_bytes 4096
            node_memory_MemAvailable_bytes 1024
            node_filesystem_size_bytes{mountpoint="/"} 8192
            node_filesystem_free_bytes{mountpoint="/"} 6144
            """,
            """
            node_cpu_seconds_total{cpu="0",mode="idle"} 1
            node_memory_MemTotal_bytes 1024
            node_memory_MemAvailable_bytes 4096
            node_filesystem_size_bytes{mountpoint="/"} 8192
            node_filesystem_free_bytes{mountpoint="/"} 6144
            """,
            """
            node_cpu_seconds_total{cpu="0",mode="idle"} 1
            node_memory_MemTotal_bytes 4096
            node_memory_MemAvailable_bytes 1024
            node_filesystem_size_bytes{mountpoint="/"} 1024
            node_filesystem_free_bytes{mountpoint="/"} 8192
            """
        ]

        for output in malformedOutputs {
            XCTAssertThrowsError(try WorkerMetricsService.parse(Data(output.utf8))) { error in
                XCTAssertEqual(error as? WorkerMetricsError, .invalidResponse)
            }
        }
    }

    func testWorkerMetricsURLUsesTheWorkerNodeExporter() throws {
        let worker = ServerProfile(host: "terminal-relay-worker-4")

        XCTAssertEqual(
            try XCTUnwrap(WorkerMetricsService.metricsURL(for: worker)).absoluteString,
            "http://terminal-relay-worker-4:9100/metrics"
        )
    }
}
