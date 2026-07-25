import AppKit
import XCTest
@testable import TerminalRelay

final class WorkerRegistrationURLTests: XCTestCase {
    func testValidURLBuildsOnlyTheFixedWorkerProfile() throws {
        let identifier = UUID(uuidString: "8D5A22C7-5750-4237-B99B-216F16867C16")!
        let url = makeURL(
            id: identifier,
            name: "Terminal Relay Worker 8d5a22c7",
            host: "worker.example.com",
            port: "2222",
            identity: "/Users/developer/.ssh/terminal-relay-operator"
        )

        let registration = try WorkerRegistrationURL.registration(from: url)
        let profile = registration.profile

        XCTAssertEqual(registration.proof, String(repeating: "a", count: 64))
        XCTAssertEqual(profile.id, identifier)
        XCTAssertEqual(profile.name, "Terminal Relay Worker 8d5a22c7")
        XCTAssertEqual(profile.host, "worker.example.com")
        XCTAssertEqual(profile.port, 2_222)
        XCTAssertEqual(profile.username, "terminal-relay")
        XCTAssertEqual(profile.identityFile, "/Users/developer/.ssh/terminal-relay-operator")
        XCTAssertEqual(profile.workingDirectory, "/workspace")
        XCTAssertEqual(profile.codexAccountLabel, "Terminal Relay Worker 8d5a22c7 Codex")
        XCTAssertEqual(profile.claudeAccountLabel, "Terminal Relay Worker 8d5a22c7 Claude")
        XCTAssertEqual(profile.codexCommand, "/usr/local/bin/terminal-relay-session codex")
        XCTAssertEqual(profile.claudeCommand, "/usr/local/bin/terminal-relay-session claude")
    }

    func testAcceptsAPersistedNumericFriendlyRoleWithoutChangingStableIdentity() throws {
        let identifier = UUID(uuidString: "8D5A22C7-5750-4237-B99B-216F16867C16")!
        let registration = try WorkerRegistrationURL.registration(
            from: makeURL(id: identifier, name: "Terminal Relay Worker 2")
        )

        XCTAssertEqual(registration.profile.id, identifier)
        XCTAssertEqual(registration.profile.name, "Terminal Relay Worker 2")
    }

    func testRejectsInvalidRoutesVersionsAndParameterShapes() {
        let valid = makeURL().absoluteString
        let cases = [
            valid.replacingOccurrences(of: "terminal-relay://", with: "https://"),
            valid.replacingOccurrences(of: "register-worker?", with: "other-action?"),
            valid.replacingOccurrences(of: "register-worker?", with: "register-worker/?"),
            valid + "#fragment",
            valid.replacingOccurrences(of: "v=1", with: "v=2"),
            valid + "&name=duplicate",
            valid.replacingOccurrences(of: "&identity=", with: ""),
            valid.replacingOccurrences(of: "identity=", with: "unexpected="),
            valid.replacingOccurrences(
                of: "&proof=\(String(repeating: "a", count: 64))",
                with: ""
            )
        ]

        for value in cases {
            XCTAssertThrowsError(try WorkerRegistrationURL.registration(from: URL(string: value)!))
        }
    }

    func testRejectsMalformedOrNoncanonicalBase64URLFields() {
        let canonicalName = encoded("Terminal Relay Worker 8d5a22c7")
        let canonicalUsername = encoded("terminal-relay")
        let cases = [
            makeURL(rawOverrides: ["name": canonicalName + "="]),
            makeURL(rawOverrides: ["name": "%56" + String(canonicalName.dropFirst())]),
            makeURL(rawOverrides: ["name": "A"]),
            makeURL(rawOverrides: ["username": noncanonicalVariant(of: canonicalUsername)]),
            makeURL(rawOverrides: ["host": "_w"])
        ]

        for url in cases {
            XCTAssertThrowsError(try WorkerRegistrationURL.registration(from: url))
        }
    }

