import Combine
import Foundation

struct TerminalRoute: Identifiable, Equatable {
    let id = UUID()
    let kind: AgentKind
    let repositoryName: String
    let instanceToken: String?
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
    private var refreshToken = UUID()
    private static let readStateKey = "workerSessionReadActivity.v1"

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
    }

    func enterDemo() {
        refreshToken = UUID()
        isLoading = false
        isPairing = false
        isDemoMode = true
        profiles = [DemoWorkspace.worker]
        profile = DemoWorkspace.worker
        projects = DemoWorkspace.projects
        sessions = DemoWorkspace.sessions
        workerOverviews = [DemoWorkspace.worker.id: DemoWorkspace.overview]
        workerLoadingIDs = []
        projectLoadingIDs = []
        publicKey = "ssh-ed25519 demo-device"
        errorMessage = nil
        terminalRoute = nil
        lastOpenedTerminalRoute = nil
    }

    func exitDemo() {
        refreshToken = UUID()
        isLoading = false
        isPairing = false
        isDemoMode = false
        profiles = profileStore.load()
        profile = profileStore.selectedProfileID()
            .flatMap { selectedID in profiles.first { $0.id == selectedID } }
            ?? profiles.first
        projects = []
        sessions = []
        workerOverviews = [:]
        workerLoadingIDs = []
        projectLoadingIDs = []
        errorMessage = nil
        terminalRoute = nil
        lastOpenedTerminalRoute = nil

        do {
            publicKey = try identityStore.publicKeyForAuthorizedKeys()
        } catch {
            publicKey = ""
            errorMessage = error.localizedDescription
        }
    }

    func updateWarning(for profileID: UUID) -> String? {
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
            let (projectsOutput, statusOutput) = try await (projectData, statusData)
            let updateStatus = Self.parseUpdateStatus(await updateResult)
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
                updateStatus: updateStatus ?? currentOverview?.updateStatus
            )
            errorMessage = nil
        } catch {
            guard refreshToken == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    func startTerminal(kind: AgentKind, repositoryName: String) {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errorMessage = WorkerRemoteCommandError.invalidRepositoryName.localizedDescription
            return
        }
        let route = TerminalRoute(
            kind: kind,
            repositoryName: repositoryName,
            instanceToken: nil
        )
        lastOpenedTerminalRoute = route
        terminalRoute = route
    }

    func openTerminal(_ session: WorkerSessionSnapshot) {
        let route = TerminalRoute(
            kind: session.kind,
            repositoryName: session.repositoryName,
            instanceToken: session.instanceToken
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
        guard let profile else { return }
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
        return lastActivityAt > (readActivityBySession[readKey(
            profileID: profileID,
            instanceToken: session.instanceToken
        )] ?? 0)
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
                    updateStatus: currentOverview.updateStatus
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

        do {
            let (projectData, sessionData, updateStatusResult) = await (
                projectsResult,
                sessionsResult,
                updateResult
            )
            let (projectOutput, sessionOutput) = try (
                projectData.get(),
                sessionData.get()
            )
            let updateStatus = parseUpdateStatus(updateStatusResult)
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
                updateStatus: updateStatus ?? currentOverview?.updateStatus
            )
        } catch {
            return WorkerOverviewSnapshot(
                projects: currentOverview?.projects ?? [],
                sessions: currentOverview?.sessions ?? [],
                resources: currentOverview?.resources,
                accounts: currentOverview?.accounts ?? [:],
                accountErrors: currentOverview?.accountErrors ?? [],
                connectionError: error.localizedDescription,
                updateStatus: currentOverview?.updateStatus
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
        async let resourcesResult = commandResult(
            WorkerRemoteCommand.resources,
            profile: profile,
            workerClient: workerClient
        )
        async let codexResult = commandResult(
            WorkerRemoteCommand.codexAccount,
            profile: profile,
            workerClient: workerClient
        )
        async let claudeResult = commandResult(
            WorkerRemoteCommand.claudeAccount,
            profile: profile,
            workerClient: workerClient
        )
        async let updateResult = commandResult(
            WorkerRemoteCommand.updateStatus,
            profile: profile,
            workerClient: workerClient
        )

        let results = await (
            projectsResult,
            sessionsResult,
            resourcesResult,
            codexResult,
            claudeResult,
            updateResult
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
                connectionError: error.localizedDescription,
                updateStatus: parseUpdateStatus(results.5)
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
            updateStatus: updateStatus
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
            let retryData = try await workerClient.execute(
                WorkerRemoteCommand.codexAccount,
                on: profile
            )
            return try WorkerOverviewParser.codexAccount(retryData)
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
            instanceToken: session.instanceToken
        )] = lastActivityAt
        if let data = try? JSONEncoder().encode(readActivityBySession) {
            readStateDefaults.set(data, forKey: Self.readStateKey)
        }
    }

    private func readKey(profileID: UUID, instanceToken: String) -> String {
        "\(profileID.uuidString.lowercased()):\(instanceToken)"
    }

    private static func loadReadState(from defaults: UserDefaults) -> [String: Int] {
        guard let data = defaults.data(forKey: readStateKey),
              let state = try? JSONDecoder().decode([String: Int].self, from: data) else {
            return [:]
        }
        return state
    }
}
