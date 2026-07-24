import Foundation

enum AgentAttachmentUploadError: LocalizedError {
    case failed

    var errorDescription: String? {
        "The image could not be uploaded to the worker."
    }
}

enum AgentAttachmentService {
    static func upload(
        pngData: Data,
        session: TerminalSession,
        worker: ServerProfile
    ) async throws -> String {
        let fileName = "\(UUID().uuidString.lowercased()).png"
        let configuration = SSHCommandBuilder.attachmentUploadConfiguration(
            for: worker,
            instanceToken: session.instanceToken,
            fileName: fileName
        )
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: configuration.executable),
            arguments: configuration.arguments,
            standardInput: pngData
        )
        guard result.exitCode == 0 else {
            throw AgentAttachmentUploadError.failed
        }

        let path = String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"),
              path.count <= 1_000,
              path.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AgentAttachmentUploadError.failed
        }
        return path
    }
}
