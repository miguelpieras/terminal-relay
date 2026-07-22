import Combine
import Foundation

struct WorkerMetricsSnapshot: Equatable {
    let cpuUsedPercent: Double
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
            snapshots[worker.id] = try await Self.fetch(worker: worker)
        } catch {
            errors[worker.id] = (error as? LocalizedError)?.errorDescription
                ?? WorkerMetricsError.commandFailed.localizedDescription
        }
    }

    static func parse(
        _ data: Data,
        fetchedAt: Date = Date()
    ) throws -> WorkerMetricsSnapshot {
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let markerIndex = lines.firstIndex(of: outputMarker) else {
            throw WorkerMetricsError.invalidResponse
        }

        var cpu: (used: UInt64, total: UInt64)?
        var memory: (totalKiB: UInt64, availableKiB: UInt64)?
        var disk: (totalKiB: UInt64, usedKiB: UInt64)?

        for line in lines.dropFirst(markerIndex + 1) {
            let fields = line
                .split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard fields.count == 3 else {
                throw WorkerMetricsError.invalidResponse
            }

            switch fields[0] {
            case "cpu":
                guard cpu == nil,
                      let used = UInt64(fields[1]),
                      let total = UInt64(fields[2]),
                      total > 0,
                      used <= total else {
                    throw WorkerMetricsError.invalidResponse
                }
                cpu = (used, total)
            case "memory":
                guard memory == nil,
                      let total = UInt64(fields[1]),
                      let available = UInt64(fields[2]),
                      total > 0,
                      available <= total else {
                    throw WorkerMetricsError.invalidResponse
                }
                memory = (total, available)
            case "disk":
                guard disk == nil,
                      let total = UInt64(fields[1]),
                      let used = UInt64(fields[2]),
                      total > 0,
                      used <= total else {
                    throw WorkerMetricsError.invalidResponse
                }
                disk = (total, used)
            default:
                throw WorkerMetricsError.invalidResponse
            }
        }

        guard let cpu, let memory, let disk,
              let memoryTotalBytes = bytes(fromKiB: memory.totalKiB),
              let memoryAvailableBytes = bytes(fromKiB: memory.availableKiB),
              let diskTotalBytes = bytes(fromKiB: disk.totalKiB),
              let diskUsedBytes = bytes(fromKiB: disk.usedKiB) else {
            throw WorkerMetricsError.invalidResponse
        }

        return WorkerMetricsSnapshot(
            cpuUsedPercent: Double(cpu.used) / Double(cpu.total) * 100,
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

    private static func fetch(worker: ServerProfile) async throws -> WorkerMetricsSnapshot {
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: ["-o", "ConnectTimeout=5"]
                + GitHubProjectService.sshArguments(for: worker, script: probeScript)
        )
        guard result.exitCode == 0 else {
            throw WorkerMetricsError.commandFailed
        }
        return try parse(result.standardOutput)
    }

    private static let outputMarker = "__TERMINAL_RELAY_METRICS_V1__"

    private static let probeScript = """
    set -eu

    read_cpu() {
      awk '/^cpu / {
        total = $2 + $3 + $4 + $5 + $6 + $7 + $8 + $9
        idle = $5 + $6
        printf "%.0f %.0f\\n", total, idle
        exit
      }' /proc/stat
    }

    cpu_before=$(read_cpu)
    sleep 1
    cpu_after=$(read_cpu)

    set -- $cpu_before
    cpu_total_before=$1
    cpu_idle_before=$2
    set -- $cpu_after
    cpu_total_after=$1
    cpu_idle_after=$2
    cpu_total=$((cpu_total_after - cpu_total_before))
    cpu_idle=$((cpu_idle_after - cpu_idle_before))
    cpu_used=$((cpu_total - cpu_idle))

    set -- $(awk '
      /^MemTotal:/ { total = $2 }
      /^MemAvailable:/ { available = $2 }
      END { print total, available }
    ' /proc/meminfo)
    memory_total=$1
    memory_available=$2

    disk_path=/workspace
    [ -d "$disk_path" ] || disk_path=/
    set -- $(df -Pk "$disk_path" | awk 'NR == 2 { print $2, $3 }')
    disk_total=$1
    disk_used=$2

    printf '%s\\n' '__TERMINAL_RELAY_METRICS_V1__'
    printf 'cpu|%s|%s\\n' "$cpu_used" "$cpu_total"
    printf 'memory|%s|%s\\n' "$memory_total" "$memory_available"
    printf 'disk|%s|%s\\n' "$disk_total" "$disk_used"
    """
}
