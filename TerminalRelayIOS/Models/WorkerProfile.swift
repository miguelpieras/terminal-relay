import Foundation

struct WorkerProfile: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let host: String
    let port: Int
    let username: String
    let expectedHostKeyFingerprint: String

    var displayName: String {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedName.isEmpty ? host : normalizedName
    }

    static func validated(
        id: UUID = UUID(),
        name: String = "",
        host: String,
        port: Int,
        username: String,
        expectedHostKeyFingerprint: String
    ) throws -> WorkerProfile {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFingerprint = try HostKeyFingerprint.normalized(expectedHostKeyFingerprint)

        guard WorkerProfileValidator.isValidHost(normalizedHost) else {
            throw WorkerProfileValidationError.invalidHost
        }
        guard (1...65_535).contains(port) else {
            throw WorkerProfileValidationError.invalidPort
        }
        guard normalizedUsername.range(
            of: #"^[A-Za-z_][A-Za-z0-9._-]{0,63}$"#,
            options: .regularExpression
        ) != nil else {
            throw WorkerProfileValidationError.invalidUsername
        }

        return WorkerProfile(
            id: id,
            name: normalizedName,
            host: normalizedHost,
            port: port,
            username: normalizedUsername,
            expectedHostKeyFingerprint: normalizedFingerprint
        )
    }
}

enum WorkerProfileValidationError: LocalizedError, Equatable {
    case invalidHost
    case invalidPort
    case invalidUsername
    case invalidFingerprint

    var errorDescription: String? {
        switch self {
        case .invalidHost:
            "Enter a valid Tailscale hostname or IP address."
        case .invalidPort:
            "The SSH port must be between 1 and 65535."
        case .invalidUsername:
            "Enter a valid worker username."
        case .invalidFingerprint:
            "Enter the host key fingerprint in SHA256:… format."
        }
    }
}

enum HostKeyFingerprint {
    static func normalized(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("SHA256:") else {
            throw WorkerProfileValidationError.invalidFingerprint
        }

        let digest = String(trimmed.dropFirst("SHA256:".count)).replacingOccurrences(of: "=", with: "")
        guard !digest.isEmpty,
              digest.range(of: #"^[A-Za-z0-9+/]+$"#, options: .regularExpression) != nil,
              let decoded = Data(base64Encoded: digest + String(repeating: "=", count: (4 - digest.count % 4) % 4)),
              decoded.count == 32 else {
            throw WorkerProfileValidationError.invalidFingerprint
        }

        return "SHA256:\(digest)"
    }
}

private enum WorkerProfileValidator {
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }

        if host.contains(":") {
            return host.range(of: #"^[0-9A-Fa-f:.%]+$"#, options: .regularExpression) != nil
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }

        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first?.isASCII == true,
                  label.last?.isASCII == true else {
                return false
            }
            return label.range(
                of: #"^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$"#,
                options: .regularExpression
            ) != nil
        }
    }
}
