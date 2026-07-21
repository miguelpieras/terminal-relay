import Combine
import Foundation

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectProfile]
    @Published private(set) var persistenceError: String?
    @Published private(set) var validationError: String?

    private let defaults: UserDefaults
    private let storageKey = "projectProfiles.v1"
    private var serverIDs: Set<UUID>

    init(
        defaults: UserDefaults = .standard,
        servers: [ServerProfile],
        initialProjects: [ProjectProfile]? = nil
    ) {
        self.defaults = defaults
        self.serverIDs = Set(servers.map(\.id))
        self.projects = initialProjects ?? Self.seedProjects(from: servers)

        if defaults.data(forKey: storageKey) == nil {
            persist()
            validateServerReferences()
        } else {
            load()
        }
    }

    func project(id: UUID?) -> ProjectProfile? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func projects(for serverID: UUID) -> [ProjectProfile] {
        projects.filter { $0.serverID == serverID }
    }

    @discardableResult
    func save(_ profile: ProjectProfile) -> Bool {
        guard serverIDs.contains(profile.serverID) else {
            validationError = "\(profile.displayName.isEmpty ? "Project" : profile.displayName) is assigned to a worker that no longer exists."
            return false
        }

        if let index = projects.firstIndex(where: { $0.id == profile.id }) {
            projects[index] = profile
        } else {
            projects.append(profile)
        }

        persist()
        validateServerReferences()
        return persistenceError == nil
    }

    func delete(id: UUID) {
        projects.removeAll { $0.id == id }
        persist()
        validateServerReferences()
    }

    func updateServers(_ servers: [ServerProfile]) {
        serverIDs = Set(servers.map(\.id))
        validateServerReferences()
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    func dismissValidationError() {
        validationError = nil
    }

    private static func seedProjects(from servers: [ServerProfile]) -> [ProjectProfile] {
        servers.compactMap { server in
            let workingDirectory = server.workingDirectory
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workingDirectory.isEmpty else { return nil }

            let directoryName = URL(fileURLWithPath: workingDirectory).lastPathComponent
            let projectName: String
            if directoryName.isEmpty {
                projectName = server.displayName
            } else if directoryName.caseInsensitiveCompare("workspace") == .orderedSame {
                projectName = "Workspace"
            } else {
                projectName = directoryName
            }

            return ProjectProfile(
                name: projectName,
                serverID: server.id,
                workingDirectory: workingDirectory
            )
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }

        do {
            projects = try JSONDecoder().decode([ProjectProfile].self, from: data)
            persistenceError = nil
            validateServerReferences()
        } catch {
            persistenceError = "Saved projects could not be read: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(projects)
            defaults.set(data, forKey: storageKey)
            persistenceError = nil
        } catch {
            persistenceError = "Projects could not be saved: \(error.localizedDescription)"
        }
    }

    private func validateServerReferences() {
        guard let project = projects.first(where: { !serverIDs.contains($0.serverID) }) else {
            validationError = nil
            return
        }

        validationError = "\(project.displayName.isEmpty ? "A project" : project.displayName) is assigned to a worker that no longer exists."
    }
}
