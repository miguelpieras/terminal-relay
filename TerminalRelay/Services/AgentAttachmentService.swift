import Foundation

enum AgentAttachmentUploadError: LocalizedError {
    case failed
    case unsupported
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .failed:
            "The attachment could not be uploaded to the worker."
        case .unsupported:
            "This worker does not support that attachment type."
        case .tooLarge:
            "Attachments are limited to 25 MiB each."
        }
    }
}

enum AgentAttachmentService {
    @MainActor
    static func upload(
        _ attachment: ChatAttachmentDraft,
        requestID: String,
        session: TerminalSession,
        worker: ServerProfile
    ) async throws -> ChatAttachmentReference {
        guard attachment.byteCount <= ChatAttachmentPolicy.maximumFileBytes else {
            throw AgentAttachmentUploadError.tooLarge
        }
        if session.usesNativeChat {
            guard let accountID = session.accountID else {
                throw AgentAttachmentUploadError.failed
            }
            let configuration = SSHCommandBuilder.workerChatAttachmentUploadConfiguration(
                for: worker,
                kind: session.kind,
                accountID: accountID,
                repositoryName: session.projectName,
                relayID: session.instanceToken,
                requestID: requestID,
                attachmentID: attachment.id,
                fileExtension: attachment.fileExtension,
                byteCount: attachment.byteCount
            )
            let result = try await Subprocess.run(
                executable: URL(fileURLWithPath: configuration.executable),
                arguments: configuration.arguments,
                standardInput: attachment.data
            )
            guard result.exitCode == 0 else {
                throw AgentAttachmentUploadError.failed
            }
            return attachment.reference(path: try validatedPath(result.standardOutput))
        }
        guard attachment.kind == .image else {
            throw AgentAttachmentUploadError.unsupported
        }
        return attachment.reference(
            path: try await uploadLegacyPNG(
                attachment.data,
                session: session,
                worker: worker
            )
        )
    }

    @MainActor
    static func discardUpload(
        requestID: String,
        session: TerminalSession,
        worker: ServerProfile
    ) async {
        guard session.usesNativeChat else {
            return
        }
        guard let accountID = session.accountID else { return }
        let configuration = SSHCommandBuilder.workerChatAttachmentDeleteConfiguration(
            for: worker,
            kind: session.kind,
            accountID: accountID,
            repositoryName: session.projectName,
            relayID: session.instanceToken,
            requestID: requestID
        )
        _ = try? await Subprocess.run(
            executable: URL(fileURLWithPath: configuration.executable),
            arguments: configuration.arguments
        )
    }

    private static func uploadLegacyPNG(
        _ pngData: Data,
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

        return try validatedPath(result.standardOutput)
    }

    private static func validatedPath(_ data: Data) throws -> String {
        let path = String(decoding: data, as: UTF8.self)
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
