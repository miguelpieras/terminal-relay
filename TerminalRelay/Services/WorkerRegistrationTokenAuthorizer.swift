import Darwin
import Foundation

enum WorkerRegistrationAuthorizationError: LocalizedError, Equatable {
    case tokenMissing
    case tokenUnsafe
    case proofMismatch
    case tokenCouldNotBeConsumed

    var errorDescription: String? {
        switch self {
        case .tokenMissing:
            "The worker registration handoff is missing. Run the bootstrap command again."
        case .tokenUnsafe:
            "The worker registration handoff file has unsafe ownership, permissions, or type."
        case .proofMismatch:
            "The worker registration handoff does not match this link."
        case .tokenCouldNotBeConsumed:
            "The worker registration handoff could not be consumed. Run the bootstrap command again."
        }
    }
}

struct WorkerRegistrationTokenAuthorizer {
    let registrationsDirectory: URL

    init(
        registrationsDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Terminal Relay/Worker Registrations", isDirectory: true)
    ) {
        self.registrationsDirectory = registrationsDirectory
    }

    func authorize(_ registration: WorkerRegistration) throws {
        let tokenURL = registrationsDirectory.appendingPathComponent(
            "\(registration.profile.id.uuidString.lowercased()).token",
            isDirectory: false
        )
        let tokenPath = tokenURL.path
        let descriptor = tokenPath.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }

        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw WorkerRegistrationAuthorizationError.tokenMissing
            }
            throw WorkerRegistrationAuthorizationError.tokenUnsafe
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == Darwin.getuid(),
              metadata.st_nlink == 1,
              (metadata.st_mode & 0o077) == 0 else {
            throw WorkerRegistrationAuthorizationError.tokenUnsafe
        }

        let expectedToken = Data("\(registration.proof)\n".utf8)
        guard metadata.st_size == expectedToken.count else {
            throw WorkerRegistrationAuthorizationError.proofMismatch
        }

        let actualToken = try read(descriptor: descriptor, maximumBytes: expectedToken.count + 1)
        guard actualToken == expectedToken else {
            throw WorkerRegistrationAuthorizationError.proofMismatch
        }

        var pathMetadata = stat()
        guard tokenPath.withCString({ Darwin.lstat($0, &pathMetadata) }) == 0,
              (pathMetadata.st_mode & S_IFMT) == S_IFREG,
              pathMetadata.st_dev == metadata.st_dev,
              pathMetadata.st_ino == metadata.st_ino else {
            throw WorkerRegistrationAuthorizationError.tokenUnsafe
        }

        guard tokenPath.withCString({ Darwin.unlink($0) }) == 0 else {
            throw WorkerRegistrationAuthorizationError.tokenCouldNotBeConsumed
        }
    }

    private func read(descriptor: Int32, maximumBytes: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: maximumBytes)
        var offset = 0

        while offset < maximumBytes {
            let remaining = maximumBytes - offset
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    remaining
                )
            }

            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw WorkerRegistrationAuthorizationError.tokenUnsafe
            }
            offset += count
        }

        return Data(bytes.prefix(offset))
    }
}
