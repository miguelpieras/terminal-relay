import Foundation

struct WorkerThreadCapabilities: Codable, Equatable {
    let resume: Bool
    let rename: Bool
    let archive: Bool
    let unarchive: Bool

    static let dormantCodex = WorkerThreadCapabilities(
        resume: true,
        rename: true,
        archive: true,
        unarchive: false
    )
    static let archivedCodex = WorkerThreadCapabilities(
        resume: false,
        rename: false,
        archive: false,
        unarchive: true
    )
    static let dormant = dormantCodex
    static let archived = archivedCodex
    static let active = WorkerThreadCapabilities(
        resume: false,
        rename: false,
        archive: false,
        unarchive: false
    )
}

enum WorkerThreadActivityState: String, Codable, Equatable {
    case inactive
    case relayActive = "relay-active"
    case externalActive = "external-active"
    case unknown
}

struct WorkerThreadSnapshot: Codable, Equatable, Identifiable {
    let kind: AgentKind
    let accountID: ProviderAccountID?
    let repositoryName: String
    let threadID: String
    let title: String?
    let updatedAt: Int
    let isArchived: Bool
    let activityState: WorkerThreadActivityState
    let activeInstanceToken: String?
    let reportedWorking: Bool?
    let capabilities: WorkerThreadCapabilities

    init(
        kind: AgentKind,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        threadID: String,
        title: String?,
        updatedAt: Int,
        isArchived: Bool,
        activityState: WorkerThreadActivityState = .inactive,
        activeInstanceToken: String?,
        reportedWorking: Bool?,
        capabilities: WorkerThreadCapabilities
    ) {
        self.kind = kind
        self.accountID = accountID
        self.repositoryName = repositoryName
        self.threadID = threadID
        self.title = title
        self.updatedAt = updatedAt
        self.isArchived = isArchived
        self.activityState = activityState
        self.activeInstanceToken = activeInstanceToken
        self.reportedWorking = reportedWorking
        self.capabilities = capabilities
    }

    var id: String {
        "\(kind.rawValue):\(accountID?.rawValue ?? "legacy"):\(threadID)"
    }
    var isActive: Bool {
        activityState == .relayActive || activityState == .externalActive
    }
    var isAttachable: Bool {
        activityState == .relayActive && activeInstanceToken != nil
    }
}

struct WorkerThreadResponse: Codable, Equatable {
    let threads: [WorkerThreadSnapshot]
    let nextCursor: String?

    func merging(liveSessions: [WorkerSessionSnapshot]) -> WorkerThreadResponse {
        var merged: [String: WorkerThreadSnapshot] = [:]
        for thread in threads {
            if thread.activityState == .relayActive {
                merged[thread.id] = WorkerThreadSnapshot(
                    kind: thread.kind,
                    accountID: thread.accountID,
                    repositoryName: thread.repositoryName,
                    threadID: thread.threadID,
                    title: thread.title,
                    updatedAt: thread.updatedAt,
                    isArchived: thread.isArchived,
                    activityState: .inactive,
                    activeInstanceToken: nil,
                    reportedWorking: nil,
                    capabilities: thread.isArchived ? .archived : .dormant
                )
            } else {
                merged[thread.id] = thread
            }
        }
        for session in liveSessions {
            guard let threadID = session.threadID else { continue }
            let id = "\(session.kind.rawValue):\(session.accountID?.rawValue ?? "legacy"):\(threadID)"
            merged[id] = WorkerThreadSnapshot(
                kind: session.kind,
                accountID: session.accountID,
                repositoryName: session.repositoryName,
                threadID: threadID,
                title: session.title ?? merged[id]?.title,
                updatedAt: session.lastActivityAt ?? merged[id]?.updatedAt ?? 0,
                isArchived: false,
                activityState: .relayActive,
                activeInstanceToken: session.instanceToken,
                reportedWorking: session.reportedWorking,
                capabilities: .active
            )
        }
        return WorkerThreadResponse(
            threads: merged.values.sorted {
                if $0.isActive != $1.isActive { return $0.isActive }
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.threadID < $1.threadID
            },
            nextCursor: nextCursor
        )
    }
}

struct WorkerThreadCatalogKey: Codable, Hashable {
    let workerID: UUID
    let provider: AgentKind?
    let accountID: ProviderAccountID?
    let repositoryName: String
    let archived: Bool

    init(
        workerID: UUID,
        provider: AgentKind? = nil,
        accountID: ProviderAccountID? = nil,
        repositoryName: String,
        archived: Bool
    ) {
        self.workerID = workerID
        self.provider = provider
        self.accountID = accountID
        self.repositoryName = repositoryName
        self.archived = archived
    }
}

