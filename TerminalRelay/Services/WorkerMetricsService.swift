import Combine
import Foundation

struct WorkerMetricsSnapshot: Equatable {
    let cpuUsedPercent: Double?
    let memoryUsedBytes: Int64
    let memoryTotalBytes: Int64
    let diskUsedBytes: Int64
    let diskTotalBytes: Int64
    let fetchedAt: Date

    var memoryUsedPercent: Double {
        Self.percent(used: memoryUsedBytes, total: memoryTotalBytes)
    }

    var diskUsedPercent: Double {
        Self.percent(used: diskUsedBytes, total: diskTotalBytes)
    }

    private static func percent(used: Int64, total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total) * 100, 0), 100)
    }
}

struct WorkerMetricsReading: Equatable {
    let cpuTotalCentiseconds: UInt64
    let cpuIdleCentiseconds: UInt64
    let memoryTotalKiB: UInt64
    let memoryAvailableKiB: UInt64
    let diskTotalKiB: UInt64
    let diskUsedKiB: UInt64
}

enum WorkerMetricsError: LocalizedError, Equatable {
    case commandFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .commandFailed:
            return "Could not read system usage from this worker."
        case .invalidResponse:
            return "This worker returned invalid system usage."
        }
    }
}

@MainActor
final class WorkerMetricsService: ObservableObject {
    @Published private(set) var snapshots: [UUID: WorkerMetricsSnapshot] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var loadingWorkerIDs: Set<UUID> = []

    private let cacheDuration: TimeInterval = 15
    private var previousReadings: [UUID: WorkerMetricsReading] = [:]

    func snapshot(for workerID: UUID) -> WorkerMetricsSnapshot? {
        snapshots[workerID]
    }

    func error(for workerID: UUID) -> String? {
        errors[workerID]
    }

    func isLoading(workerID: UUID) -> Bool {
        loadingWorkerIDs.contains(workerID)
    }

    func refresh(worker: ServerProfile, force: Bool = false) async {
        guard !loadingWorkerIDs.contains(worker.id) else { return }
        if !force,
           let snapshot = snapshots[worker.id],
           Date().timeIntervalSince(snapshot.fetchedAt) < cacheDuration {
            return
        }

        loadingWorkerIDs.insert(worker.id)
        errors[worker.id] = nil
        defer { loadingWorkerIDs.remove(worker.id) }

        do {
            let fetchedAt = Date()
            let reading = try await Self.fetch(worker: worker)
            snapshots[worker.id] = try Self.snapshot(
                reading: reading,
                previousReading: previousReadings[worker.id],
                fetchedAt: fetchedAt
            )
            previousReadings[worker.id] = reading
        } catch {
            errors[worker.id] = (error as? LocalizedError)?.errorDescription
                ?? WorkerMetricsError.commandFailed.localizedDescription
        }
    }

    static func parse(
        _ data: Data,
        previousReading: WorkerMetricsReading? = nil,
        fetchedAt: Date = Date()
    ) throws -> WorkerMetricsSnapshot {
        try snapshot(
            reading: parseReading(data),
            previousReading: previousReading,
            fetchedAt: fetchedAt
        )
    }

