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

@MainActor
final class WorkerSessionModel: ObservableObject {
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

    init(
        profileStore: WorkerProfileStore = WorkerProfileStore(),
        identityStore: SSHIdentityStore = SSHIdentityStore()
    ) {
        self.profileStore = profileStore
        self.identityStore = identityStore
        self.workerClient = SSHWorkerClient(identityStore: identityStore)
        self.profile = profileStore.load()

        do {
            self.publicKey = try identityStore.publicKeyForAuthorizedKeys()
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func saveProfile(host: String, portText: String, username: String, fingerprint: String) throws {
        guard let port = Int(portText) else {
            throw WorkerProfileValidationError.invalidPort
        }
        let profile = try WorkerProfile.validated(
            host: host,
            port: port,
            username: username,
            expectedHostKeyFingerprint: fingerprint
        )
        try profileStore.save(profile)
        self.profile = profile
        projects = []
        sessions = []
    }

    func clearProfile() {
        profileStore.clear()
        profile = nil
        projects = []
        sessions = []
    }

    func refresh() async {
        guard let profile, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            async let projectData = workerClient.execute(WorkerRemoteCommand.listProjects, on: profile)
            async let statusData = workerClient.execute(WorkerRemoteCommand.status, on: profile)
            let (projectsOutput, statusOutput) = try await (projectData, statusData)
            let projectResponse = try WorkerSessionProtocol.parse(projectsOutput)
            let statusResponse = try WorkerSessionProtocol.parse(statusOutput)

            sessions = statusResponse.sessions
            let names = Set(projectResponse.projects + statusResponse.sessions.map(\.repositoryName))
            projects = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            errorMessage = nil
        } catch {
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
