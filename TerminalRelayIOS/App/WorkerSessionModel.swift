import Combine
import Foundation

struct TerminalRoute: Identifiable, Equatable {
    let id = UUID()
    let kind: AgentKind
    let repositoryName: String
    let instanceToken: String?
    let providerThreadID: String?
    let presentation: WorkerSessionPresentation?

    init(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String?,
        providerThreadID: String? = nil,
        presentation: WorkerSessionPresentation? = nil
    ) {
        self.kind = kind
        self.repositoryName = repositoryName
        self.instanceToken = instanceToken
        self.providerThreadID = providerThreadID
        self.presentation = presentation
    }
}

enum WorkerSessionModelError: LocalizedError, Equatable {
    case sessionEnded(kind: AgentKind, repositoryName: String)
    case sessionChanged(kind: AgentKind, repositoryName: String)

    var errorDescription: String? {
        switch self {
        case .sessionEnded(let kind, let repositoryName):
            "The \(kind.displayName) session in \(repositoryName) is no longer running. Refresh before trying again."
        case .sessionChanged(let kind, let repositoryName):
            "The \(kind.displayName) session in \(repositoryName) changed. Refresh before stopping the new session."
        }
    }
}

enum WorkerProjectCatalog {
    private static let excludedProjectNames = Set(["terminal-relay"])

