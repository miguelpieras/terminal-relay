import CryptoKit
import Foundation

enum ReviewPairingGeneratorError: Error {
    case invalidArguments
}

@main
struct ReviewPairingGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 10,
              let port = Int(CommandLine.arguments[3]),
              (1...65_535).contains(port),
              let expiresAt = Int64(CommandLine.arguments[6]),
              let maximumDevices = Int(CommandLine.arguments[7]),
              (1...20).contains(maximumDevices) else {
            throw ReviewPairingGeneratorError.invalidArguments
        }

        let workerName = CommandLine.arguments[1]
        let host = CommandLine.arguments[2]
        let username = CommandLine.arguments[4]
        let fingerprint = CommandLine.arguments[5]
        let authorizedEntryPath = CommandLine.arguments[8]
        let codePath = CommandLine.arguments[9]
        let now = Date()
        let privateKey = Curve25519.Signing.PrivateKey()
        let token = UUID().uuidString.lowercased()
        let publicKey = openSSHPublicKey(
            privateKey.publicKey.rawRepresentation,
            comment: "terminal-relay-review-invitation:\(token)"
        )
        let forcedCommand =
            "/usr/local/bin/terminal-relay-review-enroll \(token) \(expiresAt) \(maximumDevices)"
        let authorizedEntry =
            #"restrict,command="\#(forcedCommand)" \#(publicKey)"#
        let payload = MobilePairingPayload(
            version: MobilePairingPayload.currentVersion,
            workerName: workerName,
            host: host,
            port: port,
            username: username,
            hostKeyFingerprint: fingerprint,
            temporaryPrivateKey: privateKey.rawRepresentation.base64EncodedString(),
            pairingToken: token,
            expiresAt: expiresAt,
            invitationKind: .appReview
        )
        let code = try MobilePairingPayloadCodec.encode(payload, now: now)

        try Data((authorizedEntry + "\n").utf8).write(
            to: URL(fileURLWithPath: authorizedEntryPath),
            options: .atomic
        )
        try Data(code.utf8).write(
            to: URL(fileURLWithPath: codePath),
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: authorizedEntryPath
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: codePath
        )
    }

    private static func openSSHPublicKey(_ key: Data, comment: String) -> String {
        var wireKey = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &wireKey)
        appendSSHString(key, to: &wireKey)
        return "ssh-ed25519 \(wireKey.base64EncodedString()) \(comment)"
    }

    private static func appendSSHString(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }
}
