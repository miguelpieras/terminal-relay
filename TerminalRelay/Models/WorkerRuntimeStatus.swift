import Foundation

struct WorkerRuntimeInfo: Equatable {
    static let clientProtocolVersion = 2

    let version: Int
    let minimumProtocol: Int
    let maximumProtocol: Int
    let capabilities: Set<String>

    var isClientProtocolCompatible: Bool {
        minimumProtocol <= Self.clientProtocolVersion
            && maximumProtocol >= Self.clientProtocolVersion
    }

    func supports(_ capability: String) -> Bool {
        isClientProtocolCompatible && capabilities.contains(capability)
    }
}

enum WorkerRuntimeUpdateResult: String, Equatable {
    case checking
    case success
    case failure
}

struct WorkerRuntimeUpdateStatus: Equatable {
    let timestamp: Int
    let result: WorkerRuntimeUpdateResult
    let installedVersion: Int
    let targetVersion: Int
    let failureCode: String

    var message: String? {
        switch result {
        case .checking:
            "Updating worker runtime…"
        case .success:
            nil
        case .failure:
            "Worker runtime update failed (\(failureCode)). Existing sessions are unchanged and the worker will retry."
        }
    }
}

enum WorkerRuntimeProtocolError: LocalizedError, Equatable {
    case missingMarker
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .missingMarker:
            "The worker runtime protocol is unavailable."
        case .invalidRecord:
            "The worker returned invalid runtime information."
        }
    }
}

enum WorkerRuntimeInfoProtocol {
    static let marker = "__TERMINAL_RELAY_RUNTIME_INFO_V1__"

    static func parse(_ data: Data) throws -> WorkerRuntimeInfo {
        let records = try records(after: marker, in: data)
        guard records.count == 1 else {
            throw WorkerRuntimeProtocolError.invalidRecord
        }
        let fields = records[0]
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 5,
              fields[0] == "runtime",
              let version = Int(fields[1]),
              version > 0,
              let minimum = Int(fields[2]),
              minimum > 0,
              let maximum = Int(fields[3]),
              maximum >= minimum else {
            throw WorkerRuntimeProtocolError.invalidRecord
        }
        let capabilities = fields[4].split(separator: ",").map(String.init)
        guard !capabilities.isEmpty,
              capabilities == capabilities.sorted(),
              Set(capabilities).count == capabilities.count,
              capabilities.allSatisfy(isValidToken) else {
            throw WorkerRuntimeProtocolError.invalidRecord
        }
        return WorkerRuntimeInfo(
            version: version,
            minimumProtocol: minimum,
            maximumProtocol: maximum,
            capabilities: Set(capabilities)
        )
    }
}

enum WorkerRuntimeUpdateStatusProtocol {
    static let marker = "__TERMINAL_RELAY_RUNTIME_UPDATE_V1__"

    static func parse(_ data: Data) throws -> WorkerRuntimeUpdateStatus? {
        let records = try records(after: marker, in: data)
        guard !records.isEmpty else { return nil }
        guard records.count == 1 else {
            throw WorkerRuntimeProtocolError.invalidRecord
        }
        let fields = records[0]
            .split(separator: "|", omittingEmptySubsequences: false)
            .map(String.init)
        guard fields.count == 6,
              fields[0] == "runtime-update",
              let timestamp = Int(fields[1]),
              timestamp > 0,
              let result = WorkerRuntimeUpdateResult(rawValue: fields[2]),
              let installed = Int(fields[3]),
              installed >= 0,
              let target = Int(fields[4]),
              target >= 0,
              isValidToken(fields[5]) else {
            throw WorkerRuntimeProtocolError.invalidRecord
        }
        return WorkerRuntimeUpdateStatus(
            timestamp: timestamp,
            result: result,
            installedVersion: installed,
            targetVersion: target,
            failureCode: fields[5]
        )
    }
}

private func records(after marker: String, in data: Data) throws -> [String] {
    let lines = String(decoding: data, as: UTF8.self)
        .split(whereSeparator: \.isNewline)
        .map(String.init)
    guard let markerIndex = lines.firstIndex(of: marker) else {
        throw WorkerRuntimeProtocolError.missingMarker
    }
    return Array(lines.dropFirst(markerIndex + 1).filter { !$0.isEmpty })
}

private func isValidToken(_ value: String) -> Bool {
    value.range(
        of: #"^[a-z0-9][a-z0-9-]{0,63}$"#,
        options: .regularExpression
    ) != nil
}
