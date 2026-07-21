import Foundation

struct ProjectProfile: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var serverID: UUID
    var githubRepository: String
    var workingDirectory: String

    init(
        id: UUID = UUID(),
        name: String = "",
        serverID: UUID,
        githubRepository: String = "",
        workingDirectory: String = ""
    ) {
        self.id = id
        self.name = name
        self.serverID = serverID
        self.githubRepository = githubRepository
        self.workingDirectory = workingDirectory
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isValid: Bool {
        !displayName.isEmpty
            && !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func hasAssignedServer(in servers: [ServerProfile]) -> Bool {
        servers.contains { $0.id == serverID }
    }
}
