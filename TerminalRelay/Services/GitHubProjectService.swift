import Combine
import Foundation

struct GitHubRepository: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let nameWithOwner: String
    let isPrivate: Bool
    let isArchived: Bool
}

enum GitHubProjectError: LocalizedError, Equatable {
    case invalidRepositoryName
    case ghNotInstalled
    case invalidGitHubResponse
    case commandFailed(tool: String, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryName:
            return "Enter a project name that can be used as a GitHub repository name."
        case .ghNotInstalled:
            return "GitHub CLI is not installed. Install and sign in to gh on this Mac first."
        case .invalidGitHubResponse:
            return "GitHub returned an unexpected response."
        case let .commandFailed(tool, message):
            return message.isEmpty ? "\(tool) failed." : message
        }
    }
}

@MainActor
final class GitHubProjectService: ObservableObject {
    static let repositoryOwner = ProjectProfile.defaultRepositoryOwner

    @Published private(set) var repositories: [GitHubRepository] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    func refreshRepositories() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            repositories = try await fetchRepositories()
        } catch {
            errorMessage = Self.message(for: error)
        }
    }

    @discardableResult
    func prepare(
        repositoryName: String,
        create: Bool,
        on worker: ServerProfile
    ) async throws -> GitHubRepository {
        let preparedName = create
            ? Self.normalizedRepositoryName(from: repositoryName)
            : repositoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeRepositoryName(preparedName) else {
            throw GitHubProjectError.invalidRepositoryName
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            if create {
                _ = try await runGH(arguments: Self.createRepositoryArguments(name: preparedName))
            }

            let repositoryData = try await runGH(
                arguments: Self.viewRepositoryArguments(name: preparedName)
            )
            let repository = try Self.parseRepository(repositoryData)
            guard repository.nameWithOwner.caseInsensitiveCompare(
                "\(Self.repositoryOwner)/\(repository.name)"
            ) == .orderedSame,
                Self.isSafeRepositoryName(repository.name),
                !repository.isArchived else {
                throw GitHubProjectError.invalidGitHubResponse
            }

            let publicKey = try await ensureWorkerKey(
                repositoryName: repository.name,
                worker: worker
            )
            try await ensureWritableDeployKey(
                publicKey: publicKey,
                repository: repository,
                worker: worker
            )
            try await provisionCheckout(repository: repository, worker: worker)

            if let existingIndex = repositories.firstIndex(where: {
                $0.nameWithOwner.caseInsensitiveCompare(repository.nameWithOwner) == .orderedSame
            }) {
                repositories[existingIndex] = repository
            } else {
                repositories.append(repository)
                repositories.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }

            return repository
        } catch {
            errorMessage = Self.message(for: error)
            throw error
        }
    }

    static func normalizedRepositoryName(from value: String) -> String {
        ProjectProfile.normalizedRepositoryName(from: value)
    }

    static func isSafeRepositoryName(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.count <= 100
            && value.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
    }

    static func listRepositoryArguments() -> [String] {
        [
            "repo", "list", repositoryOwner,
            "--limit", "1000",
            "--no-archived",
            "--json", "id,name,nameWithOwner,isPrivate,isArchived"
        ]
    }

    static func createRepositoryArguments(name: String) -> [String] {
        [
            "repo", "create", "\(repositoryOwner)/\(name)",
            "--private",
            "--add-readme"
        ]
    }

    static func viewRepositoryArguments(name: String) -> [String] {
        [
            "repo", "view", "\(repositoryOwner)/\(name)",
            "--json", "id,name,nameWithOwner,isPrivate,isArchived"
        ]
    }

    static func deployKeyListArguments(repository: GitHubRepository) -> [String] {
        [
            "repo", "deploy-key", "list",
            "--repo", repository.nameWithOwner,
            "--json", "id,key,readOnly,title"
        ]
    }

    static func parseRepositories(_ data: Data) throws -> [GitHubRepository] {
        do {
            return try JSONDecoder().decode([GitHubRepository].self, from: data)
        } catch {
            throw GitHubProjectError.invalidGitHubResponse
        }
    }

    static func parseRepository(_ data: Data) throws -> GitHubRepository {
        do {
            return try JSONDecoder().decode(GitHubRepository.self, from: data)
        } catch {
            throw GitHubProjectError.invalidGitHubResponse
        }
    }

    static func parseDeployKeys(_ data: Data) throws -> [GitHubDeployKey] {
        if String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            return []
        }

        do {
            return try JSONDecoder().decode([GitHubDeployKey].self, from: data)
        } catch {
            throw GitHubProjectError.invalidGitHubResponse
        }
    }

    static func parseDeployPublicKey(_ output: String) throws -> String {
        let marker = "__TERMINAL_RELAY_DEPLOY_KEY__"
        guard let markedLine = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { $0.hasPrefix(marker) }) else {
            throw GitHubProjectError.commandFailed(
                tool: "SSH",
                message: "The worker did not return its deploy key."
            )
        }

        let publicKey = String(markedLine.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard publicKeyIdentity(publicKey) != nil else {
            throw GitHubProjectError.commandFailed(
                tool: "SSH",
                message: "The worker returned an invalid deploy key."
            )
        }
        return publicKey
    }

    static func workerKeyScript(repositoryName: String) -> String {
        let keyName = "\(repositoryOwner)-\(repositoryName).ed25519"
        return """
        set -eu
        key_dir="$HOME/.ssh/terminal-relay"
        key_name=\(shellQuote(keyName))
        key_file="$key_dir/$key_name"
        mkdir -p "$key_dir"
        chmod 700 "$key_dir"
        if [ ! -f "$key_file" ]; then
          if [ -e "$key_file.pub" ]; then
            printf '%s\n' 'A deploy-key public file exists without its private key.' >&2
            exit 41
          fi
          ssh-keygen -q -t ed25519 -N '' -C \(shellQuote("terminal-relay:\(repositoryOwner)/\(repositoryName)")) -f "$key_file"
        fi
        if [ ! -f "$key_file.pub" ]; then
          ssh-keygen -y -P '' -f "$key_file" > "$key_file.pub"
        fi
        chmod 600 "$key_file"
        chmod 644 "$key_file.pub"
        printf '__TERMINAL_RELAY_DEPLOY_KEY__%s\n' "$(cat "$key_file.pub")"
        """
    }

    static func checkoutProvisionScript(repositoryName: String) -> String {
        let keyName = "\(repositoryOwner)-\(repositoryName).ed25519"
        return """
        set -eu
        owner=\(shellQuote(repositoryOwner))
        repo=\(shellQuote(repositoryName))
        destination="/workspace/$repo"
        expected_slug="$owner/$repo"
        ssh_url="git@github.com:$expected_slug.git"
        https_url="https://github.com/$expected_slug.git"
        key_name=\(shellQuote(keyName))
        ssh_command="ssh -i ~/.ssh/terminal-relay/$key_name -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"

        if [ -e "$destination" ] && [ ! -d "$destination" ]; then
          printf 'Project path %s exists and is not a directory.\n' "$destination" >&2
          exit 42
        fi

        if [ -d "$destination" ] && git -C "$destination" rev-parse --git-dir >/dev/null 2>&1; then
          origin="$(git -C "$destination" remote get-url origin 2>/dev/null || true)"
          case "$origin" in
            "$ssh_url"|"${ssh_url%.git}"|"$https_url"|"${https_url%.git}"|"ssh://git@github.com/$expected_slug.git"|"ssh://git@github.com/$expected_slug") ;;
            '')
              printf 'Project checkout %s has no origin remote; expected %s.\n' "$destination" "$expected_slug" >&2
              exit 43
              ;;
            *)
              printf 'Project checkout %s uses origin %s; expected %s.\n' "$destination" "$origin" "$expected_slug" >&2
              exit 44
              ;;
          esac
          git -C "$destination" remote set-url origin "$ssh_url"
          git -C "$destination" config core.sshCommand "$ssh_command"
          exit 0
        fi

        if [ -d "$destination" ] && [ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
          printf 'Project path %s is not an empty Git checkout.\n' "$destination" >&2
          exit 45
        fi

        mkdir -p /workspace
        GIT_SSH_COMMAND="$ssh_command" git clone "$ssh_url" "$destination"
        git -C "$destination" config core.sshCommand "$ssh_command"
        """
    }

    static func sshArguments(for worker: ServerProfile, script: String) -> [String] {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]

        if worker.port != 22 {
            arguments += ["-p", String(worker.port)]
        }

        let identityFile = worker.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !identityFile.isEmpty {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        arguments.append("--")
        arguments.append(worker.destination)
        arguments.append("exec /bin/sh -c \(shellQuote(script))")
        return arguments
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func fetchRepositories() async throws -> [GitHubRepository] {
        let data = try await runGH(arguments: Self.listRepositoryArguments())
        return try Self.parseRepositories(data)
            .filter { !$0.isArchived }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func ensureWorkerKey(
        repositoryName: String,
        worker: ServerProfile
    ) async throws -> String {
        let script = Self.workerKeyScript(repositoryName: repositoryName)
        let result = try await runSSH(worker: worker, script: script)
        return try Self.parseDeployPublicKey(String(decoding: result, as: UTF8.self))
    }

    private func ensureWritableDeployKey(
        publicKey: String,
        repository: GitHubRepository,
        worker: ServerProfile
    ) async throws {
        let data = try await runGH(arguments: Self.deployKeyListArguments(repository: repository))
        let deployKeys = try Self.parseDeployKeys(data)

        let publicKeyIdentity = Self.publicKeyIdentity(publicKey)
        if let existingKey = deployKeys.first(where: {
            Self.publicKeyIdentity($0.key) == publicKeyIdentity
        }) {
            if !existingKey.readOnly {
                return
            }

            _ = try await runGH(arguments: [
                "repo", "deploy-key", "delete", String(existingKey.id),
                "--repo", repository.nameWithOwner
            ])
        }

        let temporaryKeyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-relay-\(UUID().uuidString).pub")
        defer { try? FileManager.default.removeItem(at: temporaryKeyURL) }

        guard FileManager.default.createFile(
            atPath: temporaryKeyURL.path,
            contents: Data(publicKey.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw GitHubProjectError.commandFailed(
                tool: "Terminal Relay",
                message: "Could not stage the worker deploy key."
            )
        }

        let workerName = worker.displayName.prefix(80)
        _ = try await runGH(arguments: [
            "repo", "deploy-key", "add", temporaryKeyURL.path,
            "--repo", repository.nameWithOwner,
            "--title", "Terminal Relay — \(workerName)",
            "--allow-write"
        ])
    }

    private func provisionCheckout(
        repository: GitHubRepository,
        worker: ServerProfile
    ) async throws {
        _ = try await runSSH(
            worker: worker,
            script: Self.checkoutProvisionScript(repositoryName: repository.name)
        )
    }

    private func runGH(arguments: [String]) async throws -> Data {
        let executable = try Self.ghExecutableURL()
        let result = try await Subprocess.run(executable: executable, arguments: arguments)
        return try Self.checkedOutput(result, tool: "GitHub CLI")
    }

    private func runSSH(worker: ServerProfile, script: String) async throws -> Data {
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: Self.sshArguments(for: worker, script: script)
        )
        return try Self.checkedOutput(result, tool: "SSH")
    }

    private static func checkedOutput(_ result: Subprocess.Result, tool: String) throws -> Data {
        guard result.exitCode == 0 else {
            let standardError = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = standardError.isEmpty ? standardOutput : standardError
            throw GitHubProjectError.commandFailed(
                tool: tool,
                message: detail.isEmpty ? "\(tool) exited with status \(result.exitCode)." : detail
            )
        }
        return result.standardOutput
    }

    private static func ghExecutableURL() throws -> URL {
        var candidatePaths = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh"
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidatePaths += path
                .split(separator: ":")
                .map { "\($0)/gh" }
        }

        if let executablePath = candidatePaths.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) {
            return URL(fileURLWithPath: executablePath)
        }
        throw GitHubProjectError.ghNotInstalled
    }

    private static func publicKeyIdentity(_ key: String) -> String? {
        let fields = key.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        return "\(fields[0]) \(fields[1])"
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct GitHubDeployKey: Decodable {
    let id: Int64
    let key: String
    let readOnly: Bool
}

private enum Subprocess {
    struct Result {
        let exitCode: Int32
        let standardOutput: Data
        let standardError: Data
    }

    static func run(executable: URL, arguments: [String]) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let outputURL = fileManager.temporaryDirectory
                .appendingPathComponent("terminal-relay-output-\(UUID().uuidString)")
            let errorURL = fileManager.temporaryDirectory
                .appendingPathComponent("terminal-relay-error-\(UUID().uuidString)")

            guard fileManager.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ), fileManager.createFile(
                atPath: errorURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw GitHubProjectError.commandFailed(
                    tool: "Terminal Relay",
                    message: "Could not capture command output."
                )
            }
            defer {
                try? fileManager.removeItem(at: outputURL)
                try? fileManager.removeItem(at: errorURL)
            }

            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outputHandle
            process.standardError = errorHandle
            try process.run()
            process.waitUntilExit()

            try outputHandle.synchronize()
            try errorHandle.synchronize()
            return Result(
                exitCode: process.terminationStatus,
                standardOutput: try Data(contentsOf: outputURL),
                standardError: try Data(contentsOf: errorURL)
            )
        }.value
    }
}
