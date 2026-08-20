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
    @Published private(set) var threadErrors: [ProviderAccountKey: String] = [:]

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
    // Sessions this client just started, per worker. A periodic refresh
    // whose listing was captured on the worker before the chat-start
    // completed would otherwise erase the optimistic snapshot, demote its
    // thread back to dormant, and resurrect the duplicate row. Entries are
    // dropped once a listing confirms the token, on stop, or after the
    // lifetime.
    private var startedSessionGuards: [UUID: [String: (snapshot: WorkerSessionSnapshot, at: Date)]] = [:]
    private static let startedSessionGuardLifetime: TimeInterval = 60
    private var threadLoadTasks: [WorkerThreadCatalogKey: Task<WorkerThreadResponse?, Never>] = [:]

    // Accountless v1 caches cannot be attributed safely. New keys make the
    // migration an invalidation instead of guessing an owner.
    private static let threadCatalogStorageKey = "workerThreadCatalogs.v2"
    private static let sessionResponseStorageKey = "workerSessionResponses.v2"
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
            loadPersistedSessionResponses()
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

    /// Cached session responses let the sidebar render a worker's last-known
    /// session rows immediately at launch; the first SSH refresh reconciles
    /// them. Attachment and working state are transient, so they reset on load.
    private struct PersistedSessionResponse: Codable {
        let workerID: UUID
        let response: WorkerSessionResponse
    }

    private func loadPersistedSessionResponses() {
        guard let data = UserDefaults.standard.data(
            forKey: Self.sessionResponseStorageKey
        ),
        let entries = try? JSONDecoder().decode(
            [PersistedSessionResponse].self,
            from: data
        ) else {
            return
        }
        for entry in entries {
            responses[entry.workerID] = WorkerSessionResponse(
                projects: entry.response.projects,
                sessions: entry.response.sessions.map {
                    WorkerSessionSnapshot(
                        kind: $0.kind,
                        accountID: $0.accountID,
                        repositoryName: $0.repositoryName,
                        attachedClientCount: 0,
                        instanceToken: $0.instanceToken,
                        title: $0.title,
                        lastActivityAt: $0.lastActivityAt == 0 ? nil : $0.lastActivityAt,
                        reportedWorking: nil,
                        threadID: $0.threadID,
                        presentation: $0.presentation
                    )
                }
            )
        }
    }

    private func persistSessionResponses() {
        guard persistsThreadCatalogs else { return }
        let entries = responses.map {
            PersistedSessionResponse(workerID: $0.key, response: $0.value)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionResponseStorageKey)
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
        on worker: ServerProfile,
        account: ProviderAccountProfile? = nil
    ) -> [WorkerThreadSnapshot] {
        if let account {
            return threadCatalogs[
                WorkerThreadCatalogKey(
                    workerID: worker.id,
                    provider: account.provider,
                    accountID: account.accountID,
                    repositoryName: repositoryName,
                    archived: archived
                )
            ]?.threads ?? []
        }
        let matching = threadCatalogs.filter {
            $0.key.workerID == worker.id
                && $0.key.repositoryName == repositoryName
                && $0.key.archived == archived
        }
        var byID: [String: WorkerThreadSnapshot] = [:]
        for response in matching.values {
            for thread in response.threads { byID[thread.id] = thread }
        }
        return byID.values.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
    }

    func threadError(
        workerID: UUID,
        account: ProviderAccountProfile
    ) -> String? {
        threadErrors[
            ProviderAccountKey(
                workerID: workerID,
                provider: account.provider,
                accountID: account.accountID
            )
        ]
    }

    func dismissThreadError(
        workerID: UUID,
        account: ProviderAccountProfile
    ) {
        threadErrors[
            ProviderAccountKey(
                workerID: workerID,
                provider: account.provider,
                accountID: account.accountID
            )
        ] = nil
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

    func isStopping(
        worker: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> Bool {
        stoppingSlots.contains(
            SessionSlot(
                serverKey: worker.concurrencyKey,
                kind: kind,
                accountID: accountID
            )
        )
    }

    func isStarting(
        worker: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> Bool {
        startingSlots.contains(
            SessionSlot(
                serverKey: worker.concurrencyKey,
                kind: kind,
                accountID: accountID
            )
        )
    }

    @discardableResult
    func refresh(worker: ServerProfile) async -> WorkerSessionResponse? {
        // Await an in-flight refresh instead of bailing with nil: callers
        // like the archive flow treat nil as failure, so a collision with
        // the periodic loop used to silently no-op the user's action.
        await refreshCoalescing(worker: worker)
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

            let response = withRecentlyStarted(
                withoutRecentlyStopped(
                    try WorkerSessionProtocol.parse(result.standardOutput)
                ),
                workerID: worker.id
            )
            if inspectsRuntimeOnRefresh {
                await inspectRuntime(worker: worker)
            }
            apply(await fetchUpdateStatus(worker: worker), to: worker.id)
            responses[worker.id] = response
            persistSessionResponses()
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
        account: ProviderAccountProfile? = nil,
        repositoryName: String,
        launchDefaults: AgentLaunchDefaults,
        on worker: ServerProfile
    ) async -> WorkerSessionSnapshot? {
        guard requireCapability("agent-sessions", worker: worker) else { return nil }
        guard account.map({ $0.provider == kind && $0.status.isUsable }) != false else {
            errors[worker.id] = WorkerSessionServiceError.startFailed.localizedDescription
            return nil
        }
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errors[worker.id] = WorkerSessionServiceError.startFailed.localizedDescription
            return nil
        }

        let slot = SessionSlot(
            serverKey: worker.concurrencyKey,
            kind: kind,
            accountID: account?.accountID
        )
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
                    accountID: account?.accountID,
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
                expectedKind: kind,
                expectedAccountID: account?.accountID
            )
            let snapshot = WorkerSessionSnapshot(
                kind: kind,
                accountID: account?.accountID,
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
            startedSessionGuards[worker.id, default: [:]][snapshot.instanceToken] =
                (snapshot: snapshot, at: Date())
            persistSessionResponses()
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
        accountID: ProviderAccountID? = nil,
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

        let slot = SessionSlot(
            serverKey: worker.concurrencyKey,
            kind: kind,
            accountID: accountID
        )
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
                    accountID: accountID,
                    repositoryName: repositoryName,
                    instanceToken: instanceToken
                )
            case .chat:
                configuration = SSHCommandBuilder.workerChatStopConfiguration(
                    for: worker,
                    kind: kind,
                    accountID: accountID,
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
                            || $0.accountID != accountID
                            || $0.repositoryName != repositoryName
                            || $0.instanceToken != instanceToken
                    }
                )
                responses[worker.id] = response
                persistSessionResponses()
                // Demote the stopped conversation's thread back to dormant
                // right away; leaving it relay-active until the next
                // periodic refresh hides the conversation entirely (no
                // session row, no thread row).
                mergeLiveSessionsIntoThreadCatalogs(
                    workerID: worker.id,
                    sessions: response.sessions
                )
            }
            startedSessionGuards[worker.id]?[instanceToken] = nil
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
        account: ProviderAccountProfile,
        on worker: ServerProfile
    ) async -> Bool {
        guard let response = await refreshCoalescing(worker: worker) else {
            return false
        }

        for snapshot in response.sessions
        where snapshot.kind == account.provider
            && snapshot.accountID == account.accountID {
            guard await stop(
                kind: account.provider,
                accountID: account.accountID,
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

    /// Pre-activation compatibility only. Account-management UI must never
    /// call this because replacing one provider login is no longer a global
    /// operation.
    @available(*, deprecated, message: "Stop one explicit provider account instead.")
    @discardableResult
    func stopActiveSessions(
        kind: AgentKind,
        on worker: ServerProfile
    ) async -> Bool {
        guard let response = await refreshCoalescing(worker: worker) else {
            return false
        }
        for snapshot in response.sessions
        where snapshot.kind == kind && snapshot.accountID == nil {
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
        account: ProviderAccountProfile? = nil,
        skipIfFresh: Bool = false
    ) async -> WorkerThreadResponse? {
        let catalogKey = WorkerThreadCatalogKey(
            workerID: worker.id,
            provider: account?.provider,
            accountID: account?.accountID,
            repositoryName: repositoryName,
            archived: archived
        )
        if skipIfFresh,
           let fetchedAt = threadCatalogFetchTimes[catalogKey],
           Date().timeIntervalSince(fetchedAt) < Self.threadCatalogFreshness,
           let cached = threadCatalogs[catalogKey] {
            return cached
        }
        guard requireCapability(account == nil ? "threads-v2" : "provider-accounts-v1", worker: worker) else {
            return nil
        }
        guard account.map({ $0.status.isUsable }) != false else {
            if let account {
                threadErrors[
                    ProviderAccountKey(
                        workerID: worker.id,
                        provider: account.provider,
                        accountID: account.accountID
                    )
                ] = WorkerSessionServiceError.threadFailed.localizedDescription
            }
            return nil
        }
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
        // One fetch per catalog key at a time: concurrent fetches could land
        // out of order and let an older listing overwrite a newer one. A
        // freshness-tolerant caller shares the in-flight result; a forced
        // caller (after a mutation) runs behind it so its listing postdates
        // the mutation.
        if let inFlight = threadLoadTasks[catalogKey] {
            if skipIfFresh {
                return await inFlight.value
            }
            _ = await inFlight.value
        }
        let task = Task { [weak self] () -> WorkerThreadResponse? in
            guard let self else { return nil }
            defer { self.threadLoadTasks[catalogKey] = nil }
            return await self.fetchThreads(
                catalogKey: catalogKey,
                repositoryName: repositoryName,
                archived: archived,
                route: account.map { ($0.provider, $0.accountID) },
                on: worker
            )
        }
        threadLoadTasks[catalogKey] = task
        return await task.value
    }

    /// Loads every selected route independently. Successful account catalogs
    /// remain visible when another account is signed out or unavailable.
    @discardableResult
    func loadThreads(
        repositoryName: String,
        archived: Bool,
        on worker: ServerProfile,
        accounts: [ProviderAccountProfile],
        skipIfFresh: Bool = false
    ) async -> WorkerThreadResponse? {
        var seenRoutes: Set<String> = []
        for account in accounts where !account.status.isUsable {
            threadErrors[
                ProviderAccountKey(
                    workerID: worker.id,
                    provider: account.provider,
                    accountID: account.accountID
                )
            ] = account.status == .authRequired
                ? "Sign in to load this account's tasks."
                : "This account is unavailable."
        }
        let usable = accounts.filter {
            $0.status.isUsable && seenRoutes.insert($0.routeKey).inserted
        }
        guard !usable.isEmpty else {
            return WorkerThreadResponse(threads: [], nextCursor: nil)
        }
        var successes: [WorkerThreadResponse] = []
        for account in usable {
            if let response = await loadThreads(
                repositoryName: repositoryName,
                archived: archived,
                on: worker,
                account: account,
                skipIfFresh: skipIfFresh
            ) {
                successes.append(response)
            }
        }
        guard !successes.isEmpty else { return nil }
        var byID: [String: WorkerThreadSnapshot] = [:]
        for response in successes {
            for thread in response.threads { byID[thread.id] = thread }
        }
        return WorkerThreadResponse(
            threads: byID.values.sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            },
            nextCursor: successes.compactMap(\.nextCursor).first
        )
    }

    private func fetchThreads(
        catalogKey: WorkerThreadCatalogKey,
        repositoryName: String,
        archived: Bool,
        route: (kind: AgentKind, accountID: ProviderAccountID)?,
        on worker: ServerProfile
    ) async -> WorkerThreadResponse? {
        // The listing's content is as-of the fetch start; the archive
        // tombstones compare against this to tell a stale capture from a
        // genuine post-archive state.
        let fetchStartedAt = Date()
        do {
            var remainingCursor: String?
            var threads: [WorkerThreadSnapshot] = []
            let routes: [(kind: AgentKind, accountID: ProviderAccountID?)] = route.map {
                [($0.kind, $0.accountID)]
            } ?? AgentKind.allCases.map { ($0, nil) }
            for route in routes {
                var cursor: String?
                var pages = 0
                repeat {
                    let result = try await runCommand(
                        SSHCommandBuilder.workerThreadListConfiguration(
                            for: worker,
                            kind: route.kind,
                            accountID: route.accountID,
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
                        repositoryName: repositoryName,
                        expectedAccountID: route.accountID
                    )
                    guard page.threads.allSatisfy({
                        $0.kind == route.kind && $0.accountID == route.accountID
                    }) else {
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
                            && $0.accountID == route?.accountID
                            && (route == nil || $0.kind == route?.kind)
                    } ?? []
                )
                response = withoutRecentlyArchived(
                    response,
                    workerID: worker.id,
                    fetchedAt: fetchStartedAt
                )
            }
            threadCatalogs[catalogKey] = response
            threadCatalogFetchTimes[catalogKey] = fetchStartedAt
            persistThreadCatalogs()
            if let route {
                threadErrors[
                    ProviderAccountKey(
                        workerID: worker.id,
                        provider: route.kind,
                        accountID: route.accountID
                    )
                ] = nil
            } else {
                errors[worker.id] = nil
            }
            return response
        } catch {
            let message = WorkerSessionServiceError.threadFailed.localizedDescription
            if let route {
                threadErrors[
                    ProviderAccountKey(
                        workerID: worker.id,
                        provider: route.kind,
                        accountID: route.accountID
                    )
                ] = message
            } else {
                errors[worker.id] = message
            }
            return nil
        }
    }

    func createThread(
        repositoryName: String,
        on worker: ServerProfile,
        account: ProviderAccountProfile? = nil
    ) async -> WorkerThreadSnapshot? {
        guard requireCapability(account == nil ? "threads-v2" : "provider-accounts-v1", worker: worker) else {
            return nil
        }
        guard account.map({ $0.provider == .codex && $0.status.isUsable }) != false else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
        return await mutateThreadCatalog(
            configuration: SSHCommandBuilder.workerThreadCreateConfiguration(
                for: worker,
                accountID: account?.accountID,
                repositoryName: repositoryName
            ),
            repositoryName: repositoryName,
            expectedAccountID: account?.accountID,
            on: worker
        )
    }

    func resumeThread(
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        launchDefaults: AgentLaunchDefaults,
        on worker: ServerProfile
    ) async -> WorkerSessionSnapshot? {
        guard requireCapability(accountID == nil ? "threads-v2" : "provider-accounts-v1", worker: worker) else {
            return nil
        }
        guard Self.isCanonicalUUID(threadID) else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return nil
        }
        do {
            let result = try await runCommand(
                SSHCommandBuilder.workerChatStartConfiguration(
                    for: worker,
                    kind: kind,
                    accountID: accountID,
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
                expectedKind: kind,
                expectedAccountID: accountID
            )
            guard chat.providerThreadID == threadID else {
                throw WorkerSessionServiceError.threadFailed
            }
            let snapshot = WorkerSessionSnapshot(
                kind: kind,
                accountID: accountID,
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
            startedSessionGuards[worker.id, default: [:]][snapshot.instanceToken] =
                (snapshot: snapshot, at: Date())
            persistSessionResponses()
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

    func resumeThread(
        _ thread: WorkerThreadSnapshot,
        launchDefaults: AgentLaunchDefaults,
        on worker: ServerProfile
    ) async -> WorkerSessionSnapshot? {
        await resumeThread(
            kind: thread.kind,
            accountID: thread.accountID,
            repositoryName: thread.repositoryName,
            threadID: thread.threadID,
            launchDefaults: launchDefaults,
            on: worker
        )
    }

    @discardableResult
    func renameThread(
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        name: String,
        on worker: ServerProfile
    ) async -> Bool {
        guard requireCapability(accountID == nil ? "threads-v2" : "provider-accounts-v1", worker: worker) else {
            return false
        }
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
                accountID: accountID,
                repositoryName: repositoryName,
                threadID: threadID,
                name: normalized
            ),
            repositoryName: repositoryName,
            expectedAccountID: accountID,
            on: worker
        ) != nil
    }

    @discardableResult
    func renameThread(
        _ thread: WorkerThreadSnapshot,
        name: String,
        on worker: ServerProfile
    ) async -> Bool {
        await renameThread(
            kind: thread.kind,
            accountID: thread.accountID,
            repositoryName: thread.repositoryName,
            threadID: thread.threadID,
            name: name,
            on: worker
        )
    }

    @discardableResult
    func setThreadArchived(
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        archived: Bool,
        on worker: ServerProfile
    ) async -> Bool {
        guard requireCapability(accountID == nil ? "threads-v2" : "provider-accounts-v1", worker: worker) else {
            return false
        }
        guard Self.isCanonicalUUID(threadID) else {
            errors[worker.id] = WorkerSessionServiceError.threadFailed.localizedDescription
            return false
        }
        guard await mutateThreadCatalog(
            configuration: SSHCommandBuilder.workerThreadArchiveConfiguration(
                for: worker,
                kind: kind,
                accountID: accountID,
                repositoryName: repositoryName,
                threadID: threadID,
                unarchive: !archived
            ),
            repositoryName: repositoryName,
            expectedAccountID: accountID,
            on: worker
        ) != nil else {
            return false
        }
        let tombstoneKey = Self.threadTombstoneKey(
            workerID: worker.id,
            kind: kind,
            accountID: accountID,
            threadID: threadID
        )
        if archived {
            archivedThreadTombstones[tombstoneKey] = Date()
        } else {
            archivedThreadTombstones.removeValue(forKey: tombstoneKey)
        }
        if let accountID {
            // Catalog keys already retain the route. Refresh the exact key
            // directly without manufacturing mutable account metadata.
            _ = await reloadThreadCatalog(
                worker: worker,
                kind: kind,
                accountID: accountID,
                repositoryName: repositoryName,
                archived: false
            )
            _ = await reloadThreadCatalog(
                worker: worker,
                kind: kind,
                accountID: accountID,
                repositoryName: repositoryName,
                archived: true
            )
        } else {
            _ = await loadThreads(repositoryName: repositoryName, archived: false, on: worker)
            _ = await loadThreads(repositoryName: repositoryName, archived: true, on: worker)
        }
        return true
    }

    @discardableResult
    func setThreadArchived(
        _ thread: WorkerThreadSnapshot,
        archived: Bool,
        on worker: ServerProfile
    ) async -> Bool {
        await setThreadArchived(
            kind: thread.kind,
            accountID: thread.accountID,
            repositoryName: thread.repositoryName,
            threadID: thread.threadID,
            archived: archived,
            on: worker
        )
    }

    private func mutateThreadCatalog(
        configuration: SSHLaunchConfiguration,
        repositoryName: String,
        expectedAccountID: ProviderAccountID? = nil,
        on worker: ServerProfile
    ) async -> WorkerThreadSnapshot? {
        do {
            let result = try await runCommand(configuration)
            guard result.exitCode == 0 else {
                throw WorkerSessionServiceError.threadFailed
            }
            let response = try WorkerThreadProtocol.parse(
                result.standardOutput,
                repositoryName: repositoryName,
                expectedAccountID: expectedAccountID
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

    private func reloadThreadCatalog(
        worker: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID,
        repositoryName: String,
        archived: Bool
    ) async -> WorkerThreadResponse? {
        let key = WorkerThreadCatalogKey(
            workerID: worker.id,
            provider: kind,
            accountID: accountID,
            repositoryName: repositoryName,
            archived: archived
        )
        if let inFlight = threadLoadTasks[key] {
            _ = await inFlight.value
        }
        let task = Task { [weak self] () -> WorkerThreadResponse? in
            guard let self else { return nil }
            defer { self.threadLoadTasks[key] = nil }
            return await self.fetchThreads(
                catalogKey: key,
                repositoryName: repositoryName,
                archived: archived,
                route: (kind, accountID),
                on: worker
            )
        }
        threadLoadTasks[key] = task
        return await task.value
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
                            && $0.accountID == key.accountID
                    }
                ),
                workerID: workerID,
                // Re-merged content is only as fresh as the catalog's own
                // fetch; a persisted catalog with no recorded fetch is
                // treated as arbitrarily stale.
                fetchedAt: threadCatalogFetchTimes[key] ?? .distantPast
            )
        }
        // Persist the promotion: a cached catalog that still says "inactive"
        // next to a cached live session replays the duplicate row at launch.
        persistThreadCatalogs()
    }

    private static func threadTombstoneKey(
        workerID: UUID,
        kind: AgentKind,
        accountID: ProviderAccountID?,
        threadID: String
    ) -> String {
        "\(workerID.uuidString):\(kind.rawValue):\(accountID?.rawValue ?? "legacy"):\(threadID)"
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

    /// Re-injects sessions this client just started into a listing that was
    /// captured on the worker before the start completed; without this, the
    /// stale listing erases the optimistic row and its thread promotion.
    private func withRecentlyStarted(
        _ response: WorkerSessionResponse,
        workerID: UUID
    ) -> WorkerSessionResponse {
        let cutoff = Date().addingTimeInterval(-Self.startedSessionGuardLifetime)
        var guards = (startedSessionGuards[workerID] ?? [:]).filter {
            $0.value.at > cutoff
        }
        defer { startedSessionGuards[workerID] = guards.isEmpty ? nil : guards }
        guard !guards.isEmpty else { return response }
        let listedTokens = Set(response.sessions.map(\.instanceToken))
        var preserved: [WorkerSessionSnapshot] = []
        for (token, entry) in guards {
            if listedTokens.contains(token) {
                guards[token] = nil
            } else if stoppedSessionTombstones[token] == nil {
                preserved.append(entry.snapshot)
            }
        }
        guard !preserved.isEmpty else { return response }
        return WorkerSessionResponse(
            projects: response.projects,
            sessions: (response.sessions + preserved).sorted {
                if $0.repositoryName != $1.repositoryName {
                    return $0.repositoryName.localizedStandardCompare($1.repositoryName)
                        == .orderedAscending
                }
                return $0.instanceToken < $1.instanceToken
            }
        )
    }

    private func withoutRecentlyArchived(
        _ response: WorkerThreadResponse,
        workerID: UUID,
        fetchedAt: Date
    ) -> WorkerThreadResponse {
        pruneTombstones()
        guard !archivedThreadTombstones.isEmpty else { return response }
        return WorkerThreadResponse(
            threads: response.threads.filter { thread in
                guard let archivedAt = archivedThreadTombstones[
                    Self.threadTombstoneKey(
                        workerID: workerID,
                        kind: thread.kind,
                        accountID: thread.accountID,
                        threadID: thread.threadID
                    )
                ] else { return true }
                // A listing fetched after the archive is authoritative: it
                // either confirms the archive (thread absent) or reports a
                // genuine unarchive from another client. Only listings that
                // may predate the archive are vetoed.
                return fetchedAt > archivedAt
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
