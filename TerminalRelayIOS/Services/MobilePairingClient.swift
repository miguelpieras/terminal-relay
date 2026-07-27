import Foundation
import NIOSSH

enum MobilePairingClientError: LocalizedError {
    case invalidTemporaryKey
    case invalidWorkerResponse

    var errorDescription: String? {
        switch self {
        case .invalidTemporaryKey:
            "This Terminal Relay pairing code contains an invalid temporary key."
        case .invalidWorkerResponse:
            "The worker did not confirm mobile pairing."
        }
    }
}

final class MobilePairingClient {
    static let enrollmentMarker = "__TERMINAL_RELAY_DEVICE_ENROLLMENT_V1__"

    private let identityStore: SSHIdentityStore
    private let workerClient: SSHWorkerClient

    init(identityStore: SSHIdentityStore) {
        self.identityStore = identityStore
        self.workerClient = SSHWorkerClient(identityStore: identityStore)
    }

    func pair(
        payload: MobilePairingPayload,
        existingProfileID: UUID? = nil,
        now: Date = Date()
    ) async throws -> WorkerProfile {
        try payload.validate(now: now)
        let profile = try WorkerProfile.validated(
            id: existingProfileID ?? UUID(),
            name: payload.workerName,
            host: payload.host,
            port: payload.port,
            username: payload.username,
            expectedHostKeyFingerprint: payload.hostKeyFingerprint
        )

        guard let keyMaterial = Data(base64Encoded: payload.temporaryPrivateKey) else {
            throw MobilePairingClientError.invalidTemporaryKey
        }
        let temporaryKey: NIOSSHPrivateKey
        do {
            temporaryKey = try NIOSSHPrivateKey(
                ed25519Key: .init(rawRepresentation: keyMaterial)
            )
        } catch {
            throw MobilePairingClientError.invalidTemporaryKey
        }

        let publicKey = try identityStore.publicKeyForAuthorizedKeys()
        let command = Self.enrollmentCommand(publicKey: publicKey)
        let output = try await workerClient.execute(
            command,
            on: profile,
            privateKey: temporaryKey
        )
        try Self.validateEnrollmentResponse(output)
        return profile
    }

    static func enrollmentCommand(publicKey: String) -> String {
        let encodedPublicKey = Data(publicKey.utf8).base64EncodedString()
        return "terminal-relay-enroll-device \(encodedPublicKey)"
    }

    static func validateEnrollmentResponse(_ output: Data) throws {
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let markerIndex = lines.firstIndex(of: enrollmentMarker),
              markerIndex + 1 < lines.count,
              lines[markerIndex + 1] == "paired" else {
            throw MobilePairingClientError.invalidWorkerResponse
        }
    }
}
