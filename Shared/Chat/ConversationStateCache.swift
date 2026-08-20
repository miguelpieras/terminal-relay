import Foundation

protocol ConversationStateCaching: Sendable {
    func load(for identity: ChatConversationIdentity) async -> ConversationState?
    func save(
        _ state: ConversationState,
        for identity: ChatConversationIdentity
    ) async
}

/// Removes the transcript cache written by older Terminal Relay releases.
/// Conversation content is intentionally memory-only now; provider-native
/// history remains authoritative and is never touched here.
enum ConversationStateCacheMaintenance {
    static func legacyDirectory(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let base = applicationSupportDirectory
            ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
        return base
            .appendingPathComponent("Terminal Relay", isDirectory: true)
            .appendingPathComponent("Conversation Cache", isDirectory: true)
    }

    @discardableResult
    static func purgeLegacyCache(
        applicationSupportDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        let directory = legacyDirectory(
            applicationSupportDirectory: applicationSupportDirectory,
            fileManager: fileManager
        )
        guard directory.lastPathComponent == "Conversation Cache",
              directory.deletingLastPathComponent().lastPathComponent == "Terminal Relay" else {
            return false
        }
        guard fileManager.fileExists(atPath: directory.path) else {
            return true
        }
        do {
            try fileManager.removeItem(at: directory)
            return true
        } catch {
            return false
        }
    }
}