enum WorkerThreadProtocolError: LocalizedError, Equatable {
    case missingMarker
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "This worker does not support project thread management yet."
        case .invalidResponse:
            "The worker returned an invalid thread catalog."
        }
    }
}

enum WorkerThreadProtocol {
    static let marker = "__TERMINAL_RELAY_THREADS_V3__"
    static let previousMarker = "__TERMINAL_RELAY_THREADS_V2__"
    static let legacyMarker = "__TERMINAL_RELAY_THREADS_V1__"

    private struct WireResponse: Decodable {
        let threads: [WireThread]
        let nextCursor: String?
    }

    private struct WireThread: Decodable {
        let provider: String
        let accountID: ProviderAccountID?
        let threadID: String
        let title: String?
        let updatedAt: Int
        let archived: Bool
        let activityState: WorkerThreadActivityState?
        let activeInstanceToken: String?
        let isWorking: Bool?
        let capabilities: WorkerThreadCapabilities
    }

    static func parse(
        _ data: Data,
        repositoryName: String,
        expectedAccountID: ProviderAccountID? = nil
    ) throws -> WorkerThreadResponse {
        try parse(
            String(decoding: data, as: UTF8.self),
            repositoryName: repositoryName,
            expectedAccountID: expectedAccountID
        )
    }

    static func parse(
        _ output: String,
        repositoryName: String,
        expectedAccountID: ProviderAccountID? = nil
    ) throws -> WorkerThreadResponse {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerThreadProtocolError.invalidResponse
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let isV3 = lines.contains(marker)
        let selectedMarker = isV3 ? marker : (
            lines.contains(previousMarker) ? previousMarker : legacyMarker
        )
        guard expectedAccountID == nil || isV3,
              let markerIndex = lines.firstIndex(of: selectedMarker) else {
            throw WorkerThreadProtocolError.missingMarker
        }
        guard lines.count == markerIndex + 2,
              let data = lines[markerIndex + 1].data(using: .utf8),
              data.count <= ChatNDJSONDecoder.maximumRecordBytes,
              let value = try? JSONDecoder().decode(WireResponse.self, from: data),
              value.threads.count <= 1_000,
              value.nextCursor.map({ $0.utf8.count <= 2_048 && !$0.contains("\n") }) != false else {
            throw WorkerThreadProtocolError.invalidResponse
        }

        var seenIDs: Set<String> = []
        let threads = try value.threads.map { thread -> WorkerThreadSnapshot in
            guard let kind = AgentKind(rawValue: thread.provider),
                  (!isV3 || thread.accountID != nil),
                  (expectedAccountID == nil || thread.accountID == expectedAccountID),
                  let parsedThreadID = UUID(uuidString: thread.threadID),
                  parsedThreadID.uuidString.lowercased() == thread.threadID,
                  thread.updatedAt >= 0,
                  thread.title.map({ $0.utf8.count <= 200 }) != false,
                  thread.activeInstanceToken.map({
                      UUID(uuidString: $0)?.uuidString.lowercased() == $0
                  }) != false,
                  seenIDs.insert("\(kind.rawValue):\(thread.accountID?.rawValue ?? "legacy"):\(thread.threadID)").inserted else {
                throw WorkerThreadProtocolError.invalidResponse
            }
            let activityState: WorkerThreadActivityState
            if isV3 || selectedMarker == previousMarker {
                guard let reportedActivity = thread.activityState else {
                    throw WorkerThreadProtocolError.invalidResponse
                }
                activityState = reportedActivity
            } else {
                activityState = thread.activeInstanceToken == nil ? .inactive : .relayActive
            }
            let expectedCapabilities: WorkerThreadCapabilities
            if activityState != .inactive {
                expectedCapabilities = .active
            } else if thread.archived {
                expectedCapabilities = .archived
            } else {
                expectedCapabilities = .dormant
            }
            guard thread.capabilities == expectedCapabilities,
                  activityState == .relayActive || thread.isWorking == nil,
                  (activityState == .relayActive) == (thread.activeInstanceToken != nil) else {
                throw WorkerThreadProtocolError.invalidResponse
            }
            return WorkerThreadSnapshot(
                kind: kind,
                accountID: thread.accountID,
                repositoryName: repositoryName,
                threadID: thread.threadID,
                title: thread.title,
                updatedAt: thread.updatedAt,
                isArchived: thread.archived,
                activityState: activityState,
                activeInstanceToken:
                    thread.activeInstanceToken,
                reportedWorking: thread.isWorking,
                capabilities: thread.capabilities
            )
        }
        return WorkerThreadResponse(threads: threads, nextCursor: value.nextCursor)
    }
}
