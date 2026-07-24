import Combine
import Foundation

struct SidebarProjectFolder: Codable, Hashable, Identifiable {
    let id: UUID
    var name: String

    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [ProjectProfile]
    @Published private(set) var sidebarFolders: [SidebarProjectFolder] = []
    @Published private(set) var rootProjectIDs: [UUID] = []
    @Published private(set) var projectIDsByFolder: [UUID: [UUID]] = [:]
    @Published private(set) var persistenceError: String?
    @Published private(set) var validationError: String?

    private let defaults: UserDefaults
    private let storageKey = "projectProfiles.v2"
    private let sidebarStorageKey = "projectSidebarOrganization.v1"
    private var serverIDs: Set<UUID>

    init(
        defaults: UserDefaults = .standard,
        servers: [ServerProfile],
        initialProjects: [ProjectProfile]? = nil
    ) {
        self.defaults = defaults
        self.serverIDs = Set(servers.map(\.id))
        self.projects = initialProjects ?? []

        if defaults.data(forKey: storageKey) == nil {
            persistProjects()
            validateServerReferences()
        } else {
            loadProjects()
        }
        loadSidebarOrganization()
        reconcileSidebarOrganization()
        persistSidebarOrganization()
    }

    func project(id: UUID?) -> ProjectProfile? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func projects(for serverID: UUID) -> [ProjectProfile] {
        projects.filter { $0.serverID == serverID }
    }

    var sidebarProjects: [ProjectProfile] {
        rootProjects + sidebarFolders.flatMap { projects(inSidebarFolder: $0.id) }
    }

    var rootProjects: [ProjectProfile] {
        profiles(for: rootProjectIDs)
    }

    func projects(inSidebarFolder folderID: UUID) -> [ProjectProfile] {
        profiles(for: projectIDsByFolder[folderID] ?? [])
    }

    @discardableResult
    func save(_ profile: ProjectProfile) -> Bool {
        guard profile.isValid else {
            validationError = "Enter a valid GitHub repository name."
            return false
        }

        guard serverIDs.contains(profile.serverID) else {
            validationError = "\(profile.displayName.isEmpty ? "Project" : profile.displayName) is assigned to a worker that no longer exists."
            return false
        }

        if projects.contains(where: {
            $0.id != profile.id
                && $0.githubRepository.caseInsensitiveCompare(profile.githubRepository) == .orderedSame
        }) {
            validationError = "\(profile.githubRepository) is already in Terminal Relay."
            return false
        }

        if let index = projects.firstIndex(where: { $0.id == profile.id }) {
            projects[index] = profile
        } else {
            projects.append(profile)
            rootProjectIDs.append(profile.id)
        }

        reconcileSidebarOrganization()
        persistProjects()
        persistSidebarOrganization()
        validateServerReferences()
        return persistenceError == nil
    }

    func delete(id: UUID) {
        projects.removeAll { $0.id == id }
        removeProjectFromSidebar(id)
        persistProjects()
        persistSidebarOrganization()
        validateServerReferences()
    }