    func testRejectsUnsafeDecodedFieldsIdentifiersAndPorts() {
        let cases = [
            makeURL(name: "worker\nname"),
            makeURL(name: "terminal-relay-worker-a13f09bc"),
            makeURL(name: "Terminal Relay Worker 8D5A22C7"),
            makeURL(name: "Terminal Relay Worker 8d5a"),
            makeURL(name: "Terminal Relay Worker a13f09bc"),
            makeURL(name: "Terminal Relay Worker 0"),
            makeURL(name: "Terminal Relay Worker 000002"),
            makeURL(name: "Terminal Relay Worker 1234567"),
            makeURL(host: "worker@example.com"),
            makeURL(host: "-oProxyCommand=bad"),
            makeURL(username: "root"),
            makeURL(identity: "relative/key"),
            makeURL(identity: "/tmp/key\nother"),
            makeURL(port: "0"),
            makeURL(port: "65536"),
            makeURL(port: "022"),
            makeURL(port: "22;command"),
            makeURL(rawOverrides: ["id": "not-a-uuid"]),
            makeURL(proof: String(repeating: "A", count: 64)),
            makeURL(proof: String(repeating: "a", count: 63)),
            makeURL(proof: String(repeating: "g", count: 64))
        ]

        for url in cases {
            XCTAssertThrowsError(try WorkerRegistrationURL.registration(from: url))
        }
    }

    func testRejectsOversizedURLAndDecodedField() {
        let oversizedIdentity = String(repeating: "a", count: 1_025)
        XCTAssertThrowsError(
            try WorkerRegistrationURL.registration(from: makeURL(identity: "/" + oversizedIdentity))
        )

        let oversizedURL = makeURL(rawOverrides: ["name": String(repeating: "A", count: 5_000)])
        XCTAssertThrowsError(try WorkerRegistrationURL.registration(from: oversizedURL))
    }

    @MainActor
    func testApplicationDelegateQueuesColdURLAndProcessesWarmURLImmediately() {
        let suiteName = "TerminalRelayTests.WorkerRegistration.Delegate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let coldID = UUID()
        let warmID = UUID()
        let serverStore = ServerStore(defaults: defaults, initialServers: [])
        let projectStore = ProjectStore(defaults: defaults, servers: [], initialProjects: [])
        let delegate = TerminalRelayApplicationDelegate(registrationAuthorization: { _ in })
        var errors: [String] = []

        delegate.application(NSApplication.shared, open: [makeURL(id: coldID)])
        XCTAssertTrue(serverStore.servers.isEmpty)

        delegate.attach(serverStore: serverStore, projectStore: projectStore) { message in
            if let message {
                errors.append(message)
            }
        }
        XCTAssertNotNil(serverStore.server(id: coldID))

        delegate.application(
            NSApplication.shared,
            open: [makeURL(id: warmID)]
        )
        XCTAssertNotNil(serverStore.server(id: warmID))
        XCTAssertEqual(serverStore.servers.count, 2)

        let project = ProjectProfile(
            serverID: warmID,
            repositoryOwner: "example-user",
            repositoryName: "terminal-relay"
        )
        XCTAssertTrue(projectStore.save(project))
        XCTAssertTrue(errors.isEmpty)
    }

    @MainActor
    func testApplicationDelegateSurfacesFailedAuthorizationWithoutMutation() {
        let suiteName = "TerminalRelayTests.WorkerRegistration.Error.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let existing = ServerProfile(name: "Existing", host: "existing")
        let serverStore = ServerStore(defaults: defaults, initialServers: [existing])
        let projectStore = ProjectStore(defaults: defaults, servers: [existing], initialProjects: [])
        let delegate = TerminalRelayApplicationDelegate(registrationAuthorization: { _ in
            throw WorkerRegistrationAuthorizationError.tokenMissing
        })
        var surfacedError: String?
        delegate.attach(serverStore: serverStore, projectStore: projectStore) { surfacedError = $0 }

        delegate.application(NSApplication.shared, open: [makeURL()])

        XCTAssertEqual(serverStore.servers, [existing])
        XCTAssertNotNil(delegate.registrationError)
        XCTAssertNotNil(surfacedError)
    }

