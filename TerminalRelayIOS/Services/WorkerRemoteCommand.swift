import Foundation

enum WorkerRemoteCommandError: LocalizedError, Equatable {
    case invalidRepositoryName
    case invalidInstanceToken

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryName:
            "The repository name is not safe to use on the worker."
        case .invalidInstanceToken:
            "The worker session identifier is invalid."
        }
    }
}

enum WorkerRemoteCommand {
    static let listProjects = "\(WorkerSessionProtocol.helperPath) list-projects"
    static let status = "\(WorkerSessionProtocol.helperPath) status"

    static func start(
        kind: AgentKind,
        repositoryName: String,
        launchArguments: [String]
    ) throws -> String {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerRemoteCommandError.invalidRepositoryName
        }

        let workingDirectory = "/workspace/\(repositoryName)"
        let command = [
            WorkerSessionProtocol.helperPath,
            "start",
            kind.rawValue,
            repositoryName,
        ] + launchArguments

        return "cd -- \(shellQuote(workingDirectory)) && exec \(command.map(shellQuote).joined(separator: " "))"
    }

    static func reattach(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) throws -> String {
        try validateSessionIdentity(
            repositoryName: repositoryName,
            instanceToken: instanceToken
        )

        let command = [
            WorkerSessionProtocol.helperPath,
            "reattach",
            kind.rawValue,
            repositoryName,
            instanceToken,
        ]
        return "exec \(command.map(shellQuote).joined(separator: " "))"
    }

    static func stop(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) throws -> String {
        try validateSessionIdentity(
            repositoryName: repositoryName,
            instanceToken: instanceToken
        )

        let arguments = [kind.rawValue, repositoryName, instanceToken]
            .map(shellQuote)
            .joined(separator: " ")
        return "\(WorkerSessionProtocol.helperPath) stop \(arguments)"
    }

    static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func validateSessionIdentity(
        repositoryName: String,
        instanceToken: String
    ) throws {
        guard WorkerSessionProtocol.isValidRepositoryName(repositoryName) else {
            throw WorkerRemoteCommandError.invalidRepositoryName
        }
        guard UUID(uuidString: instanceToken)?.uuidString.lowercased() == instanceToken else {
            throw WorkerRemoteCommandError.invalidInstanceToken
        }
    }
}
