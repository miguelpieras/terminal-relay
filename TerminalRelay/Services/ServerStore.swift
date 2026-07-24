import Foundation
import Combine

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile]
    @Published private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let storageKey = "serverProfiles.v3"

    private static let bundledServers = [
        ServerProfile(
            name: "Terminal Relay Worker 1",
            host: "terminal-relay-worker-1",
            workingDirectory: "/workspace",
            codexAccountLabel: "Worker Codex",
            claudeAccountLabel: "Worker Claude",
            codexCommand: "/usr/local/bin/terminal-relay-session codex",
            claudeCommand: "/usr/local/bin/terminal-relay-session claude"
        )
    ]

    init(
        defaults: UserDefaults = .standard,
        initialServers: [ServerProfile]? = nil
    ) {
        self.defaults = defaults
        self.servers = initialServers ?? Self.bundledServers

        if defaults.data(forKey: storageKey) == nil {
            persist()
        } else {
            load()
        }
    }

    func server(id: UUID?) -> ServerProfile? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    func save(_ profile: ServerProfile) {
        if let index = servers.firstIndex(where: { $0.id == profile.id }) {
            servers[index] = profile
        } else {
            servers.append(profile)
        }

        persist()
    }

    func register(_ profile: ServerProfile) {
        if servers.contains(where: { $0.id == profile.id }) {
            save(profile)
            return
        }

        let matchingNameIndexes = servers.indices.filter {
            servers[$0].name == profile.name
        }
        if matchingNameIndexes.count == 1,
           profile.name.range(
               of: #"^Terminal Relay Worker [1-9][0-9]{0,5}$"#,
               options: .regularExpression
           ) != nil {
            var preservingLocalIdentity = profile
            preservingLocalIdentity.id = servers[matchingNameIndexes[0]].id
            servers[matchingNameIndexes[0]] = preservingLocalIdentity
            persist()
            return
        }

        save(profile)
    }

    func delete(id: UUID) {
        servers.removeAll { $0.id == id }
        persist()
    }

    func dismissPersistenceError() {
        persistenceError = nil
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }

        do {
            servers = try JSONDecoder().decode([ServerProfile].self, from: data)
            persistenceError = nil
        } catch {
            persistenceError = "Saved servers could not be read: \(error.localizedDescription)"
        }
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(servers)
            defaults.set(data, forKey: storageKey)
            persistenceError = nil
        } catch {
            persistenceError = "Servers could not be saved: \(error.localizedDescription)"
        }
    }
}
