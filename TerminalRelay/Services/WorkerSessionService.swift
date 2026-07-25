import Combine
import Foundation
import OSLog

private let workerSessionLogger = Logger(
    subsystem: "com.mpieras.TerminalRelay",
    category: "worker-session"
)

struct WorkerSessionCommandResult {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

enum WorkerSessionServiceError: LocalizedError, Equatable {
    case statusFailed
    case startFailed
    case stopFailed

    var errorDescription: String? {
        switch self {
        case .statusFailed:
            "Persistent session status is unavailable for this worker."
        case .startFailed:
            "The worker could not start this agent."
        case .stopFailed:
            "The worker could not stop this agent."
        }
    }
}

@MainActor
final class WorkerSessionService: ObservableObject {
    typealias CommandRunner = (SSHLaunchConfiguration) async throws -> WorkerSessionCommandResult

    @Published private(set) var responses: [UUID: WorkerSessionResponse] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var loadingWorkerIDs: Set<UUID> = []
    @Published private(set) var startingSlots: Set<SessionSlot> = []
    @Published private(set) var stoppingSlots: Set<SessionSlot> = []

    private let runCommand: CommandRunner
    private var refreshTasks: [UUID: Task<WorkerSessionResponse?, Never>] = [:]

    convenience init() {
        self.init { configuration in
            let result = try await Subprocess.run(
                executable: URL(fileURLWithPath: configuration.executable),
                arguments: configuration.arguments
            )
            return WorkerSessionCommandResult(
                exitCode: result.exitCode,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        }
    }

    init(runCommand: @escaping CommandRunner) {
        self.runCommand = runCommand
    }

    func response(for workerID: UUID) -> WorkerSessionResponse? {
        responses[workerID]
    }

    func error(for workerID: UUID) -> String? {
        errors[workerID]
    }

    func dismissError(for workerID: UUID) {
        errors[workerID] = nil
    }

    func isStopping(worker: ServerProfile, kind: AgentKind) -> Bool {
        stoppingSlots.contains(SessionSlot(serverKey: worker.concurrencyKey, kind: kind))
    }

    func isStarting(worker: ServerProfile, kind: AgentKind) -> Bool {
        startingSlots.contains(SessionSlot(serverKey: worker.concurrencyKey, kind: kind))
    }

    @discardableResult
    func refresh(worker: ServerProfile) async -> WorkerSessionResponse? {
        guard refreshTasks[worker.id] == nil else { return nil }
        return await startRefresh(worker: worker)
    }

    private func refreshCoalescing(worker: ServerProfile) async -> WorkerSessionResponse? {
        if let task = refreshTasks[worker.id] {
            return await task.value
        }
        return await startRefresh(worker: worker)
    }

    private func startRefresh(worker: ServerProfile) async -> WorkerSessionResponse? {
        let task: Task<WorkerSessionResponse?, Never> = Task { [weak self] in
            guard let self else { return nil }
            return await self.performRefresh(worker: worker)
        }
        refreshTasks[worker.id] = task
        let response = await task.value
        refreshTasks[worker.id] = nil
        return response
    }

    private func performRefresh(worker: ServerProfile) async -> WorkerSessionResponse? {
        loadingWorkerIDs.insert(worker.id)
        defer { loadingWorkerIDs.remove(worker.id) }
        workerSessionLogger.info(
            "Refreshing sessions on \(worker.destination, privacy: .public)"
        )

        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerSessionStatusConfiguration(for: worker)
            )
            guard result.exitCode == 0 else {
                workerSessionLogger.error(
                    "Session refresh failed on \(worker.destination, privacy: .public) with status \(result.exitCode, privacy: .public): \(Self.logDetail(result.standardError), privacy: .public)"
                )
                throw WorkerSessionServiceError.statusFailed
            }

            let response = try WorkerSessionProtocol.parse(result.standardOutput)
            responses[worker.id] = response
            errors[worker.id] = nil
            workerSessionLogger.info(
                "Session refresh succeeded on \(worker.destination, privacy: .public); found \(response.sessions.count, privacy: .public) sessions"
            )
            return response
        } catch {
            let message = message(for: error, fallback: .statusFailed)
            workerSessionLogger.error(
                "Session refresh failed on \(worker.destination, privacy: .public): \(message, privacy: .public)"
            )
            errors[worker.id] = message
            return nil
        }
    }

    func start(
        kind: AgentKind,
        repositoryName: String,
        launchDefaults: AgentLaunchDefaults,
        on worker: ServerProfile
    ) async -> WorkerSessionSnapshot? {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errors[worker.id] = WorkerSessionServiceError.startFailed.localizedDescription
            return nil
        }