    @discardableResult
    func createSidebarFolder(named name: String) -> SidebarProjectFolder? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let folder = SidebarProjectFolder(name: String(trimmedName.prefix(80)))
        sidebarFolders.append(folder)
        projectIDsByFolder[folder.id] = []
        persistSidebarOrganization()
        return folder
    }

    func renameSidebarFolder(id: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let index = sidebarFolders.firstIndex(where: { $0.id == id }) else {
            return
        }
        sidebarFolders[index].name = String(trimmedName.prefix(80))
        persistSidebarOrganization()
    }

    func deleteSidebarFolder(id: UUID) {
        guard sidebarFolders.contains(where: { $0.id == id }) else { return }
        rootProjectIDs.append(contentsOf: projectIDsByFolder[id] ?? [])
        projectIDsByFolder[id] = nil
        sidebarFolders.removeAll { $0.id == id }
        persistSidebarOrganization()
    }

    func moveProject(
        id projectID: UUID,
        before targetProjectID: UUID? = nil,
        intoSidebarFolder folderID: UUID?
    ) {
        guard projects.contains(where: { $0.id == projectID }),
              folderID == nil || sidebarFolders.contains(where: { $0.id == folderID }) else {
            return
        }

        removeProjectFromSidebar(projectID)
        if let folderID {
            var destination = projectIDsByFolder[folderID] ?? []
            let targetIndex = targetProjectID.flatMap {
                destination.firstIndex(of: $0)
            } ?? destination.endIndex
            destination.insert(projectID, at: targetIndex)
            projectIDsByFolder[folderID] = destination
        } else {
            let targetIndex = targetProjectID.flatMap {
                rootProjectIDs.firstIndex(of: $0)
            } ?? rootProjectIDs.endIndex
            rootProjectIDs.insert(projectID, at: targetIndex)
        }
        persistSidebarOrganization()
    }

    func moveSidebarFolder(id folderID: UUID, before targetFolderID: UUID?) {
        guard let folder = sidebarFolders.first(where: { $0.id == folderID }) else { return }
        sidebarFolders.removeAll { $0.id == folderID }
        let targetIndex = targetFolderID.flatMap { targetFolderID in
            sidebarFolders.firstIndex(where: { $0.id == targetFolderID })
        } ?? sidebarFolders.endIndex
        sidebarFolders.insert(folder, at: targetIndex)
        persistSidebarOrganization()
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

    private func loadProjects() {
        guard let data = defaults.data(forKey: storageKey) else { return }

        do {
            projects = try JSONDecoder().decode([ProjectProfile].self, from: data)
            persistenceError = nil
            validateServerReferences()
        } catch {
            persistenceError = "Saved projects could not be read: \(error.localizedDescription)"
        }
    }

    private func persistProjects() {
        do {
            let data = try JSONEncoder().encode(projects)
            defaults.set(data, forKey: storageKey)
            persistenceError = nil
        } catch {
            persistenceError = "Projects could not be saved: \(error.localizedDescription)"
        }
    }

    private func loadSidebarOrganization() {
        guard let data = defaults.data(forKey: sidebarStorageKey) else { return }

        do {
            let organization = try JSONDecoder().decode(
                SidebarOrganization.self,
                from: data
            )
            sidebarFolders = organization.folders
            rootProjectIDs = organization.rootProjectIDs
            projectIDsByFolder = organization.projectIDsByFolder
        } catch {
            persistenceError = "Saved sidebar folders could not be read: \(error.localizedDescription)"
        }
    }

    private func persistSidebarOrganization() {
        do {
            let organization = SidebarOrganization(
                folders: sidebarFolders,
                rootProjectIDs: rootProjectIDs,
                projectIDsByFolder: projectIDsByFolder
            )
            let data = try JSONEncoder().encode(organization)
            defaults.set(data, forKey: sidebarStorageKey)
        } catch {
            persistenceError = "Sidebar folders could not be saved: \(error.localizedDescription)"
        }
    }

    private func reconcileSidebarOrganization() {
        let validProjectIDs = Set(projects.map(\.id))
        var assignedProjectIDs = Set<UUID>()

        rootProjectIDs = rootProjectIDs.filter {
            validProjectIDs.contains($0) && assignedProjectIDs.insert($0).inserted
        }

        let validFolderIDs = Set(sidebarFolders.map(\.id))
        projectIDsByFolder = projectIDsByFolder.filter {
            validFolderIDs.contains($0.key)
        }
        for folder in sidebarFolders {
            projectIDsByFolder[folder.id] = (projectIDsByFolder[folder.id] ?? []).filter {
                validProjectIDs.contains($0) && assignedProjectIDs.insert($0).inserted
            }
        }

        rootProjectIDs.append(contentsOf: projects.map(\.id).filter {
            !assignedProjectIDs.contains($0)
        })
    }

    private func removeProjectFromSidebar(_ projectID: UUID) {
        rootProjectIDs.removeAll { $0 == projectID }
        for folderID in Array(projectIDsByFolder.keys) {
            projectIDsByFolder[folderID]?.removeAll { $0 == projectID }
        }
    }

    private func profiles(for ids: [UUID]) -> [ProjectProfile] {
        ids.compactMap { id in
            projects.first { $0.id == id }
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

private struct SidebarOrganization: Codable {
    var folders: [SidebarProjectFolder]
    var rootProjectIDs: [UUID]
    var projectIDsByFolder: [UUID: [UUID]]
}
