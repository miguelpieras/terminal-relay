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
    case threadFailed
    case nativeChatUnavailable
    case runtimeUpdating

    var errorDescription: String? {
        switch self {
        case .statusFailed:
            "Persistent session status is unavailable for this worker."
        case .startFailed:
            "The worker could not start this agent."
        case .stopFailed:
            "The worker could not stop this agent."
        case .threadFailed:
            "The worker could not complete that thread action."
        case .nativeChatUnavailable:
            "Native chat is unavailable on this worker. Update it and try again."
        case .runtimeUpdating:
            "This worker is updating to a compatible runtime. Existing conversations remain connected; try again shortly."
        }
    }
}

private enum WorkerUpdateStatusFetchResult {
    case loaded(WorkerUpdateStatus?)
    case unavailable
}

@MainActor
final class WorkerSessionService: ObservableObject {
    typealias CommandRunner = (SSHLaunchConfiguration) async throws -> WorkerSessionCommandResult

    @Published private(set) var responses: [UUID: WorkerSessionResponse] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var updateStatuses: [UUID: WorkerUpdateStatus] = [:]
    @Published private(set) var updateWarnings: [UUID: String] = [:]
    @Published private(set) var runtimeInfos: [UUID: WorkerRuntimeInfo] = [:]
    @Published private(set) var runtimeUpdateStatuses: [UUID: WorkerRuntimeUpdateStatus] = [:]
    @Published private(set) var runtimeMessages: [UUID: String] = [:]
    @Published private(set) var loadingWorkerIDs: Set<UUID> = []
    @Published private(set) var startingSlots: Set<SessionSlot> = []
    @Published private(set) var stoppingSlots: Set<SessionSlot> = []
    @Published private(set) var threadCatalogs: [WorkerThreadCatalogKey: WorkerThreadResponse] = [:]

    private let runCommand: CommandRunner
    private let inspectsRuntimeOnRefresh: Bool
    private let persistsThreadCatalogs: Bool
    private var refreshTasks: [UUID: Task<WorkerSessionResponse?, Never>] = [:]
    private var dismissedUpdateTimestamps: [UUID: Int] = [:]
    private var runtimeUpdateTasks: [UUID: Task<Void, Never>] = [:]
    private var threadCatalogFetchTimes: [WorkerThreadCatalogKey: Date] = [:]
    /// The worker can keep listing a chat session for a few seconds after a
    /// successful stop (broker teardown outlives the acknowledgement), and an
    /// in-flight listing can land after a mutation it predates. Tombstones veto
    /// those stale rows until the worker catches up.
    private var stoppedSessionTombstones: [String: Date] = [:]
    private var archivedThreadTombstones: [String: Date] = [:]
    private static let tombstoneLifetime: TimeInterval = 60

    private static let threadCatalogStorageKey = "workerThreadCatalogs.v1"
    private static let threadCatalogFreshness: TimeInterval = 30

    convenience init() {
        self.init(
            runCommand: { configuration in
                let result = try await Subprocess.run(
                    executable: URL(fileURLWithPath: configuration.executable),
                    arguments: configuration.arguments
                )
                return WorkerSessionCommandResult(
                    exitCode: result.exitCode,
                    standardOutput: result.standardOutput,
                    standardError: result.standardError
                )
            },
            inspectsRuntimeOnRefresh: true,
            persistsThreadCatalogs: true
        )
    }

    init(runCommand: @escaping CommandRunner) {
        self.runCommand = runCommand
        inspectsRuntimeOnRefresh = false
        persistsThreadCatalogs = false
    }

    init(
        runCommand: @escaping CommandRunner,
        inspectsRuntimeOnRefresh: Bool,
        persistsThreadCatalogs: Bool = false
    ) {
        self.runCommand = runCommand
        self.inspectsRuntimeOnRefresh = inspectsRuntimeOnRefresh
        self.persistsThreadCatalogs = persistsThreadCatalogs
        if persistsThreadCatalogs {
            loadPersistedThreadCatalogs()
        }
    }

    /// Cached catalog entries let the sidebar render a project's
    /// conversations instantly on expansion; the SSH refresh then updates
    /// them in the background.
    private struct PersistedThreadCatalog: Codable {
        let key: WorkerThreadCatalogKey
        let response: WorkerThreadResponse
    }

    private func loadPersistedThreadCatalogs() {
        guard let data = UserDefaults.standard.data(
            forKey: Self.threadCatalogStorageKey
        ),
        let entries = try? JSONDecoder().decode(
            [PersistedThreadCatalog].self,
            from: data
        ) else {
            return
        }
        for entry in entries {
            threadCatalogs[entry.key] = entry.response
        }
    }

