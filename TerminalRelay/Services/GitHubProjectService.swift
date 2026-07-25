import Combine
import Foundation

struct GitHubRepository: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let nameWithOwner: String
    let isPrivate: Bool
    let isArchived: Bool

    var owner: String {
        String(nameWithOwner.split(separator: "/", maxSplits: 1).first ?? "")
    }
}

private struct GitHubAPIRepository: Decodable {
    let nodeID: String
    let name: String
    let fullName: String
    let isPrivate: Bool
    let isArchived: Bool

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case name
        case fullName = "full_name"
        case isPrivate = "private"
        case isArchived = "archived"
    }

    var repository: GitHubRepository {
        GitHubRepository(
            id: nodeID,
            name: name,
            nameWithOwner: fullName,
            isPrivate: isPrivate,
            isArchived: isArchived
        )
    }
}

private struct GitHubAPIOrganization: Decodable {
    let login: String
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
    @Published private(set) var authenticatedUser = ""
    @Published private(set) var organizations: [String] = []
    @Published private(set) var repositories: [GitHubRepository] = []
    @Published private(set) var isLoadingRepositories = false
    @Published private(set) var organizationErrorMessage: String?
    @Published private(set) var errorMessage: String?

    private var didLoadOrganizations = false
    private var isLoadingOrganizations = false
    private var repositoryCache: [String: [GitHubRepository]] = [:]
    private var repositoryRequestID: UUID?
    private var displayedRepositoryCacheKey: String?

    func loadOrganizationsIfNeeded() async {
        guard !didLoadOrganizations, !isLoadingOrganizations else { return }

        isLoadingOrganizations = true
        organizationErrorMessage = nil
        defer { isLoadingOrganizations = false }

        do {
            authenticatedUser = try Self.parseAuthenticatedUser(
                await runGH(arguments: Self.authenticatedUserArguments())
            )
            organizations = try Self.parseOrganizationPages(
                await runGH(arguments: Self.listOrganizationArguments())
            )
            didLoadOrganizations = true
        } catch {
            organizationErrorMessage = Self.message(for: error)
        }
    }

    func loadRepositories(owner: String?, force: Bool = false) async {
        let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = Self.repositoryCacheKey(owner: owner)
        let requestID = UUID()
        repositoryRequestID = requestID
        displayedRepositoryCacheKey = cacheKey

        if !force, let cachedRepositories = repositoryCache[cacheKey] {
            repositories = cachedRepositories
            isLoadingRepositories = false
            errorMessage = nil
            return
        }

        repositories = []
        isLoadingRepositories = true
        errorMessage = nil

        do {
            let fetchedRepositories = try await fetchRepositories(owner: owner)
            repositoryCache[cacheKey] = fetchedRepositories
            guard repositoryRequestID == requestID else { return }
            repositories = fetchedRepositories
            isLoadingRepositories = false
        } catch {
            guard repositoryRequestID == requestID else { return }
            errorMessage = Self.message(for: error)
            isLoadingRepositories = false
        }
    }

