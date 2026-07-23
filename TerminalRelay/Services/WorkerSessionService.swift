import Combine
import Foundation

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
        guard !loadingWorkerIDs.contains(worker.id) else { return nil }
        loadingWorkerIDs.insert(worker.id)
        defer { loadingWorkerIDs.remove(worker.id) }

        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerSessionStatusConfiguration(for: worker)
            )
            guard result.exitCode == 0 else {
                throw WorkerSessionServiceError.statusFailed
            }

            let response = try WorkerSessionProtocol.parse(result.standardOutput)
            responses[worker.id] = response
            errors[worker.id] = nil
            return response
        } catch {
            errors[worker.id] = message(for: error, fallback: .statusFailed)
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
            return snapshot
        } catch {
            errors[worker.id] = message(for: error, fallback: .startFailed)
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
            return true
        } catch {
            errors[worker.id] = message(for: error, fallback: .stopFailed)
            return false
        }
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
