import Foundation

/// Persists each conversation's reduced state on disk so reopening a thread
/// paints the transcript instantly from the cache while the live attach
/// resumes through the existing afterSeq/snapshotGeneration cursor: the
/// worker then replays only the delta, or a fresh snapshot when its
/// generation changed. The cache is a render head start, never an authority —
/// every hydrated conversation still reconciles against the worker.
actor ConversationStateCache {
    static let shared = ConversationStateCache()

    static let schemaVersion = 1
    static let retainedFileLimit = 60

    private struct Entry: Codable {
        let version: Int
        let savedAt: Date
        let state: ConversationState
    }

    private let directory: URL
    private var didPrune = false

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
            .appendingPathComponent(
                "Terminal Relay/Conversation Cache",
                isDirectory: true
            )
    }

    func load(for identity: ChatConversationIdentity) -> ConversationState? {
        guard let url = fileURL(for: identity),
              let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == Self.schemaVersion,
              !entry.state.items.isEmpty else {
            return nil
        }
        return entry.state
    }

    func save(_ state: ConversationState, for identity: ChatConversationIdentity) {
        guard let url = fileURL(for: identity), !state.items.isEmpty else {
            return
        }
        guard let data = try? JSONEncoder().encode(
            Entry(version: Self.schemaVersion, savedAt: Date(), state: state)
        ) else {
            return
        }
        let manager = FileManager.default
        try? manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            try data.write(to: url, options: [.atomic])
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            return
        }
        pruneIfNeeded()
    }

    func remove(for identity: ChatConversationIdentity) {
        guard let url = fileURL(for: identity) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Cache files are keyed by the stable provider thread ID; per-run relay
    /// IDs would never be read back. Components are restricted to validated
    /// identifier characters so no identity can traverse the directory.
    private func fileURL(for identity: ChatConversationIdentity) -> URL? {
        guard let threadID = identity.providerThreadID,
              !threadID.isEmpty,
              threadID.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            return nil
        }
        let provider = identity.provider.rawValue.filter {
            $0.isLetter || $0.isNumber
        }
        guard !provider.isEmpty else { return nil }
        return directory.appendingPathComponent("\(provider)-\(threadID).json")
    }

    /// Bounds the cache to the most recently saved conversations, once per
    /// process run.
    private func pruneIfNeeded() {
        guard !didPrune else { return }
        didPrune = true
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            return
        }
        let dated = files.map { url in
            (
                url: url,
                modified: (try? url.resourceValues(
                    forKeys: [.contentModificationDateKey]
                ))?.contentModificationDate ?? .distantPast
            )
        }
        .sorted { $0.modified > $1.modified }
        for stale in dated.dropFirst(Self.retainedFileLimit) {
            try? manager.removeItem(at: stale.url)
        }
    }
}
