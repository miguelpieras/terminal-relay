import CryptoKit
import Foundation

struct MobilePairingInvitation: Identifiable {
    let id: String
    let worker: ServerProfile
    let code: String
    let expiresAt: Date
}

enum MobilePairingServiceError: LocalizedError {
    case missingUsername
    case invalidHostFingerprint
    case workerRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingUsername:
            "Set an explicit SSH username for this worker before pairing a mobile device."
        case .invalidHostFingerprint:
            "The worker did not return a valid ED25519 host-key fingerprint."
        case .workerRejected(let message):
            message.isEmpty
                ? "The worker could not create a mobile pairing invitation."
                : message
        }
    }
}

enum MobilePairingService {
    static let invitationLifetime: TimeInterval = 10 * 60
    static let responseMarker = "__TERMINAL_RELAY_MOBILE_PAIRING_V1__"
    static let enrollmentMarker = "__TERMINAL_RELAY_DEVICE_ENROLLMENT_V1__"

    static func prepare(worker: ServerProfile, now: Date = Date()) async throws
        -> MobilePairingInvitation {
        let username = worker.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw MobilePairingServiceError.missingUsername
        }

        let temporaryKey = Curve25519.Signing.PrivateKey()
        let token = UUID().uuidString.lowercased()
        let expiresAt = now.addingTimeInterval(invitationLifetime)
        let expiresAtSeconds = Int64(expiresAt.timeIntervalSince1970)
        let publicKey = openSSHPublicKey(
            temporaryKey.publicKey.rawRepresentation,
            comment: "terminal-relay-pairing:\(token)"
        )
        let entry = authorizedKeyEntry(
            publicKey: publicKey,
            token: token,
            expiresAt: expiresAtSeconds
        )

        let output = try await run(
            script: pairingSetupScript(authorizedKeyEntry: entry),
            on: worker
        )
        let fingerprint = try parseFingerprint(output)
        let payload = MobilePairingPayload(
            version: MobilePairingPayload.currentVersion,
            workerName: String(worker.displayName.prefix(80)),
            host: worker.host.trimmingCharacters(in: .whitespacesAndNewlines),
            port: worker.port,
            username: username,
            hostKeyFingerprint: fingerprint,
            temporaryPrivateKey: temporaryKey.rawRepresentation.base64EncodedString(),
            pairingToken: token,
            expiresAt: expiresAtSeconds
        )

