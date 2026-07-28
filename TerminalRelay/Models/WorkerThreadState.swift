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
    static let active = WorkerThreadCapabilities(
        resume: false,
        rename: false,
        archive: false,
        unarchive: false
    )
}

struct WorkerThreadSnapshot: Equatable, Identifiable {
    let kind: AgentKind
    let repositoryName: String
    let threadID: String
    let title: String?
    let updatedAt: Int
    let isArchived: Bool
    let activeInstanceToken: String?
    let reportedWorking: Bool?
    let capabilities: WorkerThreadCapabilities

    var id: String { "\(kind.rawValue):\(threadID)" }
    var isActive: Bool { activeInstanceToken != nil }
}

struct WorkerThreadResponse: Equatable {
    let threads: [WorkerThreadSnapshot]
    let nextCursor: String?

    func merging(liveSessions: [WorkerSessionSnapshot]) -> WorkerThreadResponse {
        var merged: [String: WorkerThreadSnapshot] = [:]
        for thread in threads {
            if thread.kind == .claude, thread.isActive {
                continue
            }
            merged[thread.id] = WorkerThreadSnapshot(
                kind: thread.kind,
                repositoryName: thread.repositoryName,
                threadID: thread.threadID,
                title: thread.title,
                updatedAt: thread.updatedAt,
                isArchived: thread.isArchived,
                activeInstanceToken: nil,
                reportedWorking: nil,
                capabilities: thread.isArchived ? .archivedCodex : .dormantCodex
            )
        }
        for session in liveSessions {
            guard let threadID = session.threadID else { continue }
            let id = "\(session.kind.rawValue):\(threadID)"
            merged[id] = WorkerThreadSnapshot(
                kind: session.kind,
                repositoryName: session.repositoryName,
                threadID: threadID,
                title: session.title ?? merged[id]?.title,
                updatedAt: session.lastActivityAt ?? merged[id]?.updatedAt ?? 0,
                isArchived: false,
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

struct WorkerThreadCatalogKey: Hashable {
    let workerID: UUID
    let repositoryName: String
    let archived: Bool
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
    static let marker = "__TERMINAL_RELAY_THREADS_V1__"

    private struct WireResponse: Decodable {
        let threads: [WireThread]
        let nextCursor: String?
    }

    private struct WireThread: Decodable {
        let provider: String
        let threadID: String
        let title: String?
        let updatedAt: Int
        let archived: Bool
        let activeInstanceToken: String?
        let isWorking: Bool?
        let capabilities: WorkerThreadCapabilities
    }

    static func parse(
        _ data: Data,
        repositoryName: String
    ) throws -> WorkerThreadResponse {
        try parse(String(decoding: data, as: UTF8.self), repositoryName: repositoryName)
    }

    static func parse(
        _ output: String,
        repositoryName: String
    ) throws -> WorkerThreadResponse {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerThreadProtocolError.invalidResponse
        }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard let markerIndex = lines.firstIndex(of: marker) else {
            throw WorkerThreadProtocolError.missingMarker
        }
        guard lines.indices.contains(markerIndex + 1),
              let data = lines[markerIndex + 1].data(using: .utf8),
              let value = try? JSONDecoder().decode(WireResponse.self, from: data),
              value.nextCursor.map({ $0.utf8.count <= 2_048 && !$0.contains("\n") }) != false else {
            throw WorkerThreadProtocolError.invalidResponse
        }

        var seenIDs: Set<String> = []
        let threads = try value.threads.map { thread -> WorkerThreadSnapshot in
            guard let kind = AgentKind(rawValue: thread.provider),
                  let parsedThreadID = UUID(uuidString: thread.threadID),
                  parsedThreadID.uuidString.lowercased() == thread.threadID,
                  thread.updatedAt >= 0,
                  thread.title.map({ $0.utf8.count <= 200 }) != false,
                  thread.activeInstanceToken.map({
                      UUID(uuidString: $0)?.uuidString.lowercased() == $0
                  }) != false,
                  seenIDs.insert("\(kind.rawValue):\(thread.threadID)").inserted else {
                throw WorkerThreadProtocolError.invalidResponse
            }
            let isActive = thread.activeInstanceToken != nil
            let expectedCapabilities: WorkerThreadCapabilities
            if isActive {
                expectedCapabilities = .active
            } else if thread.archived {
                expectedCapabilities = .archivedCodex
            } else {
                expectedCapabilities = .dormantCodex
            }
            guard thread.capabilities == expectedCapabilities,
                  !thread.archived || !isActive,
                  isActive || thread.isWorking == nil,
                  kind != .claude || isActive else {
                throw WorkerThreadProtocolError.invalidResponse
            }
            return WorkerThreadSnapshot(
                kind: kind,
                repositoryName: repositoryName,
                threadID: thread.threadID,
                title: thread.title,
                updatedAt: thread.updatedAt,
                isArchived: thread.archived,
                activeInstanceToken:
                    thread.activeInstanceToken,
                reportedWorking: thread.isWorking,
                capabilities: thread.capabilities
            )
        }
        return WorkerThreadResponse(threads: threads, nextCursor: value.nextCursor)
    }
}