    private func persistThreadCatalogs() {
        guard persistsThreadCatalogs else { return }
        let entries = threadCatalogs.map {
            PersistedThreadCatalog(key: $0.key, response: $0.value)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.threadCatalogStorageKey)
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

    func threads(
        repositoryName: String,
        archived: Bool,
        on worker: ServerProfile
    ) -> [WorkerThreadSnapshot] {
        threadCatalogs[
            WorkerThreadCatalogKey(
                workerID: worker.id,
                repositoryName: repositoryName,
                archived: archived
            )
        ]?.threads ?? []
    }

    func updateWarning(for workerID: UUID) -> String? {
        runtimeMessages[workerID] ?? updateWarnings[workerID]
    }

    func dismissUpdateWarning(for workerID: UUID) {
        if let status = updateStatuses[workerID] {
            dismissedUpdateTimestamps[workerID] = status.timestamp
        }
        updateWarnings[workerID] = nil
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

            let response = withoutRecentlyStopped(
                try WorkerSessionProtocol.parse(result.standardOutput)
            )
            if inspectsRuntimeOnRefresh {
                await inspectRuntime(worker: worker)
            }
            apply(await fetchUpdateStatus(worker: worker), to: worker.id)
            responses[worker.id] = response
            mergeLiveSessionsIntoThreadCatalogs(
                workerID: worker.id,
                sessions: response.sessions
            )
            errors[worker.id] = nil
            workerSessionLogger.info(
                "Session refresh succeeded on \(worker.destination, privacy: .public); found \(response.sessions.count, privacy: .public) sessions"
            )
            return response
        } catch {
            if inspectsRuntimeOnRefresh {
                await inspectRuntime(worker: worker)
            }
            apply(await fetchUpdateStatus(worker: worker), to: worker.id)
            let message = message(for: error, fallback: .statusFailed)
            workerSessionLogger.error(
                "Session refresh failed on \(worker.destination, privacy: .public): \(message, privacy: .public)"
            )
            errors[worker.id] = message
            return nil
        }
    }