    static func visibleProjectNames(
        discoveredProjects: [String],
        sessions: [WorkerSessionSnapshot]
    ) -> [String] {
        Set(discoveredProjects + sessions.map(\.repositoryName))
            .filter { !excludedProjectNames.contains($0.lowercased()) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

@MainActor
final class WorkerSessionModel: ObservableObject {
    @Published private(set) var profiles: [WorkerProfile]
    @Published private(set) var profile: WorkerProfile?
    @Published private(set) var projects: [String] = []
    @Published private(set) var sessions: [WorkerSessionSnapshot] = []
    @Published private(set) var threadCatalogs: [WorkerThreadCatalogKey: WorkerThreadResponse] = [:]
    @Published private(set) var workerOverviews: [UUID: WorkerOverviewSnapshot] = [:]
    @Published private(set) var workerLoadingIDs: Set<UUID> = []
    @Published private(set) var projectLoadingIDs: Set<UUID> = []
    @Published private var dismissedUpdateTimestamps: [UUID: Int] = [:]
    @Published private(set) var publicKey = ""
    @Published private(set) var isLoading = false
    @Published private(set) var isPairing = false
    @Published private(set) var isDemoMode: Bool
    @Published var errorMessage: String?
    @Published var terminalRoute: TerminalRoute?

    private let profileStore: WorkerProfileStore
    private let identityStore: SSHIdentityStore
    private let workerClient: SSHWorkerClient
    private let pairingClient: MobilePairingClient
    private let readStateDefaults: UserDefaults
    private var readActivityBySession: [String: Int]
    private var lastOpenedTerminalRoute: TerminalRoute?
    private var runtimeUpdateTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshToken = UUID()
    private static let readStateKey = "workerSessionReadActivity.v1"
    private static let connectionFailureMessage =
        "Could not reach this worker. Check that it is online, then try again."

    init(
        profileStore: WorkerProfileStore = WorkerProfileStore(),
        identityStore: SSHIdentityStore = SSHIdentityStore(),
        readStateDefaults: UserDefaults = .standard,
        screenshotDemo: Bool = false
    ) {
        self.profileStore = profileStore
        self.identityStore = identityStore
        self.workerClient = SSHWorkerClient(identityStore: identityStore)
        self.pairingClient = MobilePairingClient(identityStore: identityStore)
        self.readStateDefaults = readStateDefaults
        self.isDemoMode = screenshotDemo
        self.readActivityBySession = Self.loadReadState(from: readStateDefaults)
        let profiles: [WorkerProfile]
        if screenshotDemo {
            profiles = [DemoWorkspace.worker]
        } else {
            profiles = profileStore.load()
        }
        self.profiles = profiles
        self.profile = profileStore.selectedProfileID()
            .flatMap { selectedID in profiles.first { $0.id == selectedID } }
            ?? profiles.first

        if screenshotDemo {
            projects = DemoWorkspace.projects
            sessions = DemoWorkspace.sessions
            workerOverviews = [DemoWorkspace.worker.id: DemoWorkspace.overview]
            loadDemoThreads()
            publicKey = "ssh-ed25519 screenshot-demo-device"
            return
        }

        do {
            self.publicKey = try identityStore.publicKeyForAuthorizedKeys()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func pair(with code: String) async -> Bool {
        guard !isPairing else { return false }
        isPairing = true
        errorMessage = nil
        defer { isPairing = false }

        do {
            let payload = try MobilePairingPayloadCodec.decode(code)
            let existingProfileID = profiles.first {
                $0.host.caseInsensitiveCompare(payload.host) == .orderedSame
                    && $0.port == payload.port
                    && $0.username == payload.username
            }?.id
            let pairedProfile = try await pairingClient.pair(
                payload: payload,
                existingProfileID: existingProfileID
            )
            try profileStore.save(pairedProfile)
            isDemoMode = false
            profiles = profileStore.load()
            profileStore.setSelectedProfileID(pairedProfile.id)
            profile = pairedProfile
            resetWorkerState()
            await refreshProjectCatalogs()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func saveProfile(
        id: UUID? = nil,
        name: String,
        host: String,
        portText: String,
        username: String,
        fingerprint: String
    ) throws -> WorkerProfile {
        guard let port = Int(portText) else {
            throw WorkerProfileValidationError.invalidPort
        }
        let profile = try WorkerProfile.validated(
            id: id ?? UUID(),
            name: name,
            host: host,
            port: port,
            username: username,
            expectedHostKeyFingerprint: fingerprint
        )
        try profileStore.save(profile)
        isDemoMode = false
        profiles = profileStore.load()
        profileStore.setSelectedProfileID(profile.id)
        self.profile = profile
        resetWorkerState()
        return profile
    }

    func selectProfile(id: UUID) {
        guard let selectedProfile = profiles.first(where: { $0.id == id }) else { return }
        if isDemoMode {
            profile = selectedProfile
            return
        }
        profileStore.setSelectedProfileID(id)
        profile = selectedProfile
        resetWorkerState()
    }

    func deleteProfile(id: UUID) {
        guard !isDemoMode else { return }
        profileStore.delete(id: id)
        profiles = profileStore.load()
        workerOverviews[id] = nil
        workerLoadingIDs.remove(id)
        projectLoadingIDs.remove(id)
        dismissedUpdateTimestamps[id] = nil
        profile = profileStore.selectedProfileID()
            .flatMap { selectedID in profiles.first { $0.id == selectedID } }
            ?? profiles.first
        resetWorkerState()
    }

    private func resetWorkerState() {
        refreshToken = UUID()
        isLoading = false
        projects = []
        sessions = []
        threadCatalogs = [:]
    }

    func updateWarning(for profileID: UUID) -> String? {
        if let message = workerOverviews[profileID]?.runtimeUpdateStatus?.message {
            return message
        }
        if let info = workerOverviews[profileID]?.runtimeInfo,
           !info.isClientProtocolCompatible {
            return "This worker is updating to support the current app."
        }
        guard let status = workerOverviews[profileID]?.updateStatus,
              dismissedUpdateTimestamps[profileID] != status.timestamp else {
            return nil
        }
        return status.warningMessage
    }

    func dismissUpdateWarning(for profileID: UUID) {
        guard let timestamp = workerOverviews[profileID]?.updateStatus?.timestamp else {
            return
        }
        dismissedUpdateTimestamps[profileID] = timestamp
    }

    func refresh() async {
        guard !isDemoMode else { return }
        guard let profile, !isLoading else { return }
        let token = UUID()
        refreshToken = token
        isLoading = true
        defer {
            if refreshToken == token {
                isLoading = false
            }
        }

        do {
            async let projectData = workerClient.execute(WorkerRemoteCommand.listProjects, on: profile)
            async let statusData = workerClient.execute(WorkerRemoteCommand.status, on: profile)
            async let updateResult = Self.commandResult(
                WorkerRemoteCommand.updateStatus,
                profile: profile,
                workerClient: workerClient
            )
            async let runtimeInfoResult = Self.commandResult(
                WorkerRemoteCommand.runtimeInfo,
                profile: profile,
                workerClient: workerClient
            )
            async let runtimeStatusResult = Self.commandResult(
                WorkerRemoteCommand.runtimeUpdateStatus,
                profile: profile,
                workerClient: workerClient
            )
            let (projectsOutput, statusOutput, runtimeInfoOutput, runtimeStatusOutput) =
                try await (
                    projectData,
                    statusData,
                    runtimeInfoResult,
                    runtimeStatusResult
                )
            let updateStatus = Self.parseUpdateStatus(await updateResult)
            let runtimeInfo = try? WorkerRuntimeInfoProtocol.parse(runtimeInfoOutput.get())
            let runtimeUpdateStatus = try? WorkerRuntimeUpdateStatusProtocol.parse(
                runtimeStatusOutput.get()
            )
            let projectResponse = try WorkerSessionProtocol.parse(projectsOutput)
            let statusResponse = try WorkerSessionProtocol.parse(statusOutput)

            guard refreshToken == token else { return }
            sessions = statusResponse.sessions
            projects = WorkerProjectCatalog.visibleProjectNames(
                discoveredProjects: projectResponse.projects,
                sessions: statusResponse.sessions
            )
            let visibleProjects = Set(projects)
            let visibleSessions = statusResponse.sessions.filter {
                visibleProjects.contains($0.repositoryName)
            }
            let currentOverview = workerOverviews[profile.id]
            workerOverviews[profile.id] = WorkerOverviewSnapshot(
                projects: projects,
                sessions: visibleSessions,
                resources: currentOverview?.resources,
                accounts: currentOverview?.accounts ?? [:],
                accountErrors: currentOverview?.accountErrors ?? [],
                connectionError: nil,
                updateStatus: updateStatus ?? currentOverview?.updateStatus,
                runtimeInfo: runtimeInfo ?? currentOverview?.runtimeInfo,
                runtimeUpdateStatus: runtimeUpdateStatus ?? currentOverview?.runtimeUpdateStatus
            )
            if let runtimeInfo, !runtimeInfo.isClientProtocolCompatible {
                beginRuntimeUpdate(profile: profile)
            }
            mergeLiveSessionsIntoThreadCatalogs(
                workerID: profile.id,
                sessions: visibleSessions
            )
            errorMessage = nil
        } catch {
            guard refreshToken == token else { return }
            errorMessage = Self.connectionFailureMessage
        }
    }

    private func beginRuntimeUpdate(profile: WorkerProfile) {
        guard runtimeUpdateTasks[profile.id] == nil else { return }
        runtimeUpdateTasks[profile.id] = Task { [weak self] in
            guard let self else { return }
            defer { runtimeUpdateTasks[profile.id] = nil }
            do {
                let request = try await workerClient.execute(
                    WorkerRemoteCommand.runtimeUpdateRequest,
                    on: profile
                )
                let requestOutput = String(decoding: request, as: UTF8.self)
                guard requestOutput.contains(WorkerRuntimeUpdateStatusProtocol.marker),
                      requestOutput.contains("|accepted") else {
                    return
                }
                for delay in [1, 2, 4] {
                    try? await Task.sleep(for: .seconds(delay))
                    let infoData = try await workerClient.execute(
                        WorkerRemoteCommand.runtimeInfo,
                        on: profile
                    )
                    guard let info = try? WorkerRuntimeInfoProtocol.parse(infoData) else {
                        continue
                    }
                    if var overview = workerOverviews[profile.id] {
                        overview.runtimeInfo = info
                        if let statusData = try? await workerClient.execute(
                            WorkerRemoteCommand.runtimeUpdateStatus,
                            on: profile
                        ) {
                            overview.runtimeUpdateStatus =
                                try? WorkerRuntimeUpdateStatusProtocol.parse(statusData)
                        }
                        workerOverviews[profile.id] = overview
                    }
                    if info.isClientProtocolCompatible {
                        await refreshProjectCatalogs()
                        await refreshAllThreads()
                        return
                    }
                }
            } catch {
                return
            }
        }
    }

    private func requireCapability(_ capability: String, on worker: WorkerProfile) -> Bool {
        guard let info = workerOverviews[worker.id]?.runtimeInfo else {
            return true
        }
        guard info.supports(capability) else {
            errorMessage =
                "This worker is updating to add the required capability. Existing conversations are unchanged."
            beginRuntimeUpdate(profile: worker)
            return false
        }
        return true
    }

    func startConversation(kind: AgentKind, repositoryName: String) {
        if let profile, !requireCapability("agent-sessions", on: profile) {
            return
        }
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errorMessage = WorkerRemoteCommandError.invalidRepositoryName.localizedDescription
            return
        }
        let route = TerminalRoute(
            kind: kind,
            repositoryName: repositoryName,
            instanceToken: nil,
            presentation: .chat
        )
        lastOpenedTerminalRoute = route
        terminalRoute = route
    }

    func threads(
        workerID: UUID,
        repositoryName: String,
        archived: Bool
    ) -> [WorkerThreadSnapshot] {
        threadCatalogs[
            WorkerThreadCatalogKey(
                workerID: workerID,
                repositoryName: repositoryName,
                archived: archived
            )
        ]?.threads ?? []
    }

    func refreshThreads(workerID: UUID, repositoryName: String) async {
        guard !isDemoMode,
              let worker = profiles.first(where: { $0.id == workerID }),
              requireCapability("threads-v2", on: worker) else {
            return
        }
        async let active = loadThreads(
            worker: worker,
            repositoryName: repositoryName,
            archived: false
        )
        async let archived = loadThreads(
            worker: worker,
            repositoryName: repositoryName,
            archived: true
        )
        let responses = await (active, archived)
        if let response = responses.0 {
            threadCatalogs[
                WorkerThreadCatalogKey(
                    workerID: workerID,
                    repositoryName: repositoryName,
                    archived: false
                )
            ] = response
        }
        if let response = responses.1 {
            threadCatalogs[
                WorkerThreadCatalogKey(
                    workerID: workerID,
                    repositoryName: repositoryName,
                    archived: true
                )
            ] = response
        }
    }

    func refreshAllThreads() async {
        guard !isDemoMode else { return }
        await withTaskGroup(of: Void.self) { group in
            for worker in profiles {
                for repositoryName in workerOverviews[worker.id]?.projects ?? [] {
                    group.addTask { [weak self] in
                        await self?.refreshThreads(
                            workerID: worker.id,
                            repositoryName: repositoryName
                        )
                    }
                }
            }
        }
    }

    func createThread(workerID: UUID, repositoryName: String) async {
        guard !isDemoMode,
              let worker = profiles.first(where: { $0.id == workerID }),
              requireCapability("threads-v2", on: worker) else {
            return
        }
        do {
            let command = try WorkerRemoteCommand.createThread(
                repositoryName: repositoryName
            )
            _ = try await workerClient.execute(command, on: worker)
            await refreshThreads(workerID: workerID, repositoryName: repositoryName)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resumeThread(workerID: UUID, thread: WorkerThreadSnapshot) async {
        guard thread.activityState == .inactive,
              thread.capabilities.resume else {
            return
        }
        if isDemoMode {
            let route = TerminalRoute(
                kind: thread.kind,
                repositoryName: thread.repositoryName,
                instanceToken: nil,
                providerThreadID: thread.threadID,
                presentation: .chat
            )
            lastOpenedTerminalRoute = route
            terminalRoute = route
            return
        }
        guard let worker = profiles.first(where: { $0.id == workerID }),
              requireCapability("threads-v2", on: worker) else { return }
        if profile?.id != workerID {
            selectProfile(id: workerID)
        }
        let route = TerminalRoute(
            kind: thread.kind,
            repositoryName: thread.repositoryName,
            instanceToken: nil,
            providerThreadID: thread.threadID,
            presentation: .chat
        )
        lastOpenedTerminalRoute = route
        terminalRoute = route
    }

    func renameThread(
        workerID: UUID,
        thread: WorkerThreadSnapshot,
        name: String
    ) async {
        await mutateThread(
            workerID: workerID,
            thread: thread,
            command: {
                try WorkerRemoteCommand.renameThread(
                    kind: thread.kind,
                    repositoryName: thread.repositoryName,
                    threadID: thread.threadID,
                    name: name
                )
            }
        )
    }

    func setThreadArchived(
        workerID: UUID,
        thread: WorkerThreadSnapshot,
        archived: Bool
    ) async {
        await mutateThread(
            workerID: workerID,
            thread: thread,
            command: {
                try WorkerRemoteCommand.archiveThread(
                    kind: thread.kind,
                    repositoryName: thread.repositoryName,
                    threadID: thread.threadID,
                    unarchive: !archived
                )
            }
        )
    }

    func openTerminal(_ session: WorkerSessionSnapshot) {
        let route = TerminalRoute(
            kind: session.kind,
            repositoryName: session.repositoryName,
            instanceToken: session.instanceToken,
            providerThreadID: session.threadID,
            presentation: session.presentation
        )
        markSessionRead(session)
        lastOpenedTerminalRoute = route
        terminalRoute = route
    }

    func stop(
        kind: AgentKind,
        repositoryName: String,
        expectedInstanceToken: String
    ) async {
        if isDemoMode {
            terminalRoute = nil
            return
        }
        guard let profile, requireCapability("agent-sessions", on: profile) else { return }
        do {
            let statusData = try await workerClient.execute(WorkerRemoteCommand.status, on: profile)
            let response = try WorkerSessionProtocol.parse(statusData)
            guard let session = response.sessions.first(where: {
                $0.kind == kind
                    && $0.repositoryName == repositoryName
                    && $0.instanceToken == expectedInstanceToken
            }) else {
                throw WorkerSessionModelError.sessionEnded(kind: kind, repositoryName: repositoryName)
            }
            guard session.instanceToken == expectedInstanceToken else {
                throw WorkerSessionModelError.sessionChanged(kind: kind, repositoryName: repositoryName)
            }

            let command = try WorkerRemoteCommand.stop(
                kind: kind,
                repositoryName: repositoryName,
                instanceToken: session.instanceToken
            )
            _ = try await workerClient.execute(command, on: profile)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func isUnread(_ session: WorkerSessionSnapshot) -> Bool {
        guard let profile else {
            return false
        }
        return isUnread(session, profileID: profile.id)
    }

    func isUnread(_ session: WorkerSessionSnapshot, profileID: UUID) -> Bool {
        guard let lastActivityAt = session.lastActivityAt else { return false }
        let durableReadAt = readActivityBySession[readKey(
            profileID: profileID,
            identity: session.threadID ?? session.instanceToken
        )] ?? 0
        let legacyReadAt = readActivityBySession[readKey(
            profileID: profileID,
            identity: session.instanceToken
        )] ?? 0
        return lastActivityAt > max(durableReadAt, legacyReadAt)
    }

    func markLastOpenedTerminalRead() {
        guard let route = lastOpenedTerminalRoute,
              let profile else {
            return
        }
        let matchingSessions = sessions.filter {
            $0.kind == route.kind
                && $0.repositoryName == route.repositoryName
                && (route.instanceToken == nil || $0.instanceToken == route.instanceToken)
        }
        guard let session = matchingSessions.max(by: {
            ($0.lastActivityAt ?? 0) < ($1.lastActivityAt ?? 0)
        }) else {
            return
        }
        markSessionRead(session, profileID: profile.id)
    }

    func refreshWorkerOverviews() async {
        guard !isDemoMode else { return }
        let profilesToRefresh = profiles.filter { !workerLoadingIDs.contains($0.id) }
        guard !profilesToRefresh.isEmpty else { return }
        workerLoadingIDs.formUnion(profilesToRefresh.map(\.id))

        await withTaskGroup(of: (UUID, WorkerOverviewSnapshot).self) { group in
            for profile in profilesToRefresh {
                group.addTask { [workerClient] in
                    (
                        profile.id,
                        await Self.loadOverview(profile: profile, workerClient: workerClient)
                    )
                }
            }

            for await (profileID, overview) in group {
                workerOverviews[profileID] = overview
                if overview.connectionError == nil,
                   let runtimeInfo = overview.runtimeInfo,
                   !runtimeInfo.isClientProtocolCompatible,
                   let profile = profiles.first(where: { $0.id == profileID }) {
                    beginRuntimeUpdate(profile: profile)
                }
                mergeLiveSessionsIntoThreadCatalogs(
                    workerID: profileID,
                    sessions: overview.sessions
                )
                workerLoadingIDs.remove(profileID)
            }
        }
    }

    func refreshProjectCatalogs() async {
        guard !isDemoMode else { return }
        let profilesToRefresh = profiles.filter { !projectLoadingIDs.contains($0.id) }
        guard !profilesToRefresh.isEmpty else { return }
        projectLoadingIDs.formUnion(profilesToRefresh.map(\.id))

        await withTaskGroup(of: (UUID, WorkerOverviewSnapshot).self) { group in
            for profile in profilesToRefresh {
                let currentOverview = workerOverviews[profile.id]
                group.addTask { [workerClient] in
                    (
                        profile.id,
                        await Self.loadProjectCatalog(
                            profile: profile,
                            currentOverview: currentOverview,
                            workerClient: workerClient
                        )
                    )
                }
            }

            for await (profileID, overview) in group {
                workerOverviews[profileID] = overview
                mergeLiveSessionsIntoThreadCatalogs(
                    workerID: profileID,
                    sessions: overview.sessions
                )
                projectLoadingIDs.remove(profileID)
            }
        }
    }

    func refreshProjectActivity() async {
        guard !isDemoMode else { return }
        let profilesToRefresh = profiles.filter { !projectLoadingIDs.contains($0.id) }
        guard !profilesToRefresh.isEmpty else { return }

        await withTaskGroup(of: (UUID, Result<Data, Error>).self) { group in
            for profile in profilesToRefresh {
                group.addTask { [workerClient] in
                    (
                        profile.id,
                        await Self.commandResult(
                            WorkerRemoteCommand.status,
                            profile: profile,
                            workerClient: workerClient
                        )
                    )
                }
            }

            for await (profileID, result) in group {
                guard let currentOverview = workerOverviews[profileID],
                      let data = try? result.get(),
                      let response = try? WorkerSessionProtocol.parse(data) else {
                    continue
                }
                let visibleProjects = Set(currentOverview.projects)
                let refreshedSessions = response.sessions.filter {
                    visibleProjects.contains($0.repositoryName)
                }
                workerOverviews[profileID] = WorkerOverviewSnapshot(
                    projects: currentOverview.projects,
                    sessions: refreshedSessions,
                    resources: currentOverview.resources,
                    accounts: currentOverview.accounts,
                    accountErrors: currentOverview.accountErrors,
                    connectionError: nil,
                    updateStatus: currentOverview.updateStatus,
                    runtimeInfo: currentOverview.runtimeInfo,
                    runtimeUpdateStatus: currentOverview.runtimeUpdateStatus
                )
                mergeLiveSessionsIntoThreadCatalogs(
                    workerID: profileID,
                    sessions: refreshedSessions
                )
                if profile?.id == profileID, !isLoading {
                    sessions = refreshedSessions
                }
            }
        }
    }

    private static func loadProjectCatalog(
        profile: WorkerProfile,
        currentOverview: WorkerOverviewSnapshot?,
        workerClient: SSHWorkerClient
    ) async -> WorkerOverviewSnapshot {
        async let projectsResult = commandResult(
            WorkerRemoteCommand.listProjects,
            profile: profile,
            workerClient: workerClient
        )
        async let sessionsResult = commandResult(
            WorkerRemoteCommand.status,
            profile: profile,
            workerClient: workerClient
        )
        async let updateResult = commandResult(
            WorkerRemoteCommand.updateStatus,
            profile: profile,
            workerClient: workerClient
        )
        async let runtimeInfoResult = commandResult(
            WorkerRemoteCommand.runtimeInfo,
            profile: profile,
            workerClient: workerClient
        )
        async let runtimeStatusResult = commandResult(
            WorkerRemoteCommand.runtimeUpdateStatus,
            profile: profile,
            workerClient: workerClient
        )

        do {
            let (
                projectData,
                sessionData,
                updateStatusOutput,
                runtimeInfoOutput,
                runtimeStatusOutput
            ) = await (
                projectsResult,
                sessionsResult,
                updateResult,
                runtimeInfoResult,
                runtimeStatusResult
            )
            let (projectOutput, sessionOutput) = try (
                projectData.get(),
                sessionData.get()
            )
            let updateStatus = parseUpdateStatus(updateStatusOutput)
            let runtimeInfo = try? WorkerRuntimeInfoProtocol.parse(runtimeInfoOutput.get())
            let runtimeUpdateStatus = try? WorkerRuntimeUpdateStatusProtocol.parse(
                runtimeStatusOutput.get()
            )
            let projectResponse = try WorkerSessionProtocol.parse(projectOutput)
            let sessionResponse = try WorkerSessionProtocol.parse(sessionOutput)
            let projects = WorkerProjectCatalog.visibleProjectNames(
                discoveredProjects: projectResponse.projects,
                sessions: sessionResponse.sessions
            )
            let visibleProjects = Set(projects)
            return WorkerOverviewSnapshot(
                projects: projects,
                sessions: sessionResponse.sessions.filter {
                    visibleProjects.contains($0.repositoryName)
                },
                resources: currentOverview?.resources,
                accounts: currentOverview?.accounts ?? [:],
                accountErrors: currentOverview?.accountErrors ?? [],
                connectionError: nil,
                updateStatus: updateStatus ?? currentOverview?.updateStatus,
                runtimeInfo: runtimeInfo ?? currentOverview?.runtimeInfo,
                runtimeUpdateStatus: runtimeUpdateStatus ?? currentOverview?.runtimeUpdateStatus
            )
        } catch {
            return WorkerOverviewSnapshot(
                projects: currentOverview?.projects ?? [],
                sessions: currentOverview?.sessions ?? [],
                resources: currentOverview?.resources,
                accounts: currentOverview?.accounts ?? [:],
                accountErrors: currentOverview?.accountErrors ?? [],
                connectionError: connectionFailureMessage,
                updateStatus: currentOverview?.updateStatus,
                runtimeInfo: currentOverview?.runtimeInfo,
                runtimeUpdateStatus: currentOverview?.runtimeUpdateStatus
            )
        }
    }

    private static func loadOverview(
        profile: WorkerProfile,
        workerClient: SSHWorkerClient
    ) async -> WorkerOverviewSnapshot {
        async let projectsResult = commandResult(
            WorkerRemoteCommand.listProjects,
            profile: profile,
            workerClient: workerClient
        )
        async let sessionsResult = commandResult(
            WorkerRemoteCommand.status,
            profile: profile,
            workerClient: workerClient
        )
        async let resourcesResult = compatibleCommandResult(
            WorkerRemoteCommand.resources,
            legacyCommand: WorkerRemoteCommand.legacyResources,
            profile: profile,
            workerClient: workerClient
        )
        async let codexResult = compatibleCommandResult(
            WorkerRemoteCommand.codexAccount,
            legacyCommand: WorkerRemoteCommand.legacyCodexAccount,
            profile: profile,
            workerClient: workerClient
        )
        async let claudeResult = compatibleCommandResult(
            WorkerRemoteCommand.claudeAccount,
            legacyCommand: WorkerRemoteCommand.legacyClaudeAccount,
            profile: profile,
            workerClient: workerClient
        )
        async let updateResult = commandResult(
            WorkerRemoteCommand.updateStatus,
            profile: profile,
            workerClient: workerClient
        )
        async let runtimeInfoResult = commandResult(
            WorkerRemoteCommand.runtimeInfo,
            profile: profile,
            workerClient: workerClient
        )
        async let runtimeStatusResult = commandResult(
            WorkerRemoteCommand.runtimeUpdateStatus,
            profile: profile,
            workerClient: workerClient
        )

        let results = await (
            projectsResult,
            sessionsResult,
            resourcesResult,
            codexResult,
            claudeResult,
            updateResult,
            runtimeInfoResult,
            runtimeStatusResult
        )

        let projectResponse: WorkerSessionResponse
        let sessionResponse: WorkerSessionResponse
        do {
            projectResponse = try WorkerSessionProtocol.parse(results.0.get())
            sessionResponse = try WorkerSessionProtocol.parse(results.1.get())
        } catch {
            return WorkerOverviewSnapshot(
                projects: [],
                sessions: [],
                resources: nil,
                accounts: [:],
                accountErrors: Set(AgentKind.allCases),
                connectionError: connectionFailureMessage,
                updateStatus: parseUpdateStatus(results.5),
                runtimeInfo: try? WorkerRuntimeInfoProtocol.parse(results.6.get()),
                runtimeUpdateStatus: try? WorkerRuntimeUpdateStatusProtocol.parse(
                    results.7.get()
                )
            )
        }

        let projects = WorkerProjectCatalog.visibleProjectNames(
            discoveredProjects: projectResponse.projects,
            sessions: sessionResponse.sessions
        )
        let visibleProjects = Set(projects)
        let sessions = sessionResponse.sessions.filter {
            visibleProjects.contains($0.repositoryName)
        }
        let resources = try? WorkerOverviewParser.resources(results.2.get())
        let updateStatus = parseUpdateStatus(results.5)
        let runtimeInfo = try? WorkerRuntimeInfoProtocol.parse(results.6.get())
        let runtimeUpdateStatus = try? WorkerRuntimeUpdateStatusProtocol.parse(
            results.7.get()
        )

        var accounts: [AgentKind: WorkerAccountSnapshot] = [:]
        var accountErrors: Set<AgentKind> = []
        do {
            accounts[.codex] = try await loadCodexAccount(
                initialResult: results.3,
                profile: profile,
                workerClient: workerClient
            )
        } catch {
            accountErrors.insert(.codex)
        }
        do {
            accounts[.claude] = try WorkerOverviewParser.claudeAccount(results.4.get())
        } catch {
            accountErrors.insert(.claude)
        }

        return WorkerOverviewSnapshot(
            projects: projects,
            sessions: sessions,
            resources: resources,
            accounts: accounts,
            accountErrors: accountErrors,
            connectionError: nil,
            updateStatus: updateStatus,
            runtimeInfo: runtimeInfo,
            runtimeUpdateStatus: runtimeUpdateStatus
        )
    }

    private static func parseUpdateStatus(
        _ result: Result<Data, Error>
    ) -> WorkerUpdateStatus? {
        guard case .success(let data) = result else { return nil }
        return try? WorkerUpdateStatusProtocol.parse(data)
    }

    private static func loadCodexAccount(
        initialResult: Result<Data, Error>,
        profile: WorkerProfile,
        workerClient: SSHWorkerClient
    ) async throws -> WorkerAccountSnapshot {
        do {
            return try WorkerOverviewParser.codexAccount(initialResult.get())
        } catch {
            let retryResult = await compatibleCommandResult(
                WorkerRemoteCommand.codexAccount,
                legacyCommand: WorkerRemoteCommand.legacyCodexAccount,
                profile: profile,
                workerClient: workerClient
            )
            let retryData = try retryResult.get()
            return try WorkerOverviewParser.codexAccount(retryData)
        }
    }

    private static func compatibleCommandResult(
        _ command: String,
        legacyCommand: String,
        profile: WorkerProfile,
        workerClient: SSHWorkerClient
    ) async -> Result<Data, Error> {
        do {
            return .success(try await workerClient.execute(command, on: profile))
        } catch {
            return await commandResult(
                legacyCommand,
                profile: profile,
                workerClient: workerClient
            )
        }
    }

    private func loadThreads(
        worker: WorkerProfile,
        repositoryName: String,
        archived: Bool
    ) async -> WorkerThreadResponse? {
        do {
            var remainingCursor: String?
            var threads: [WorkerThreadSnapshot] = []
            for kind in AgentKind.allCases {
                var cursor: String?
                var pages = 0
                repeat {
                    let command = try WorkerRemoteCommand.threads(
                        kind: kind,
                        repositoryName: repositoryName,
                        archived: archived,
                        cursor: cursor
                    )
                    let data = try await workerClient.execute(command, on: worker)
                    let response = try WorkerThreadProtocol.parse(
                        data,
                        repositoryName: repositoryName
                    )
                    guard response.threads.allSatisfy({ $0.kind == kind }) else {
                        throw WorkerThreadProtocolError.invalidResponse
                    }
                    threads.append(contentsOf: response.threads)
                    cursor = response.nextCursor
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
                    liveSessions: workerOverviews[worker.id]?.sessions.filter {
                        $0.repositoryName == repositoryName
                    } ?? []
                )
            }
            return response
        } catch {
            return nil
        }
    }

    private func mutateThread(
        workerID: UUID,
        thread: WorkerThreadSnapshot,
        command: () throws -> String
    ) async {
        guard !isDemoMode,
              let worker = profiles.first(where: { $0.id == workerID }),
              requireCapability("threads-v2", on: worker) else {
            return
        }
        do {
            _ = try await workerClient.execute(try command(), on: worker)
            await refreshThreads(
                workerID: workerID,
                repositoryName: thread.repositoryName
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadDemoThreads() {
        for archived in [false, true] {
            for repositoryName in DemoWorkspace.projects {
                threadCatalogs[
                    WorkerThreadCatalogKey(
                        workerID: DemoWorkspace.worker.id,
                        repositoryName: repositoryName,
                        archived: archived
                    )
                ] = WorkerThreadResponse(
                    threads: DemoWorkspace.threads.filter {
                        $0.repositoryName == repositoryName
                            && $0.isArchived == archived
                    },
                    nextCursor: nil
                )
            }
        }
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
            threadCatalogs[key] = catalog.merging(
                liveSessions: sessions.filter {
                    $0.repositoryName == key.repositoryName
                }
            )
        }
    }

    private static func commandResult(
        _ command: String,
        profile: WorkerProfile,
        workerClient: SSHWorkerClient
    ) async -> Result<Data, Error> {
        do {
            return .success(try await workerClient.execute(command, on: profile))
        } catch {
            return .failure(error)
        }
    }

    private func markSessionRead(
        _ session: WorkerSessionSnapshot,
        profileID: UUID? = nil
    ) {
        guard let profileID = profileID ?? profile?.id,
              let lastActivityAt = session.lastActivityAt else {
            return
        }
        readActivityBySession[readKey(
            profileID: profileID,
            identity: session.threadID ?? session.instanceToken
        )] = lastActivityAt
        if let data = try? JSONEncoder().encode(readActivityBySession) {
            readStateDefaults.set(data, forKey: Self.readStateKey)
        }
    }

    private func readKey(profileID: UUID, identity: String) -> String {
        "\(profileID.uuidString.lowercased()):\(identity)"
    }

    private static func loadReadState(from defaults: UserDefaults) -> [String: Int] {
        guard let data = defaults.data(forKey: readStateKey),
              let state = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return state
    }
}