    @discardableResult
    func prepare(
        repositoryReference: String,
        create: Bool,
        on worker: ServerProfile
    ) async throws -> GitHubRepository {
        let preparedReference = repositoryReference
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if create {
            let components = preparedReference.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 2 else {
                throw GitHubProjectError.invalidRepositoryName
            }
        }
        guard Self.isSafeRepositoryReference(preparedReference) else {
            throw GitHubProjectError.invalidRepositoryName
        }

        errorMessage = nil

        do {
            if create {
                _ = try await runGH(
                    arguments: Self.createRepositoryArguments(repository: preparedReference)
                )
            }

            let repositoryData = try await runGH(
                arguments: Self.viewRepositoryArguments(repository: preparedReference)
            )
            let repository = try Self.parseRepository(repositoryData)
            guard repository.nameWithOwner.caseInsensitiveCompare(
                preparedReference
            ) == .orderedSame,
                !repository.owner.isEmpty,
                Self.isSafeRepositoryName(repository.name),
                !repository.isArchived else {
                throw GitHubProjectError.invalidGitHubResponse
            }

            let publicKey = try await ensureWorkerKey(
                repository: repository,
                worker: worker
            )
            try await ensureWritableDeployKey(
                publicKey: publicKey,
                repository: repository,
                worker: worker
            )
            try await provisionCheckout(repository: repository, worker: worker)
            _ = try await runGH(arguments: [
                "repo", "edit", repository.nameWithOwner,
                "--default-branch", "main"
            ])

            updateRepositoryCache(with: repository)
            if let displayedRepositoryCacheKey,
               let displayedRepositories = repositoryCache[displayedRepositoryCacheKey] {
                repositories = displayedRepositories
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

    static func isSafeRepositoryOwner(_ value: String) -> Bool {
        !value.isEmpty
            && value.count <= 100
            && value.range(of: #"^[A-Za-z0-9-]+$"#, options: .regularExpression) != nil
    }

    static func isSafeRepositoryReference(_ value: String) -> Bool {
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return false }
        let owner = String(components[0])
        return isSafeRepositoryOwner(owner)
            && isSafeRepositoryName(String(components[1]))
    }

    static func listOrganizationArguments() -> [String] {
        [
            "api", "user/orgs",
            "--method", "GET",
            "--paginate",
            "--slurp",
            "-f", "per_page=100"
        ]
    }

    static func authenticatedUserArguments() -> [String] {
        ["api", "user", "--jq", ".login"]
    }

    static func listRepositoryArguments(
        owner: String? = nil,
        authenticatedUser: String? = nil
    ) -> [String] {
        if let owner {
            if let authenticatedUser,
               owner.caseInsensitiveCompare(authenticatedUser) == .orderedSame {
                return [
                    "api", "user/repos",
                    "--method", "GET",
                    "--paginate",
                    "--slurp",
                    "-f", "affiliation=owner",
                    "-f", "per_page=100"
                ]
            }

            return [
                "api", "orgs/\(owner)/repos",
                "--method", "GET",
                "--paginate",
                "--slurp",
                "-f", "type=all",
                "-f", "per_page=100"
            ]
        }

        return [
            "api", "user/repos",
            "--method", "GET",
            "--paginate",
            "--slurp",
            "-f", "affiliation=owner,collaborator,organization_member",
            "-f", "per_page=100"
        ]
    }

    static func createRepositoryArguments(repository: String) -> [String] {
        [
            "repo", "create", repository,
            "--private",
            "--add-readme"
        ]
    }

    static func viewRepositoryArguments(repository: String) -> [String] {
        [
            "repo", "view", repository,
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

    static func parseRepositoryPages(_ data: Data) throws -> [GitHubRepository] {
        do {
            return try JSONDecoder()
                .decode([[GitHubAPIRepository]].self, from: data)
                .flatMap { $0.map(\.repository) }
        } catch {
            throw GitHubProjectError.invalidGitHubResponse
        }
    }

    static func parseOrganizationPages(_ data: Data) throws -> [String] {
        do {
            return try JSONDecoder()
                .decode([[GitHubAPIOrganization]].self, from: data)
                .flatMap { $0.map(\.login) }
                .filter(Self.isSafeRepositoryOwner)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            throw GitHubProjectError.invalidGitHubResponse
        }
    }

    static func parseAuthenticatedUser(_ data: Data) throws -> String {
        let user = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard isSafeRepositoryOwner(user) else {
            throw GitHubProjectError.invalidGitHubResponse
        }
        return user
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

    static func workerKeyScript(repositoryOwner: String, repositoryName: String) -> String {
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

    static func checkoutProvisionScript(repositoryOwner: String, repositoryName: String) -> String {
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

        select_main() {
          if [ -n "$(git -C "$destination" status --porcelain --untracked-files=all)" ]; then
            return
          fi

          if git -C "$destination" show-ref --verify --quiet refs/remotes/origin/main; then
            if git -C "$destination" show-ref --verify --quiet refs/heads/main; then
              git -C "$destination" switch --quiet main
            else
              git -C "$destination" switch --quiet --track -c main origin/main
            fi
          else
            current_branch="$(git -C "$destination" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
            if git -C "$destination" show-ref --verify --quiet refs/heads/main; then
              git -C "$destination" switch --quiet main
            elif [ -n "$current_branch" ]; then
              git -C "$destination" branch -m main
            else
              return
            fi
            GIT_SSH_COMMAND="$ssh_command" git -C "$destination" push --set-upstream origin main
          fi
          git -C "$destination" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
        }

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
          GIT_SSH_COMMAND="$ssh_command" git -C "$destination" fetch --prune --quiet origin
          select_main
          exit 0
        fi

        if [ -d "$destination" ] && [ -n "$(find "$destination" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
          printf 'Project path %s is not an empty Git checkout.\n' "$destination" >&2
          exit 45
        fi

        mkdir -p /workspace
        GIT_SSH_COMMAND="$ssh_command" git clone "$ssh_url" "$destination"
        git -C "$destination" config core.sshCommand "$ssh_command"
        select_main
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

    private func fetchRepositories(owner: String?) async throws -> [GitHubRepository] {
        if let owner, !Self.isSafeRepositoryOwner(owner) {
            throw GitHubProjectError.invalidRepositoryName
        }

        let data = try await runGH(arguments: Self.listRepositoryArguments(
            owner: owner,
            authenticatedUser: authenticatedUser
        ))
        return try Self.parseRepositoryPages(data)
            .filter { !$0.isArchived }
            .sorted {
                $0.nameWithOwner.localizedCaseInsensitiveCompare($1.nameWithOwner) == .orderedAscending
            }
    }

    private static func repositoryCacheKey(owner: String?) -> String {
        owner?.lowercased() ?? "*"
    }

    private func updateRepositoryCache(with repository: GitHubRepository) {
        for cacheKey in [
            Self.repositoryCacheKey(owner: repository.owner),
            Self.repositoryCacheKey(owner: nil)
        ] where repositoryCache[cacheKey] != nil {
            var cachedRepositories = repositoryCache[cacheKey] ?? []
            if let index = cachedRepositories.firstIndex(where: {
                $0.nameWithOwner.caseInsensitiveCompare(repository.nameWithOwner) == .orderedSame
            }) {
                cachedRepositories[index] = repository
            } else {
                cachedRepositories.append(repository)
            }
            repositoryCache[cacheKey] = cachedRepositories.sorted {
                $0.nameWithOwner.localizedCaseInsensitiveCompare($1.nameWithOwner) == .orderedAscending
            }
        }
    }

    private func ensureWorkerKey(
        repository: GitHubRepository,
        worker: ServerProfile
    ) async throws -> String {
        let script = Self.workerKeyScript(
            repositoryOwner: repository.owner,
            repositoryName: repository.name
        )
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
            script: Self.checkoutProvisionScript(
                repositoryOwner: repository.owner,
                repositoryName: repository.name
            )
        )
    }

    private func runGH(arguments: [String]) async throws -> Data {
        try await Self.runGitHubCLI(arguments: arguments)
    }

    static func runGitHubCLI(arguments: [String]) async throws -> Data {
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

enum Subprocess {
    struct Result {
        let exitCode: Int32
        let standardOutput: Data
        let standardError: Data
    }

    static func run(
        executable: URL,
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> Result {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let outputURL = fileManager.temporaryDirectory
                .appendingPathComponent("terminal-relay-output-\(UUID().uuidString)")
            let errorURL = fileManager.temporaryDirectory
                .appendingPathComponent("terminal-relay-error-\(UUID().uuidString)")
            let inputURL = standardInput.map { _ in
                fileManager.temporaryDirectory
                    .appendingPathComponent("terminal-relay-input-\(UUID().uuidString)")
            }

            guard fileManager.createFile(
                atPath: outputURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ), fileManager.createFile(
                atPath: errorURL.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            ), inputURL == nil || fileManager.createFile(
                atPath: inputURL!.path,
                contents: standardInput,
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
                if let inputURL {
                    try? fileManager.removeItem(at: inputURL)
                }
            }

            let outputHandle = try FileHandle(forWritingTo: outputURL)
            let errorHandle = try FileHandle(forWritingTo: errorURL)
            let inputHandle = try inputURL.map(FileHandle.init(forReadingFrom:))
            defer {
                try? outputHandle.close()
                try? errorHandle.close()
                try? inputHandle?.close()
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = inputHandle
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
