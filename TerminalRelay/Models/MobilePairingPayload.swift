import Foundation

struct MobilePairingPayload: Codable, Equatable {
    static let currentVersion = 1
    static let maximumLifetime: TimeInterval = 15 * 60

    let version: Int
    let workerName: String
    let host: String
    let port: Int
    let username: String
    let hostKeyFingerprint: String
    let temporaryPrivateKey: String
    let pairingToken: String
    let expiresAt: Int64

    func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw MobilePairingPayloadError.unsupportedVersion
        }
        guard !workerName.isEmpty,
              workerName.count <= 80,
              workerName == workerName.trimmingCharacters(in: .whitespacesAndNewlines),
              !workerName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MobilePairingPayloadError.invalidPayload
        }
        guard !host.isEmpty,
              host.count <= 253,
              host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)
              }),
              (1...65_535).contains(port),
              username.range(
                  of: #"^[A-Za-z_][A-Za-z0-9._-]{0,63}$"#,
                  options: .regularExpression
              ) != nil
        else {
            throw MobilePairingPayloadError.invalidPayload
        }

        let fingerprintPrefix = "SHA256:"
        let fingerprintDigest = String(hostKeyFingerprint.dropFirst(fingerprintPrefix.count))
        let fingerprintPadding = String(
            repeating: "=",
            count: (4 - fingerprintDigest.count % 4) % 4
        )
        guard hostKeyFingerprint.hasPrefix(fingerprintPrefix),
              fingerprintDigest.range(
                  of: #"^[A-Za-z0-9+/]+$"#,
                  options: .regularExpression
              ) != nil,
              let fingerprintData = Data(
                  base64Encoded: fingerprintDigest + fingerprintPadding
              ),
              fingerprintData.count == 32
        else {
            throw MobilePairingPayloadError.invalidPayload
        }

        guard let privateKey = Data(base64Encoded: temporaryPrivateKey),
              privateKey.count == 32,
              privateKey.base64EncodedString() == temporaryPrivateKey,
              let token = UUID(uuidString: pairingToken),
              token.uuidString.lowercased() == pairingToken
        else {
            throw MobilePairingPayloadError.invalidPayload
        }

        let nowSeconds = Int64(now.timeIntervalSince1970)
        guard expiresAt > nowSeconds else {
            throw MobilePairingPayloadError.expired
        }
        guard expiresAt <= nowSeconds + Int64(Self.maximumLifetime) else {
            throw MobilePairingPayloadError.invalidPayload
        }
    }
}

enum MobilePairingPayloadError: LocalizedError, Equatable {
    case invalidCode
    case invalidPayload
    case unsupportedVersion
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidCode, .invalidPayload:
            "This is not a valid Terminal Relay pairing code."
        case .unsupportedVersion:
            "This pairing code was created by an unsupported version of Terminal Relay."
        case .expired:
            "This pairing code has expired. Create a new one on your Mac."
        }
    }
}

enum MobilePairingPayloadCodec {
    private static let scheme = "terminal-relay"
    private static let host = "pair-device"
    private static let maximumCodeLength = 4_096

    static func encode(_ payload: MobilePairingPayload, now: Date = Date()) throws -> String {
        try payload.validate(now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedPayload = base64URLEncoded(try encoder.encode(payload))

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [
            URLQueryItem(name: "v", value: String(MobilePairingPayload.currentVersion)),
            URLQueryItem(name: "payload", value: encodedPayload),
        ]
        guard let code = components.url?.absoluteString,
              code.utf8.count <= maximumCodeLength else {
            throw MobilePairingPayloadError.invalidPayload
        }
        return code
    }

    static func decode(_ code: String, now: Date = Date()) throws -> MobilePairingPayload {
        guard !code.isEmpty,
              code.utf8.count <= maximumCodeLength,
              let components = URLComponents(string: code),
              components.scheme == scheme,
              components.host == host,
              components.path.isEmpty,
              components.fragment == nil,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let items = components.queryItems,
              items.count == 2,
              items.count(where: { $0.name == "v" }) == 1,
              items.count(where: { $0.name == "payload" }) == 1,
              items.first(where: { $0.name == "v" })?.value
                  == String(MobilePairingPayload.currentVersion),
              let encodedPayload = items.first(where: { $0.name == "payload" })?.value,
              let payloadData = base64URLDecoded(encodedPayload)
        else {
            throw MobilePairingPayloadError.invalidCode
        }

        do {
            let payload = try JSONDecoder().decode(MobilePairingPayload.self, from: payloadData)
            try payload.validate(now: now)
            return payload
        } catch let error as MobilePairingPayloadError {
            throw error
        } catch {
            throw MobilePairingPayloadError.invalidPayload
        }
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        guard !value.isEmpty,
              value.range(
                  of: #"^[A-Za-z0-9_-]+$"#,
                  options: .regularExpression
              ) != nil else {
            return nil
        }
        let standard = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              base64URLEncoded(data) == value else {
            return nil
        }
        return data
    }
}