        do {
            return MobilePairingInvitation(
                id: token,
                worker: worker,
                code: try MobilePairingPayloadCodec.encode(payload, now: now),
                expiresAt: expiresAt
            )
        } catch {
            try? await revoke(token: token, on: worker)
            throw error
        }
    }

    static func revoke(token: String, on worker: ServerProfile) async throws {
        guard let parsedToken = UUID(uuidString: token),
              parsedToken.uuidString.lowercased() == token else {
            return
        }
        _ = try await run(script: pairingRevocationScript(token: token), on: worker)
    }

    static func authorizedKeyEntry(
        publicKey: String,
        token: String,
        expiresAt: Int64
    ) -> String {
        let script = enrollmentScript(token: token, expiresAt: expiresAt)
        let encodedScript = Data(script.utf8).base64EncodedString()
        let forcedCommand =
            "/bin/sh -c 'printf %s \(encodedScript) | /usr/bin/base64 -d | /bin/sh'"
        return #"restrict,command="\#(forcedCommand)" \#(publicKey)"#
    }

    static func enrollmentScript(token: String, expiresAt: Int64) -> String {
        """
        set -eu
        token='\(token)'
        expires_at='\(expiresAt)'
        marker="terminal-relay-pairing:$token"
        ssh_directory="$HOME/.ssh"
        authorized_keys="$ssh_directory/authorized_keys"
        lock_file="$ssh_directory/.terminal-relay-pairing.lock"

        if [ "$(/bin/date +%s)" -gt "$expires_at" ]; then
            echo "This Terminal Relay pairing invitation has expired." >&2
            exit 75
        fi

        original="${SSH_ORIGINAL_COMMAND:-}"
        prefix='terminal-relay-enroll-device '
        case "$original" in
            "$prefix"*) encoded="${original#"$prefix"}" ;;
            *) echo "This SSH key can only enroll a Terminal Relay device." >&2; exit 64 ;;
        esac
        case "$encoded" in
            ''|*[!A-Za-z0-9+/=]*)
                echo "The Terminal Relay device key is invalid." >&2
                exit 64
                ;;
        esac

        device_key="$(printf '%s' "$encoded" | /usr/bin/base64 -d 2>/dev/null)" || {
            echo "The Terminal Relay device key is invalid." >&2
            exit 64
        }
        device_entry="restrict,command=\\"/usr/local/bin/terminal-relay-mobile-gateway\\" $device_key"
        printf '%s\n' "$device_key" | /usr/bin/awk '
            NF == 3 && $1 == "ssh-ed25519" \
                && $2 ~ /^[A-Za-z0-9+\\/=]+$/ \
                && $3 == "terminal-relay-ios" {
                valid += 1
            }
            END {
                exit !(NR == 1 && valid == 1)
            }
        ' || {
            echo "The Terminal Relay device key is invalid." >&2
            exit 64
        }

        [ -d "$ssh_directory" ] && [ ! -L "$ssh_directory" ] \
            && [ -f "$authorized_keys" ] && [ ! -L "$authorized_keys" ] || {
            echo "The worker SSH authorization file is unsafe." >&2
            exit 78
        }
        /usr/bin/touch "$lock_file"
        /bin/chmod 600 "$lock_file"
        (
            /usr/bin/flock -x 9
            /usr/bin/awk -v marker="$marker" \
                '$NF == marker { found = 1 } END { exit !found }' \
                "$authorized_keys" || {
                echo "This Terminal Relay pairing invitation was already used." >&2
                exit 76
            }
            temporary_file="$(/usr/bin/mktemp "$ssh_directory/.authorized_keys.XXXXXX")"
            trap '/bin/rm -f -- "$temporary_file"' EXIT
            /usr/bin/awk -v marker="$marker" '$NF != marker { print }' \
                "$authorized_keys" > "$temporary_file"
            if ! /usr/bin/grep -Fqx -- "$device_entry" "$temporary_file"; then
                printf '%s\n' "$device_entry" >> "$temporary_file"
            fi
            /bin/chmod 600 "$temporary_file"
            /bin/mv -f -- "$temporary_file" "$authorized_keys"
            trap - EXIT
        ) 9>"$lock_file"

        printf '%s\n' '\(enrollmentMarker)'
        printf '%s\n' 'paired'
        """
    }

    static func pairingSetupScript(authorizedKeyEntry: String) -> String {
        let quotedEntry = shellQuote(authorizedKeyEntry)
        return """
        set -eu
        umask 077
        ssh_directory="$HOME/.ssh"
        authorized_keys="$ssh_directory/authorized_keys"
        lock_file="$ssh_directory/.terminal-relay-pairing.lock"
        pairing_entry=\(quotedEntry)

        if [ -e "$ssh_directory" ] || [ -L "$ssh_directory" ]; then
            [ -d "$ssh_directory" ] && [ ! -L "$ssh_directory" ] || {
                echo "The worker SSH directory is unsafe." >&2
                exit 78
            }
        else
            /bin/mkdir -p "$ssh_directory"
        fi
        /bin/chmod 700 "$ssh_directory"

        if [ -e "$authorized_keys" ] || [ -L "$authorized_keys" ]; then
            [ -f "$authorized_keys" ] && [ ! -L "$authorized_keys" ] || {
                echo "The worker SSH authorization file is unsafe." >&2
                exit 78
            }
        else
            /usr/bin/touch "$authorized_keys"
        fi
        /bin/chmod 600 "$authorized_keys"
        /usr/bin/touch "$lock_file"
        /bin/chmod 600 "$lock_file"

        (
            /usr/bin/flock -x 9
            temporary_file="$(/usr/bin/mktemp "$ssh_directory/.authorized_keys.XXXXXX")"
            trap '/bin/rm -f -- "$temporary_file"' EXIT
            /usr/bin/awk '$NF !~ /^terminal-relay-pairing:/ { print }' \
                "$authorized_keys" > "$temporary_file"
            printf '%s\n' "$pairing_entry" >> "$temporary_file"
            /bin/chmod 600 "$temporary_file"
            /bin/mv -f -- "$temporary_file" "$authorized_keys"
            trap - EXIT
        ) 9>"$lock_file"

        fingerprint="$(/usr/bin/ssh-keygen -E sha256 -lf \
            /etc/ssh/ssh_host_ed25519_key.pub | /usr/bin/awk 'NR == 1 { print $2 }')"
        case "$fingerprint" in
            SHA256:*) ;;
            *) echo "The worker ED25519 host key is unavailable." >&2; exit 69 ;;
        esac
        printf '%s\n' '\(responseMarker)'
        printf 'fingerprint|%s\n' "$fingerprint"
        """
    }

    static func pairingRevocationScript(token: String) -> String {
        """
        set -eu
        marker='terminal-relay-pairing:\(token)'
        ssh_directory="$HOME/.ssh"
        authorized_keys="$ssh_directory/authorized_keys"
        lock_file="$ssh_directory/.terminal-relay-pairing.lock"
        [ -d "$ssh_directory" ] && [ ! -L "$ssh_directory" ] \
            && [ -f "$authorized_keys" ] && [ ! -L "$authorized_keys" ] || exit 0
        /usr/bin/touch "$lock_file"
        /bin/chmod 600 "$lock_file"
        (
            /usr/bin/flock -x 9
            temporary_file="$(/usr/bin/mktemp "$ssh_directory/.authorized_keys.XXXXXX")"
            trap '/bin/rm -f -- "$temporary_file"' EXIT
            /usr/bin/awk -v marker="$marker" '$NF != marker { print }' \
                "$authorized_keys" > "$temporary_file"
            /bin/chmod 600 "$temporary_file"
            /bin/mv -f -- "$temporary_file" "$authorized_keys"
            trap - EXIT
        ) 9>"$lock_file"
        """
    }

    private static func openSSHPublicKey(_ key: Data, comment: String) -> String {
        var wireKey = Data()
        appendSSHString(Data("ssh-ed25519".utf8), to: &wireKey)
        appendSSHString(key, to: &wireKey)
        return "ssh-ed25519 \(wireKey.base64EncodedString()) \(comment)"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static func appendSSHString(_ value: Data, to data: inout Data) {
        var length = UInt32(value.count).bigEndian
        withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
        data.append(value)
    }

    private static func parseFingerprint(_ output: Data) throws -> String {
        let lines = String(decoding: output, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard let markerIndex = lines.firstIndex(of: responseMarker),
              markerIndex + 1 < lines.count,
              lines[markerIndex + 1].hasPrefix("fingerprint|") else {
            throw MobilePairingServiceError.invalidHostFingerprint
        }
        let fingerprint = String(lines[markerIndex + 1].dropFirst("fingerprint|".count))
        let digest = String(fingerprint.dropFirst("SHA256:".count))
        let padding = String(repeating: "=", count: (4 - digest.count % 4) % 4)
        guard fingerprint.hasPrefix("SHA256:"),
              digest.range(
                  of: #"^[A-Za-z0-9+/]+$"#,
                  options: .regularExpression
              ) != nil,
              Data(base64Encoded: digest + padding)?.count == 32 else {
            throw MobilePairingServiceError.invalidHostFingerprint
        }
        return fingerprint
    }

    private static func run(script: String, on worker: ServerProfile) async throws -> Data {
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: GitHubProjectService.sshArguments(for: worker, script: script)
        )
        guard result.exitCode == 0 else {
            let standardError = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MobilePairingServiceError.workerRejected(standardError)
        }
        return result.standardOutput
    }
}