    private func inspectRuntime(worker: ServerProfile) async {
        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerRuntimeInfoConfiguration(for: worker)
            )
            guard result.exitCode == 0 else { return }
            let info = try WorkerRuntimeInfoProtocol.parse(result.standardOutput)
            runtimeInfos[worker.id] = info
            if info.isClientProtocolCompatible {
                runtimeMessages[worker.id] = nil
            } else {
                runtimeMessages[worker.id] =
                    "This worker needs a runtime update for the current client. Updating automatically…"
                beginRuntimeUpdate(worker: worker)
            }
            await refreshRuntimeUpdateStatus(worker: worker)
        } catch {
            runtimeInfos[worker.id] = nil
        }
    }

    private func beginRuntimeUpdate(worker: ServerProfile) {
        guard runtimeUpdateTasks[worker.id] == nil else { return }
        runtimeUpdateTasks[worker.id] = Task { [weak self] in
            guard let self else { return }
            defer { runtimeUpdateTasks[worker.id] = nil }
            do {
                let request = try await runCommand(
                    SSHCommandBuilder.workerRuntimeUpdateRequestConfiguration(for: worker)
                )
                let requestOutput = String(decoding: request.standardOutput, as: UTF8.self)
                guard request.exitCode == 0,
                      requestOutput.contains(WorkerRuntimeUpdateStatusProtocol.marker),
                      requestOutput.contains("|accepted")
                else { return }
                runtimeMessages[worker.id] =
                    "This worker needs a runtime update for the current client. Updating automatically…"
                for delay in [1, 2, 4] {
                    try? await Task.sleep(for: .seconds(delay))
                    await refreshRuntimeUpdateStatus(worker: worker)
                    let result = try await runCommand(
                        SSHCommandBuilder.workerRuntimeInfoConfiguration(for: worker)
                    )
                    guard result.exitCode == 0,
                          let info = try? WorkerRuntimeInfoProtocol.parse(result.standardOutput)
                    else { continue }
                    runtimeInfos[worker.id] = info
                    if info.isClientProtocolCompatible {
                        runtimeMessages[worker.id] = nil
                        _ = await refresh(worker: worker)
                        return
                    }
                }
            } catch {
                // The next normal refresh retries through the fixed worker trigger.
            }
        }
    }

    private func refreshRuntimeUpdateStatus(worker: ServerProfile) async {
        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerRuntimeUpdateStatusConfiguration(for: worker)
            )
            guard result.exitCode == 0,
                  let status = try WorkerRuntimeUpdateStatusProtocol.parse(result.standardOutput)
            else { return }
            runtimeUpdateStatuses[worker.id] = status
            if let message = status.message {
                runtimeMessages[worker.id] = message
            }
        } catch {
            return
        }
    }

    private func requireCapability(
        _ capability: String,
        worker: ServerProfile
    ) -> Bool {
        if runtimeInfos[worker.id] == nil, runtimeMessages[worker.id] == nil {
            return true
        }
        guard runtimeInfos[worker.id]?.supports(capability) == true else {
            runtimeMessages[worker.id] =
                "This worker is updating to add the required capability."
            errors[worker.id] = WorkerSessionServiceError.runtimeUpdating.localizedDescription
            beginRuntimeUpdate(worker: worker)
            return false
        }
        return true
    }

    private func fetchUpdateStatus(worker: ServerProfile) async -> WorkerUpdateStatusFetchResult {
        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerUpdateStatusConfiguration(for: worker)
            )
            guard result.exitCode == 0 else { return .unavailable }
            return .loaded(try WorkerUpdateStatusProtocol.parse(result.standardOutput))
        } catch {
            return .unavailable
        }
    }

    private func apply(_ result: WorkerUpdateStatusFetchResult, to workerID: UUID) {
        guard case .loaded(let status) = result else { return }
        guard let status else {
            updateStatuses[workerID] = nil
            updateWarnings[workerID] = nil
            dismissedUpdateTimestamps[workerID] = nil
            return
        }

        updateStatuses[workerID] = status
        guard let warning = status.warningMessage else {
            updateWarnings[workerID] = nil
            dismissedUpdateTimestamps[workerID] = nil
            return
        }
        if dismissedUpdateTimestamps[workerID] != status.timestamp {
            updateWarnings[workerID] = warning
        }
    }

    func start(
        kind: AgentKind,
        repositoryName: String,
        launchDefaults: AgentLaunchDefaults,
        on worker: ServerProfile
    ) async -> WorkerSessionSnapshot? {
        guard requireCapability("agent-sessions", worker: worker) else { return nil }
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
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: kind,
                    repositoryName: repositoryName,
                    threadID: nil,
                    launchDefaults: launchDefaults
                )
            )
            if result.exitCode == 64 {
                throw WorkerSessionServiceError.nativeChatUnavailable
            }
            guard result.exitCode == 0 else {
                workerSessionLogger.error(
                    "Session start failed for \(kind.rawValue, privacy: .public) on \(worker.destination, privacy: .public) with status \(result.exitCode, privacy: .public): \(Self.logDetail(result.standardError), privacy: .public)"
                )
                throw WorkerSessionServiceError.startFailed
            }

            let chat = try WorkerChatProtocol.parseStart(
                result.standardOutput,
                expectedKind: kind
            )
            let snapshot = WorkerSessionSnapshot(
                kind: kind,
                repositoryName: repositoryName,
                attachedClientCount: 0,
                instanceToken: chat.relayID,
                reportedWorking: false,
                threadID: chat.providerThreadID,
                presentation: .chat
            )
            let response = WorkerSessionResponse(
                projects: [repositoryName],
                sessions: [snapshot]
            )

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
        presentation: WorkerSessionPresentation = .terminal,
        on worker: ServerProfile
    ) async -> Bool {
        guard requireCapability("agent-sessions", worker: worker) else { return false }
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
            let configuration: SSHLaunchConfiguration
            switch presentation {
            case .terminal:
                configuration = SSHCommandBuilder.workerSessionStopConfiguration(
                    for: worker,
                    kind: kind,
                    repositoryName: repositoryName,
                    instanceToken: instanceToken
                )
            case .chat:
                configuration = SSHCommandBuilder.workerChatStopConfiguration(
                    for: worker,
                    kind: kind,
                    repositoryName: repositoryName,
                    instanceToken: instanceToken
                )
            }
            let result = try await runCommand(
                configuration
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
            stoppedSessionTombstones[instanceToken] = Date()
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
                presentation: snapshot.presentation,
                on: worker
            ) else {
                return false
            }
        }
        return true
    }

    @discardableResult
    func loadThreads(
        repositoryName: String,
        archived: Bool,
        on worker: ServerProfile,
        skipIfFresh: Bool = false
    ) async -> WorkerThreadResponse? {
        let catalogKey = WorkerThreadCatalogKey(
            workerID: worker.id,
            repositoryName: repositoryName,
            archived: archived
        )
        if skipIfFresh,
           let fetchedAt = threadCatalogFetchTimes[catalogKey],
           Date().timeIntervalSince(fetchedAt) < Self.threadCatalogFreshness,
           let cached = threadCatalogs[catalogKey] {
            return cached
        }
        guard requireCapability("threads-v2", worker: worker) else { return nil }
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
        do {
            var remainingCursor: String?
            var threads: [WorkerThreadSnapshot] = []
            for kind in AgentKind.allCases {
                var cursor: String?
                var pages = 0
                repeat {
                    let result = try await runCommand(
                        SSHCommandBuilder.workerThreadListConfiguration(
                            for: worker,
                            kind: kind,
                            repositoryName: repositoryName,
                            archived: archived,
                            cursor: cursor
                        )
                    )
                    guard result.exitCode == 0 else {
                        throw WorkerSessionServiceError.threadFailed
                    }
                    let page = try WorkerThreadProtocol.parse(
                        result.standardOutput,
                        repositoryName: repositoryName
                    )
                    guard page.threads.allSatisfy({ $0.kind == kind }) else {
                        throw WorkerSessionServiceError.threadFailed
                    }
                    threads.append(contentsOf: page.threads)
                    cursor = page.nextCursor
                    pages += 1
                } while cursor != nil && pages < 20
                if cursor != nil {
                    remainingCursor = cursor
                }
            }

            var threadsByID: [String: WorkerThreadSnapshot] = [:]
            for thread in threads {
                threadsByID[thread.id] = thread
            }
            var response = WorkerThreadResponse(
                threads: threadsByID.values.sorted {
                    if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                    return $0.threadID < $1.threadID
                },
                nextCursor: remainingCursor
            )
            if !archived {
                response = response.merging(
                    liveSessions: responses[worker.id]?.sessions.filter {
                        $0.repositoryName == repositoryName
                    } ?? []
                )
                response = withoutRecentlyArchived(response, workerID: worker.id)
            }
            threadCatalogs[catalogKey] = response
            threadCatalogFetchTimes[catalogKey] = Date()
            persistThreadCatalogs()
            errors[worker.id] = nil
            return response
        } catch {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
    }

    func createThread(
        repositoryName: String,
        on worker: ServerProfile
    ) async -> WorkerThreadSnapshot? {
        guard requireCapability("threads-v2", worker: worker) else { return nil }
        return await mutateThreadCatalog(
            configuration: SSHCommandBuilder.workerThreadCreateConfiguration(
                for: worker,
                repositoryName: repositoryName
            ),
            repositoryName: repositoryName,
            on: worker
        )
    }

    func resumeThread(
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        launchDefaults: AgentLaunchDefaults,
        on worker: ServerProfile
    ) async -> WorkerSessionSnapshot? {
        guard requireCapability("threads-v2", worker: worker) else { return nil }
        guard Self.isCanonicalUUID(threadID) else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: kind,
                    repositoryName: repositoryName,
                    threadID: threadID,
                    launchDefaults: launchDefaults
                )
            )
            if result.exitCode == 64 {
                throw WorkerSessionServiceError.nativeChatUnavailable
            }
            guard result.exitCode == 0 else {
                throw WorkerSessionServiceError.threadFailed
            }
            let chat = try WorkerChatProtocol.parseStart(
                result.standardOutput,
                expectedKind: kind
            )
            guard chat.providerThreadID == threadID else {
                throw WorkerSessionServiceError.threadFailed
            }
            let snapshot = WorkerSessionSnapshot(
                kind: kind,
                repositoryName: repositoryName,
                attachedClientCount: 0,
                instanceToken: chat.relayID,
                reportedWorking: false,
                threadID: chat.providerThreadID,
                presentation: .chat
            )
            let current = responses[worker.id] ?? WorkerSessionResponse(
                projects: [repositoryName],
                sessions: []
            )
            responses[worker.id] = WorkerSessionResponse(
                projects: Array(Set(current.projects + [repositoryName])).sorted {
                    $0.localizedStandardCompare($1) == .orderedAscending
                },
                sessions: (current.sessions.filter {
                    $0.instanceToken != snapshot.instanceToken
                } + [snapshot]).sorted {
                    if $0.repositoryName != $1.repositoryName {
                        return $0.repositoryName.localizedStandardCompare($1.repositoryName)
                            == .orderedAscending
                    }
                    return $0.instanceToken < $1.instanceToken
                }
            )
            mergeLiveSessionsIntoThreadCatalogs(
                workerID: worker.id,
                sessions: responses[worker.id]?.sessions ?? []
            )
            errors[worker.id] = nil
            return snapshot
        } catch {
            errors[worker.id] = message(for: error, fallback: .threadFailed)
            return nil
        }
    }

    @discardableResult
    func renameThread(
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        name: String,
        on worker: ServerProfile
    ) async -> Bool {
        guard requireCapability("threads-v2", worker: worker) else { return false }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isCanonicalUUID(threadID), !normalized.isEmpty,
              !normalized.contains("\n"), normalized.utf8.count <= 200 else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return false
        }
        return await mutateThreadCatalog(
            configuration: SSHCommandBuilder.workerThreadRenameConfiguration(
                for: worker,
                kind: kind,
                repositoryName: repositoryName,
                threadID: threadID,
                name: normalized
            ),
            repositoryName: repositoryName,
            on: worker
        ) != nil
    }

    @discardableResult
    func setThreadArchived(
        kind: AgentKind,
        repositoryName: String,
        threadID: String,
        archived: Bool,
        on worker: ServerProfile
    ) async -> Bool {
        guard requireCapability("threads-v2", worker: worker) else { return false }
        guard Self.isCanonicalUUID(threadID) else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return false
        }
        guard await mutateThreadCatalog(
            configuration: SSHCommandBuilder.workerThreadArchiveConfiguration(
                for: worker,
                kind: kind,
                repositoryName: repositoryName,
                threadID: threadID,
                unarchive: !archived
            ),
            repositoryName: repositoryName,
            on: worker
        ) != nil else {
            return false
        }
        let tombstoneKey = Self.threadTombstoneKey(
            workerID: worker.id,
            kind: kind,
            threadID: threadID
        )
        if archived {
            archivedThreadTombstones[tombstoneKey] = Date()
        } else {
            archivedThreadTombstones.removeValue(forKey: tombstoneKey)
        }
        _ = await loadThreads(repositoryName: repositoryName, archived: false, on: worker)
        _ = await loadThreads(repositoryName: repositoryName, archived: true, on: worker)
        return true
    }

    private func mutateThreadCatalog(
        configuration: SSHLaunchConfiguration,
        repositoryName: String,
        on worker: ServerProfile
    ) async -> WorkerThreadSnapshot? {
        do {
            let result = try await runCommand(configuration)
            guard result.exitCode == 0 else {
                throw WorkerSessionServiceError.threadFailed
            }
            let response = try WorkerThreadProtocol.parse(
                result.standardOutput,
                repositoryName: repositoryName
            )
            guard response.threads.count == 1, let thread = response.threads.first else {
                throw WorkerSessionServiceError.threadFailed
            }
            errors[worker.id] = nil
            return thread
        } catch {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        UUID(uuidString: value)?.uuidString.lowercased() == value
    }

    private func mergeLiveSessionsIntoThreadCatalogs(
        workerID: UUID,
        sessions: [WorkerSessionSnapshot]
    ) {
        let keys = threadCatalogs.keys.filter {
            $0.workerID == workerID && !$0.archived
        }
        for key in keys {
            guard let catalog = threadCatalogs[key] else { continue }
            threadCatalogs[key] = withoutRecentlyArchived(
                catalog.merging(
                    liveSessions: sessions.filter {
                        $0.repositoryName == key.repositoryName
                    }
                ),
                workerID: workerID
            )
        }
    }

    private static func threadTombstoneKey(
        workerID: UUID,
        kind: AgentKind,
        threadID: String
    ) -> String {
        "\(workerID.uuidString):\(kind.rawValue):\(threadID)"
    }

    private func pruneTombstones() {
        let cutoff = Date().addingTimeInterval(-Self.tombstoneLifetime)
        stoppedSessionTombstones = stoppedSessionTombstones.filter { $0.value > cutoff }
        archivedThreadTombstones = archivedThreadTombstones.filter { $0.value > cutoff }
    }

    private func withoutRecentlyStopped(
        _ response: WorkerSessionResponse
    ) -> WorkerSessionResponse {
        pruneTombstones()
        guard !stoppedSessionTombstones.isEmpty else { return response }
        return WorkerSessionResponse(
            projects: response.projects,
            sessions: response.sessions.filter {
                stoppedSessionTombstones[$0.instanceToken] == nil
            }
        )
    }

    private func withoutRecentlyArchived(
        _ response: WorkerThreadResponse,
        workerID: UUID
    ) -> WorkerThreadResponse {
        pruneTombstones()
        guard !archivedThreadTombstones.isEmpty else { return response }
        return WorkerThreadResponse(
            threads: response.threads.filter {
                archivedThreadTombstones[
                    Self.threadTombstoneKey(
                        workerID: workerID,
                        kind: $0.kind,
                        threadID: $0.threadID
                    )
                ] == nil
            },
            nextCursor: response.nextCursor
        )
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
