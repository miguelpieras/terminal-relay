import Foundation

final class WorkerProfileStore {
    private enum Key {
        static let legacyProfile = "terminalRelayIOS.workerProfile.v1"
        static let profiles = "terminalRelayIOS.workerProfiles.v2"
        static let selectedProfileID = "terminalRelayIOS.selectedWorkerProfileID.v2"
    }

    private struct LegacyWorkerProfile: Codable {
        let host: String
        let port: Int
        let username: String
        let expectedHostKeyFingerprint: String
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [WorkerProfile] {
        if let data = defaults.data(forKey: Key.profiles),
           let profiles = try? JSONDecoder().decode([WorkerProfile].self, from: data) {
            return profiles
        }

        guard let data = defaults.data(forKey: Key.legacyProfile),
              let legacyProfile = try? JSONDecoder().decode(LegacyWorkerProfile.self, from: data),
              let migratedProfile = try? WorkerProfile.validated(
                  name: legacyProfile.host,
                  host: legacyProfile.host,
                  port: legacyProfile.port,
                  username: legacyProfile.username,
                  expectedHostKeyFingerprint: legacyProfile.expectedHostKeyFingerprint
              ) else {
            return []
        }

        persist([migratedProfile])
        defaults.set(migratedProfile.id.uuidString, forKey: Key.selectedProfileID)
        defaults.removeObject(forKey: Key.legacyProfile)
        return [migratedProfile]
    }

    func save(_ profile: WorkerProfile) throws {
        var profiles = load()
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        defaults.set(try JSONEncoder().encode(profiles), forKey: Key.profiles)
    }

    func delete(id: UUID) {
        let profiles = load().filter { $0.id != id }
        persist(profiles)
        if selectedProfileID() == id {
            setSelectedProfileID(profiles.first?.id)
        }
    }

    func selectedProfileID() -> UUID? {
        defaults.string(forKey: Key.selectedProfileID).flatMap(UUID.init(uuidString:))
    }

    func setSelectedProfileID(_ id: UUID?) {
        if let id {
            defaults.set(id.uuidString, forKey: Key.selectedProfileID)
        } else {
            defaults.removeObject(forKey: Key.selectedProfileID)
        }
    }

    private func persist(_ profiles: [WorkerProfile]) {
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: Key.profiles)
        }
    }
}