    func testTokenAuthorizerConsumesAValidFileOnlyOnce() throws {
        let directory = try makeTemporaryRegistrationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registration = try WorkerRegistrationURL.registration(from: makeURL())
        let tokenURL = tokenURL(for: registration, in: directory)
        try writeToken("\(registration.proof)\n", to: tokenURL, permissions: 0o600)
        let authorizer = WorkerRegistrationTokenAuthorizer(registrationsDirectory: directory)

        try authorizer.authorize(registration)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenURL.path))
        XCTAssertThrowsError(try authorizer.authorize(registration)) { error in
            XCTAssertEqual(error as? WorkerRegistrationAuthorizationError, .tokenMissing)
        }
    }

    func testTokenAuthorizerRejectsMissingMismatchedAndWrongModeFiles() throws {
        let directory = try makeTemporaryRegistrationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registration = try WorkerRegistrationURL.registration(from: makeURL())
        let tokenURL = tokenURL(for: registration, in: directory)
        let authorizer = WorkerRegistrationTokenAuthorizer(registrationsDirectory: directory)

        XCTAssertThrowsError(try authorizer.authorize(registration)) { error in
            XCTAssertEqual(error as? WorkerRegistrationAuthorizationError, .tokenMissing)
        }

        try writeToken("\(String(repeating: "b", count: 64))\n", to: tokenURL, permissions: 0o600)
        XCTAssertThrowsError(try authorizer.authorize(registration)) { error in
            XCTAssertEqual(error as? WorkerRegistrationAuthorizationError, .proofMismatch)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenURL.path))

        try writeToken("\(registration.proof)\n", to: tokenURL, permissions: 0o644)
        XCTAssertThrowsError(try authorizer.authorize(registration)) { error in
            XCTAssertEqual(error as? WorkerRegistrationAuthorizationError, .tokenUnsafe)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenURL.path))
    }

    func testTokenAuthorizerRejectsSymbolicLink() throws {
        let directory = try makeTemporaryRegistrationDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let registration = try WorkerRegistrationURL.registration(from: makeURL())
        let tokenURL = tokenURL(for: registration, in: directory)
        let targetURL = directory.appendingPathComponent("target.token")
        try writeToken("\(registration.proof)\n", to: targetURL, permissions: 0o600)
        try FileManager.default.createSymbolicLink(at: tokenURL, withDestinationURL: targetURL)

        let authorizer = WorkerRegistrationTokenAuthorizer(registrationsDirectory: directory)
        XCTAssertThrowsError(try authorizer.authorize(registration)) { error in
            XCTAssertEqual(error as? WorkerRegistrationAuthorizationError, .tokenUnsafe)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: targetURL.path))
    }

    private func makeURL(
        id: UUID = UUID(uuidString: "8D5A22C7-5750-4237-B99B-216F16867C16")!,
        name: String? = nil,
        host: String = "worker.example.com",
        port: String = "22",
        username: String = "terminal-relay",
        identity: String = "",
        proof: String = String(repeating: "a", count: 64),
        rawOverrides: [String: String] = [:]
    ) -> URL {
        let resolvedName = name
            ?? "Terminal Relay Worker \(id.uuidString.prefix(8).lowercased())"
        var fields = [
            "v": "1",
            "id": id.uuidString,
            "name": encoded(resolvedName),
            "host": encoded(host),
            "port": port,
            "username": encoded(username),
            "identity": encoded(identity),
            "proof": proof
        ]
        fields.merge(rawOverrides) { _, replacement in replacement }

        let query = ["v", "id", "name", "host", "port", "username", "identity", "proof"]
            .map { "\($0)=\(fields[$0]!)" }
            .joined(separator: "&")
        return URL(string: "terminal-relay://register-worker?\(query)")!
    }

    private func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func noncanonicalVariant(of value: String) -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var characters = Array(value)
        let finalIndex = alphabet.firstIndex(of: characters.removeLast())!
        characters.append(alphabet[finalIndex + 1])
        return String(characters)
    }

    private func makeTemporaryRegistrationDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TerminalRelayRegistrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func tokenURL(for registration: WorkerRegistration, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(registration.profile.id.uuidString.lowercased()).token"
        )
    }

    private func writeToken(_ value: String, to url: URL, permissions: Int) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: url.path
        )
    }
}
