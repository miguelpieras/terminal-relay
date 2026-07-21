import Foundation
import Combine

@MainActor
final class ServerStore: ObservableObject {
    @Published private(set) var servers: [ServerProfile]
    @Published private(set) var persistenceError: String?

    private let defaults: UserDefaults
    private let storageKey = "serverProfiles.v2"

    private static let bundledServers = [
        ServerProfile(
            name: "Agent Console Worker 1",
            host: "agent-console-worker-1",
            workingDirectory: "/workspace",
            codexAccountLabel: "Worker Codex",
            claudeAccountLabel: "Worker Claude",
            codexCommand: "/usr/local/bin/agent-console-session codex",
            claudeCommand: "/usr/local/bin/agent-console-session claude"
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
