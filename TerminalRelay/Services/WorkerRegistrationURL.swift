import Foundation

enum WorkerRegistrationURLError: LocalizedError, Equatable {
    case urlTooLong
    case invalidRoute
    case invalidParameters
    case invalidIdentifier
    case invalidField(String)

    var errorDescription: String? {
        switch self {
        case .urlTooLong:
            "The worker registration link is too large."
        case .invalidRoute:
            "The worker registration link has an invalid route."
        case .invalidParameters:
            "The worker registration link has invalid parameters."
        case .invalidIdentifier:
            "The worker registration link has an invalid worker identifier."
        case .invalidField(let field):
            "The worker registration link has an invalid \(field) value."
        }
    }
}

struct WorkerRegistration: Equatable {
    let profile: ServerProfile
    let proof: String
}

enum WorkerRegistrationURL {
    static let scheme = "terminal-relay"
    static let action = "register-worker"
    static let workingDirectory = "/workspace"
    static let codexCommand = "/usr/local/bin/terminal-relay-session codex"
    static let claudeCommand = "/usr/local/bin/terminal-relay-session claude"

    private static let route = "\(scheme)://\(action)"
    private static let workerNamePrefix = "Terminal Relay Worker "
    private static let expectedFields: Set<String> = [
        "v", "id", "name", "host", "port", "username", "identity", "proof"
    ]
    private static let maximumURLBytes = 4_096
    private static let maximumQueryBytes = 3_072

    static func registration(from url: URL) throws -> WorkerRegistration {
        let absolute = url.absoluteString
        guard absolute.lengthOfBytes(using: .utf8) <= maximumURLBytes else {
            throw WorkerRegistrationURLError.urlTooLong
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme,
              components.host == action,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.percentEncodedPath.isEmpty,
              components.fragment == nil,
              let questionMark = absolute.firstIndex(of: "?"),
              String(absolute[..<questionMark]) == route else {
            throw WorkerRegistrationURLError.invalidRoute
        }

        let queryStart = absolute.index(after: questionMark)
        let query = String(absolute[queryStart...])
        guard query.lengthOfBytes(using: .utf8) <= maximumQueryBytes else {
            throw WorkerRegistrationURLError.urlTooLong
        }

        let fields = try parseFields(query)
        guard fields["v"] == "1" else {
            throw WorkerRegistrationURLError.invalidParameters
        }

        guard let identifierValue = fields["id"],
              identifierValue.utf8.count == 36,
              let identifier = UUID(uuidString: identifierValue),
              identifier.uuidString.caseInsensitiveCompare(identifierValue) == .orderedSame else {
            throw WorkerRegistrationURLError.invalidIdentifier
        }

        let name = try decodeField(fields["name"], named: "name", maximumBytes: 63)
        let host = try decodeField(fields["host"], named: "host", maximumBytes: 253)
        let username = try decodeField(fields["username"], named: "username", maximumBytes: 32)
        let identityFile = try decodeField(
            fields["identity"],
            named: "identity",
            maximumBytes: 1_024,
            allowsEmpty: true
        )

        guard isSafeName(name, identifier: identifier) else {
            throw WorkerRegistrationURLError.invalidField("name")
        }
        guard isSafeHost(host) else {
            throw WorkerRegistrationURLError.invalidField("host")
        }
        guard username == "terminal-relay" else {
            throw WorkerRegistrationURLError.invalidField("username")
        }
        guard isSafeIdentityFile(identityFile) else {
            throw WorkerRegistrationURLError.invalidField("identity")
        }
        guard let portValue = fields["port"],
              !portValue.isEmpty,
              portValue.utf8.allSatisfy(isASCIIDigit),
              let port = Int(portValue),
              (1...65_535).contains(port),
              String(port) == portValue else {
            throw WorkerRegistrationURLError.invalidField("port")
        }
        guard let proof = fields["proof"],
              proof.utf8.count == 64,
              proof.utf8.allSatisfy(isLowercaseHexDigit) else {
            throw WorkerRegistrationURLError.invalidField("proof")
        }

        return WorkerRegistration(
            profile: ServerProfile(
                id: identifier,
                name: name,
                host: host,
                port: port,
                username: username,
                identityFile: identityFile,
                workingDirectory: workingDirectory,
                codexAccountLabel: "\(name) Codex",
                claudeAccountLabel: "\(name) Claude",
                codexCommand: codexCommand,
                claudeCommand: claudeCommand
            ),
            proof: proof
        )
    }

    private static func parseFields(_ query: String) throws -> [String: String] {
        let pairs = query.split(separator: "&", omittingEmptySubsequences: false)
        guard pairs.count == expectedFields.count else {
            throw WorkerRegistrationURLError.invalidParameters
        }

        var result: [String: String] = [:]
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw WorkerRegistrationURLError.invalidParameters
            }

            let key = String(parts[0])
            let value = String(parts[1])
            guard expectedFields.contains(key), result[key] == nil else {
                throw WorkerRegistrationURLError.invalidParameters
            }
            result[key] = value
        }

        guard Set(result.keys) == expectedFields else {
            throw WorkerRegistrationURLError.invalidParameters
        }
        return result
    }

    private static func decodeField(
        _ encodedValue: String?,
        named field: String,
        maximumBytes: Int,
        allowsEmpty: Bool = false
    ) throws -> String {
        guard let encodedValue,
              encodedValue.utf8.count <= ((maximumBytes + 2) / 3) * 4,
              encodedValue.utf8.allSatisfy(isBase64URLByte),
              allowsEmpty || !encodedValue.isEmpty,
              encodedValue.utf8.count % 4 != 1 else {
            throw WorkerRegistrationURLError.invalidField(field)
        }

        var base64 = encodedValue
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard let data = Data(base64Encoded: base64),
              data.count <= maximumBytes,
              let value = String(data: data, encoding: .utf8),
              canonicalBase64URL(data) == encodedValue,
              allowsEmpty || !value.isEmpty else {
            throw WorkerRegistrationURLError.invalidField(field)
        }
        return value
    }

    private static func canonicalBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isSafeName(_ value: String, identifier: UUID) -> Bool {
        let shortIdentifier = identifier.uuidString.prefix(8).lowercased()
        if value == "\(workerNamePrefix)\(shortIdentifier)" {
            return true
        }

        let suffix = value.dropFirst(workerNamePrefix.count)
        return value.hasPrefix(workerNamePrefix)
            && (1...6).contains(suffix.utf8.count)
            && suffix.first != "0"
            && suffix.utf8.allSatisfy(isASCIIDigit)
    }

    private static func isSafeHost(_ value: String) -> Bool {
        isSafeASCIIIdentifier(value, allowedPunctuation: [45, 46, 95])
            && !value.contains("..")
    }

    private static func isSafeASCIIIdentifier(
        _ value: String,
        allowedPunctuation: Set<UInt8>
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first,
              let last = bytes.last,
              isASCIIAlphaNumeric(first),
              isASCIIAlphaNumeric(last) else {
            return false
        }
        return bytes.allSatisfy { isASCIIAlphaNumeric($0) || allowedPunctuation.contains($0) }
    }

    private static func isSafeIdentityFile(_ value: String) -> Bool {
        value.isEmpty
            || (value.hasPrefix("/")
                && value != "/"
                && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isBase64URLByte(_ byte: UInt8) -> Bool {
        isASCIIAlphaNumeric(byte) || byte == 45 || byte == 95
    }

    private static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
        isASCIIDigit(byte) || (97...102).contains(byte)
    }
}
