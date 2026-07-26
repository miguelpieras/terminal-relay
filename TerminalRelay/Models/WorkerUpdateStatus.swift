import Foundation

enum WorkerUpdateResult: String, Equatable {
    case success
    case failure
}

struct WorkerUpdateStatus: Equatable {
    let timestamp: Int
    let result: WorkerUpdateResult
    let codexVersion: String
    let claudeVersion: String

    var warningMessage: String? {
        guard result == .failure else { return nil }
        return "Automatic agent update failed. Codex \(codexVersion) and Claude Code \(claudeVersion) remain available; the worker will retry automatically."
    }
}

enum WorkerUpdateStatusProtocolError: LocalizedError, Equatable {
    case missingMarker
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "The worker did not return agent update status."
        case .invalidRecord:
            "The worker returned invalid agent update status."
        }
    }
}

enum WorkerUpdateStatusProtocol {
    static let marker = "__TERMINAL_RELAY_AGENT_UPDATE_V1__"

    static func parse(_ data: Data) throws -> WorkerUpdateStatus? {
        try parse(String(decoding: data, as: UTF8.self))
    }

    static func parse(_ output: String) throws -> WorkerUpdateStatus? {
        let lines = output
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
        guard let markerIndex = lines.firstIndex(of: marker) else {
            throw WorkerUpdateStatusProtocolError.missingMarker
        }

        let records = lines.dropFirst(markerIndex + 1).filter { !$0.isEmpty }
        guard !records.isEmpty else { return nil }
        guard records.count == 1 else {
            throw WorkerUpdateStatusProtocolError.invalidRecord
        }

        let fields = records[0]
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 5,
              fields[0] == "update",
              let timestamp = Int(fields[1]),
              timestamp > 0,
              let result = WorkerUpdateResult(rawValue: fields[2]),
              isValidVersion(fields[3]),
              isValidVersion(fields[4]) else {
            throw WorkerUpdateStatusProtocolError.invalidRecord
        }
        return WorkerUpdateStatus(
            timestamp: timestamp,
            result: result,
            codexVersion: fields[3],
            claudeVersion: fields[4]
        )
    }

    private static func isValidVersion(_ value: String) -> Bool {
        value == "unknown"
            || value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#,
                options: .regularExpression
            ) != nil
    }
}
