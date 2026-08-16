import Foundation

enum WorkerSessionPresentation: String, Codable, Equatable {
    case terminal
    case chat
}

struct WorkerSessionSnapshot: Codable, Equatable, Identifiable {
    let kind: AgentKind
    let repositoryName: String
    let attachedClientCount: Int
    let instanceToken: String
    let title: String?
    let lastActivityAt: Int?
    let reportedWorking: Bool?
    let threadID: String?
    let presentation: WorkerSessionPresentation

    var id: String { instanceToken }

    init(
        kind: AgentKind,
        repositoryName: String,
        attachedClientCount: Int,
        instanceToken: String,
        title: String? = nil,
        lastActivityAt: Int? = nil,
        reportedWorking: Bool? = nil,
        threadID: String? = nil,
        presentation: WorkerSessionPresentation = .terminal
    ) {
        self.kind = kind
        self.repositoryName = repositoryName
        self.attachedClientCount = attachedClientCount
        self.instanceToken = instanceToken
        self.title = title
        self.lastActivityAt = lastActivityAt
        self.reportedWorking = reportedWorking
        self.threadID = threadID
        self.presentation = presentation
    }

    func isWorking(now: Date = Date()) -> Bool {
        if let reportedWorking {
            return reportedWorking
        }
        guard let lastActivityAt else { return false }
        return now.timeIntervalSince1970 - Double(lastActivityAt) < 8
    }
}

struct WorkerSessionResponse: Codable, Equatable {
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
        var seenInstances: Set<String> = []

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
                guard fields.count == 5 || fields.count == 7
                        || fields.count == 8 || fields.count == 9
                        || fields.count == 10,
                      let kind = AgentKind(rawValue: fields[1]),
                      isValidRepositoryName(fields[2]),
                      let attachedClientCount = Int(fields[3]),
                      attachedClientCount >= 0,
                      let instanceToken = UUID(uuidString: fields[4]) else {
                    throw WorkerSessionProtocolError.invalidRecord
                }
                let canonicalInstanceID = instanceToken.uuidString.lowercased()
                guard seenInstances.insert(canonicalInstanceID).inserted else {
                    throw WorkerSessionProtocolError.invalidRecord
                }
                let lastActivityAt: Int?
                let title: String?
                let reportedWorking: Bool?
                let threadID: String?
                let presentation: WorkerSessionPresentation
                if fields.count >= 7 {
                    guard let activity = Int(fields[5]), activity >= 0,
                          let decodedTitle = decodeHexUTF8(fields[6]),
                          decodedTitle.count <= 200 else {
                        throw WorkerSessionProtocolError.invalidRecord
                    }
                    lastActivityAt = activity
                    title = decodedTitle.isEmpty ? nil : decodedTitle
                    if fields.count >= 8 {
                        guard fields[7].isEmpty || fields[7] == "0" || fields[7] == "1" else {
                            throw WorkerSessionProtocolError.invalidRecord
                        }
                        reportedWorking = fields[7].isEmpty ? nil : fields[7] == "1"
                    } else {
                        reportedWorking = nil
                    }
                    if fields.count >= 9 {
                        if fields[8].isEmpty {
                            threadID = nil
                        } else {
                            guard let parsedThreadID = UUID(uuidString: fields[8]) else {
                                throw WorkerSessionProtocolError.invalidRecord
                            }
                            threadID = parsedThreadID.uuidString.lowercased()
                        }
                    } else {
                        threadID = nil
                    }
                    if fields.count == 10 {
                        guard let parsedPresentation = WorkerSessionPresentation(
                            rawValue: fields[9]
                        ) else {
                            throw WorkerSessionProtocolError.invalidRecord
                        }
                        presentation = parsedPresentation
                    } else {
                        presentation = .terminal
                    }
                } else {
                    lastActivityAt = nil
                    title = nil
                    reportedWorking = nil
                    threadID = nil
                    presentation = .terminal
                }
                sessions.append(
                    WorkerSessionSnapshot(
                        kind: kind,
                        repositoryName: fields[2],
                        attachedClientCount: attachedClientCount,
                        instanceToken: canonicalInstanceID,
                        title: title,
                        lastActivityAt: lastActivityAt,
                        reportedWorking: reportedWorking,
                        threadID: threadID,
                        presentation: presentation
                    )
                )
            default:
                throw WorkerSessionProtocolError.invalidRecord
            }
        }

        return WorkerSessionResponse(
            projects: projects.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
            sessions: sessions.sorted {
                let repositoryOrder = $0.repositoryName.localizedStandardCompare($1.repositoryName)
                if repositoryOrder != .orderedSame {
                    return repositoryOrder == .orderedAscending
                }
                let titleOrder = ($0.title ?? "").localizedStandardCompare($1.title ?? "")
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                if $0.kind != $1.kind {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.instanceToken < $1.instanceToken
            }
        )
    }

    static func isValidRepositoryName(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 100
            && value != "."
            && value != ".."
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    private static func decodeHexUTF8(_ value: String) -> String? {
        guard value.count.isMultiple(of: 2),
              value.range(of: #"^[a-f0-9]*$"#, options: .regularExpression) != nil else {
            return nil
        }
        var data = Data()
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return String(data: data, encoding: .utf8)
    }
}