        let slot = SessionSlot(serverKey: worker.concurrencyKey, kind: kind)
        guard !startingSlots.contains(slot), !stoppingSlots.contains(slot) else { return nil }
        startingSlots.insert(slot)
        defer { startingSlots.remove(slot) }
        workerSessionLogger.notice(
            "Starting \(kind.rawValue, privacy: .public) for \(repositoryName, privacy: .public) on \(worker.destination, privacy: .public)"
        )

        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerSessionStartConfiguration(
                    for: worker,
                    kind: kind,
                    repositoryName: repositoryName,
                    launchDefaults: launchDefaults
                )
            )
            guard result.exitCode == 0 else {
                workerSessionLogger.error(
                    "Session start failed for \(kind.rawValue, privacy: .public) on \(worker.destination, privacy: .public) with status \(result.exitCode, privacy: .public): \(Self.logDetail(result.standardError), privacy: .public)"
                )
                throw WorkerSessionServiceError.startFailed
            }

            let response = try WorkerSessionProtocol.parse(result.standardOutput)
            guard response.sessions.count == 1,
                  let snapshot = response.sessions.first,
                  snapshot.kind == kind,
                  snapshot.repositoryName == repositoryName else {
                throw WorkerSessionServiceError.startFailed
            }

            let previousResponse = responses[worker.id]
            let projects = Set(previousResponse?.projects ?? [])
                .union(response.projects)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let sessions = ((previousResponse?.sessions ?? []).filter {
                $0.instanceToken != snapshot.instanceToken
            } + [snapshot])
                .sorted {
                    if $0.repositoryName != $1.repositoryName {
                        return $0.repositoryName.localizedStandardCompare($1.repositoryName)
                            == .orderedAscending
                    }
                    return $0.instanceToken < $1.instanceToken
                }
            responses[worker.id] = WorkerSessionResponse(
                projects: projects,
                sessions: sessions
            )
            errors[worker.id] = nil
            workerSessionLogger.notice(
                "Started \(kind.rawValue, privacy: .public) session \(snapshot.instanceToken, privacy: .public) for \(repositoryName, privacy: .public) on \(worker.destination, privacy: .public)"
            )
            return snapshot
        } catch {
            let message = message(for: error, fallback: .startFailed)
            workerSessionLogger.error(
                "Session start failed for \(kind.rawValue, privacy: .public) on \(worker.destination, privacy: .public): \(message, privacy: .public)"
            )
            errors[worker.id] = message
            return nil
        }
    }

    @discardableResult
    func stop(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String,
        on worker: ServerProfile
    ) async -> Bool {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName),
              let parsedInstanceToken = UUID(uuidString: instanceToken),
              parsedInstanceToken.uuidString.lowercased() == instanceToken else {
            errors[worker.id] = WorkerSessionServiceError.stopFailed.localizedDescription
            return false
        }

        let slot = SessionSlot(serverKey: worker.concurrencyKey, kind: kind)
        guard !stoppingSlots.contains(slot), !startingSlots.contains(slot) else { return false }
        stoppingSlots.insert(slot)
        defer { stoppingSlots.remove(slot) }
        workerSessionLogger.notice(
            "Stopping \(kind.rawValue, privacy: .public) session \(instanceToken, privacy: .public) on \(worker.destination, privacy: .public)"
        )

        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerSessionStopConfiguration(
                    for: worker,
                    kind: kind,
                    repositoryName: repositoryName,
                    instanceToken: instanceToken
                )
            )
            guard result.exitCode == 0 else {
                workerSessionLogger.error(
                    "Session stop failed for \(instanceToken, privacy: .public) on \(worker.destination, privacy: .public) with status \(result.exitCode, privacy: .public): \(Self.logDetail(result.standardError), privacy: .public)"
                )
                throw WorkerSessionServiceError.stopFailed
            }

            if var response = responses[worker.id] {
                response = WorkerSessionResponse(
                    projects: response.projects,
                    sessions: response.sessions.filter {
                        $0.kind != kind
                            || $0.repositoryName != repositoryName
                            || $0.instanceToken != instanceToken
                    }
                )
                responses[worker.id] = response
            }
            errors[worker.id] = nil
            workerSessionLogger.notice(
                "Stopped \(kind.rawValue, privacy: .public) session \(instanceToken, privacy: .public) on \(worker.destination, privacy: .public)"
            )
            return true
        } catch {
            let message = message(for: error, fallback: .stopFailed)
            workerSessionLogger.error(
                "Session stop failed for \(instanceToken, privacy: .public) on \(worker.destination, privacy: .public): \(message, privacy: .public)"
            )
            errors[worker.id] = message
            return false
        }
    }

    @discardableResult
    func stopActiveSessions(
        kind: AgentKind,
        on worker: ServerProfile
    ) async -> Bool {
        guard let response = await refreshCoalescing(worker: worker) else {
            return false
        }

        for snapshot in response.sessions where snapshot.kind == kind {
            guard await stop(
                kind: kind,
                repositoryName: snapshot.repositoryName,
                instanceToken: snapshot.instanceToken,
                on: worker
            ) else {
                return false
            }
        }
        return true
    }

    private static func logDetail(_ data: Data) -> String {
        let detail = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return detail.isEmpty ? "no stderr" : String(detail.prefix(1_000))
    }

    private func message(
        for error: Error,
        fallback: WorkerSessionServiceError
    ) -> String {
        if let protocolError = error as? WorkerSessionProtocolError {
            return protocolError.errorDescription ?? fallback.localizedDescription
        }
        if let serviceError = error as? WorkerSessionServiceError {
            return serviceError.errorDescription ?? fallback.localizedDescription
        }
        return fallback.localizedDescription
    }
}
