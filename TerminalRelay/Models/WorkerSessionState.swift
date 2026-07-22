import Foundation

struct WorkerSessionSnapshot: Equatable, Identifiable {
    let kind: AgentKind
    let repositoryName: String
    let attachedClientCount: Int
    let instanceToken: String

    var id: AgentKind { kind }
}

struct WorkerSessionResponse: Equatable {
    let projects: [String]
    let sessions: [WorkerSessionSnapshot]
}

enum WorkerSessionProtocolError: LocalizedError, Equatable {
    case missingMarker
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "The worker does not have the persistent-session helper installed."
        case .invalidRecord:
            "The worker returned an invalid persistent-session response."
        }
    }
}

enum WorkerSessionProtocol {
    static let marker = "__TERMINAL_RELAY_SESSION_V1__"
    static let helperPath = "/usr/local/bin/terminal-relay-session"

    static func parse(_ data: Data) throws -> WorkerSessionResponse {
        try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) throws -> WorkerSessionResponse {
        let lines = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)

        guard let markerIndex = lines.firstIndex(of: marker) else {
            throw WorkerSessionProtocolError.missingMarker
        }

        var projects: [String] = []
        var sessions: [WorkerSessionSnapshot] = []
        var seenProjects: Set<String> = []
        var seenKinds: Set<AgentKind> = []

        for line in lines.dropFirst(markerIndex + 1) where !line.isEmpty {
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)

            switch fields.first {
            case "project":
                guard fields.count == 2,
                      isValidRepositoryName(fields[1]),
                      seenProjects.insert(fields[1]).inserted else {
                    throw WorkerSessionProtocolError.invalidRecord
                }
                projects.append(fields[1])
            case "session":
                guard fields.count == 5,
                      let kind = AgentKind(rawValue: fields[1]),
                      isValidRepositoryName(fields[2]),
                      let attachedClientCount = Int(fields[3]),
                      attachedClientCount >= 0,
                      let instanceToken = UUID(uuidString: fields[4]),
                      seenKinds.insert(kind).inserted else {
                    throw WorkerSessionProtocolError.invalidRecord
                }
                let canonicalInstanceID = instanceToken.uuidString.lowercased()
                sessions.append(
                    WorkerSessionSnapshot(
                        kind: kind,
                        repositoryName: fields[2],
                        attachedClientCount: attachedClientCount,
                        instanceToken: canonicalInstanceID
                    )
                )
            default:
                throw WorkerSessionProtocolError.invalidRecord
            }
        }

        return WorkerSessionResponse(
            projects: projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            sessions: sessions.sorted { $0.kind.rawValue < $1.kind.rawValue }
        )
    }

    static func isValidRepositoryName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 100
            && value != "."
            && value != ".."
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }
}
