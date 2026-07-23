import Combine
import Foundation

struct TerminalRoute: Identifiable, Equatable {
    let kind: AgentKind
    let repositoryName: String
    let instanceToken: String?

    var id: String { "\(kind.rawValue):\(repositoryName)" }
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
    @Published private(set) var publicKey = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published var terminalRoute: TerminalRoute?

    private let profileStore: WorkerProfileStore
    private let identityStore: SSHIdentityStore
    private let workerClient: SSHWorkerClient
    private var refreshToken = UUID()

    init(
        profileStore: WorkerProfileStore = WorkerProfileStore(),
        identityStore: SSHIdentityStore = SSHIdentityStore()
    ) {
        self.profileStore = profileStore
        self.identityStore = identityStore
        self.workerClient = SSHWorkerClient(identityStore: identityStore)
        let profiles = profileStore.load()
        self.profiles = profiles
        self.profile = profileStore.selectedProfileID()
            .flatMap { selectedID in profiles.first { $0.id == selectedID } }
            ?? profiles.first

        do {
            self.publicKey = try identityStore.publicKeyForAuthorizedKeys()
        } catch {
            self.errorMessage = error.localizedDescription
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
        profiles = profileStore.load()
        profileStore.setSelectedProfileID(profile.id)
        self.profile = profile
        resetWorkerState()
        return profile
    }

    func selectProfile(id: UUID) {
        guard let selectedProfile = profiles.first(where: { $0.id == id }) else { return }
        profileStore.setSelectedProfileID(id)
        profile = selectedProfile
        resetWorkerState()
    }

    func deleteProfile(id: UUID) {
        profileStore.delete(id: id)
        profiles = profileStore.load()
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

    func refresh() async {
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
            let (projectsOutput, statusOutput) = try await (projectData, statusData)
            let projectResponse = try WorkerSessionProtocol.parse(projectsOutput)
            let statusResponse = try WorkerSessionProtocol.parse(statusOutput)

            guard refreshToken == token else { return }
            sessions = statusResponse.sessions
            projects = WorkerProjectCatalog.visibleProjectNames(
                discoveredProjects: projectResponse.projects,
                sessions: statusResponse.sessions
            )
            errorMessage = nil
        } catch {
            guard refreshToken == token else { return }
            errorMessage = error.localizedDescription
        }
    }

    func openTerminal(kind: AgentKind, repositoryName: String) {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            errorMessage = WorkerRemoteCommandError.invalidRepositoryName.localizedDescription
            return
        }
        let instanceToken = sessions.first {
            $0.kind == kind && $0.repositoryName == repositoryName
        }?.instanceToken
        terminalRoute = TerminalRoute(
            kind: kind,
            repositoryName: repositoryName,
            instanceToken: instanceToken
        )
    }

    func stop(
        kind: AgentKind,
        repositoryName: String,
        expectedInstanceToken: String
    ) async {
        guard let profile else { return }
        do {
            let statusData = try await workerClient.execute(WorkerRemoteCommand.status, on: profile)
            let response = try WorkerSessionProtocol.parse(statusData)
            guard let session = response.sessions.first(where: {
                $0.kind == kind && $0.repositoryName == repositoryName
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

    func session(for kind: AgentKind) -> WorkerSessionSnapshot? {
        sessions.first { $0.kind == kind }
    }
}
