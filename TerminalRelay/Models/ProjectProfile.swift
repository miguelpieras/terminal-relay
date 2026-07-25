import Foundation

struct ProjectProfile: Codable, Hashable, Identifiable {
    static let defaultRepositoryOwner = ""

    var id: UUID
    var serverID: UUID
    var repositoryOwner: String
    var repositoryName: String

    init(
        id: UUID = UUID(),
        serverID: UUID,
        repositoryOwner: String = Self.defaultRepositoryOwner,
        repositoryName: String = ""
    ) {
        self.id = id
        self.serverID = serverID
        self.repositoryOwner = repositoryOwner
        self.repositoryName = repositoryName
    }

    var displayName: String {
        repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var githubRepository: String {
        "\(repositoryOwner.trimmingCharacters(in: .whitespacesAndNewlines))/\(displayName)"
    }

    var workingDirectory: String {
        "/workspace/\(displayName)"
    }

    var isValid: Bool {
        let owner = repositoryOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        return !owner.isEmpty
            && !displayName.isEmpty
            && !owner.contains("/")
            && !displayName.contains("/")
            && displayName != "."
            && displayName != ".."
            && owner.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil
            && displayName.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            && displayName.count <= 100
    }

    static func normalizedRepositoryName(from value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        let components = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        let slug = components
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String(slug.prefix(100))
    }

    func hasAssignedServer(in servers: [ServerProfile]) -> Bool {
        servers.contains { $0.id == serverID }
    }
}