    static func parseReading(_ data: Data) throws -> WorkerMetricsReading {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var cpuTotalSeconds = 0.0
        var cpuIdleSeconds = 0.0
        var memoryTotalBytes: Double?
        var memoryAvailableBytes: Double?
        var diskTotalBytes: Double?
        var diskFreeBytes: Double?

        for line in lines where !line.hasPrefix("#") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let metricField = fields.first else { continue }
            let metric = String(metricField)
            let isCPU = metric.hasPrefix("node_cpu_seconds_total{")
            let isMemoryTotal = metric == "node_memory_MemTotal_bytes"
            let isMemoryAvailable = metric == "node_memory_MemAvailable_bytes"
            let isDiskTotal = metric.hasPrefix("node_filesystem_size_bytes{")
                && metric.contains(#"mountpoint="/""#)
            let isDiskFree = metric.hasPrefix("node_filesystem_free_bytes{")
                && metric.contains(#"mountpoint="/""#)
            guard isCPU || isMemoryTotal || isMemoryAvailable || isDiskTotal || isDiskFree else {
                continue
            }
            guard fields.count == 2,
                  let value = Double(fields[1]),
                  value.isFinite,
                  value >= 0 else {
                throw WorkerMetricsError.invalidResponse
            }

            if isCPU {
                guard !metric.contains(#"mode="guest""#),
                      !metric.contains(#"mode="guest_nice""#) else {
                    continue
                }
                cpuTotalSeconds += value
                if metric.contains(#"mode="idle""#)
                    || metric.contains(#"mode="iowait""#) {
                    cpuIdleSeconds += value
                }
            } else if isMemoryTotal {
                memoryTotalBytes = value
            } else if isMemoryAvailable {
                memoryAvailableBytes = value
            } else if isDiskTotal {
                diskTotalBytes = value
            } else if isDiskFree {
                diskFreeBytes = value
            }
        }

        guard let cpuTotalCentiseconds = uint64(cpuTotalSeconds, scale: 100),
              let cpuIdleCentiseconds = uint64(cpuIdleSeconds, scale: 100),
              cpuTotalCentiseconds > 0,
              cpuIdleCentiseconds <= cpuTotalCentiseconds,
              let memoryTotalBytes,
              let memoryAvailableBytes,
              memoryTotalBytes > 0,
              memoryAvailableBytes <= memoryTotalBytes,
              let diskTotalBytes,
              let diskFreeBytes,
              diskTotalBytes > 0,
              diskFreeBytes <= diskTotalBytes,
              let memoryTotalKiB = uint64(memoryTotalBytes, scale: 1.0 / 1_024),
              let memoryAvailableKiB = uint64(
                  memoryAvailableBytes,
                  scale: 1.0 / 1_024
              ),
              let diskTotalKiB = uint64(diskTotalBytes, scale: 1.0 / 1_024),
              let diskUsedKiB = uint64(
                  diskTotalBytes - diskFreeBytes,
                  scale: 1.0 / 1_024
              ) else {
            throw WorkerMetricsError.invalidResponse
        }

        return WorkerMetricsReading(
            cpuTotalCentiseconds: cpuTotalCentiseconds,
            cpuIdleCentiseconds: cpuIdleCentiseconds,
            memoryTotalKiB: memoryTotalKiB,
            memoryAvailableKiB: memoryAvailableKiB,
            diskTotalKiB: diskTotalKiB,
            diskUsedKiB: diskUsedKiB
        )
    }

    static func snapshot(
        reading: WorkerMetricsReading,
        previousReading: WorkerMetricsReading?,
        fetchedAt: Date = Date()
    ) throws -> WorkerMetricsSnapshot {
        guard
              let memoryTotalBytes = bytes(fromKiB: reading.memoryTotalKiB),
              let memoryAvailableBytes = bytes(fromKiB: reading.memoryAvailableKiB),
              let diskTotalBytes = bytes(fromKiB: reading.diskTotalKiB),
              let diskUsedBytes = bytes(fromKiB: reading.diskUsedKiB) else {
            throw WorkerMetricsError.invalidResponse
        }

        let cpuUsedPercent: Double?
        if let previousReading,
           reading.cpuTotalCentiseconds > previousReading.cpuTotalCentiseconds,
           reading.cpuIdleCentiseconds >= previousReading.cpuIdleCentiseconds {
            let total = reading.cpuTotalCentiseconds - previousReading.cpuTotalCentiseconds
            let idle = reading.cpuIdleCentiseconds - previousReading.cpuIdleCentiseconds
            guard idle <= total else {
                throw WorkerMetricsError.invalidResponse
            }
            cpuUsedPercent = Double(total - idle) / Double(total) * 100
        } else {
            cpuUsedPercent = nil
        }

        return WorkerMetricsSnapshot(
            cpuUsedPercent: cpuUsedPercent,
            memoryUsedBytes: memoryTotalBytes - memoryAvailableBytes,
            memoryTotalBytes: memoryTotalBytes,
            diskUsedBytes: diskUsedBytes,
            diskTotalBytes: diskTotalBytes,
            fetchedAt: fetchedAt
        )
    }

    private static func bytes(fromKiB value: UInt64) -> Int64? {
        guard value <= UInt64(Int64.max) else { return nil }
        let result = Int64(value).multipliedReportingOverflow(by: 1_024)
        return result.overflow ? nil : result.partialValue
    }

    private static func uint64(_ value: Double, scale: Double) -> UInt64? {
        let scaled = value * scale
        guard scaled.isFinite,
              scaled >= 0,
              scaled <= Double(UInt64.max) else {
            return nil
        }
        return UInt64(scaled.rounded())
    }

    private static func fetch(worker: ServerProfile) async throws -> WorkerMetricsReading {
        guard let url = metricsURL(for: worker) else {
            throw WorkerMetricsError.commandFailed
        }
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: [
                "--fail",
                "--silent",
                "--show-error",
                "--connect-timeout", "3",
                "--max-time", "5",
                "--",
                url.absoluteString
            ]
        )
        guard result.exitCode == 0 else {
            throw WorkerMetricsError.commandFailed
        }
        return try parseReading(result.standardOutput)
    }

    static func metricsURL(for worker: ServerProfile) -> URL? {
        let host = worker.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 9_100
        components.path = "/metrics"
        return components.url
    }
}
