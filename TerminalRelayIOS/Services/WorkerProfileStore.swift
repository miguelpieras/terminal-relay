import Foundation

final class WorkerProfileStore {
    private enum Key {
        static let profile = "terminalRelayIOS.workerProfile.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> WorkerProfile? {
        guard let data = defaults.data(forKey: Key.profile) else { return nil }
        return try? JSONDecoder().decode(WorkerProfile.self, from: data)
    }

    func save(_ profile: WorkerProfile) throws {
        defaults.set(try JSONEncoder().encode(profile), forKey: Key.profile)
    }

    func clear() {
        defaults.removeObject(forKey: Key.profile)
    }
}
