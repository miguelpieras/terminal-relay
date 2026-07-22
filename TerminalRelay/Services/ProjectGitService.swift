import Combine
import Foundation

struct ProjectGitSnapshot: Equatable {
    let currentBranch: String
    let headOID: String?
    let isDetachedHead: Bool
    let localBranches: [String]
    let remoteBranches: [String]
    let changedFileCount: Int
    let stagedFileCount: Int
    let unstagedFileCount: Int
    let untrackedFileCount: Int
    let aheadCount: Int
    let behindCount: Int
    let hasUpstream: Bool
    let fetchedAt: Date

    var availableBranches: [String] {
        var values = Set(localBranches + remoteBranches)
        if !isDetachedHead {
            values.insert(currentBranch)
        }
        return values.sorted()
    }

    var hasChanges: Bool {
        changedFileCount > 0
    }

    var hasPendingPush: Bool {
        aheadCount > 0 || (headOID != nil && !isDetachedHead && !hasUpstream)
    }

    var originBranch: String? {
        isDetachedHead ? nil : "origin/\(currentBranch)"
    }
}

struct GitHubWorkflowRun: Decodable, Equatable, Identifiable {
    let databaseId: Int64
    let displayTitle: String
    let workflowName: String
    let status: String
    let conclusion: String
    let url: String

    var id: Int64 { databaseId }

    var isCompleted: Bool {
        status.caseInsensitiveCompare("completed") == .orderedSame
    }

    var succeeded: Bool {
        conclusion.caseInsensitiveCompare("success") == .orderedSame
    }
}

enum ProjectDeploymentState: Equatable {
    case checking(commitOID: String)
    case run(GitHubWorkflowRun)
    case noWorkflow(commitOID: String)
    case unavailable(String)
}

enum ProjectGitOperation: Equatable {
    case refreshing
    case switchingBranch
    case committingAndPushing
    case pushing
}

enum ProjectGitOperationResult: Equatable {
    case switchedBranch(String)
    case committedAndPushed
    case pushed
    case committedLocally(pushError: String)
    case pushFailed(String)

    var message: String {
        switch self {
        case .switchedBranch(let branch):
            return "Switched to \(branch)."
        case .committedAndPushed:
            return "Changes committed and pushed."
        case .pushed:
            return "Commits pushed."
        case .committedLocally(let pushError):
            return "Committed locally, but the push failed: \(pushError)"
        case .pushFailed(let message):
            return "Push failed: \(message)"
        }
    }
}

enum ProjectGitError: LocalizedError, Equatable {
    case invalidStatusResponse
    case invalidBranch
    case emptyCommitMessage
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidStatusResponse:
            return "The worker returned an unexpected Git status."
        case .invalidBranch:
            return "Choose a valid Git branch."
        case .emptyCommitMessage:
            return "Enter a commit message."
        case .commandFailed(let message):
            return message.isEmpty ? "The remote Git command failed." : message
        }
    }
}

@MainActor
final class ProjectGitService: ObservableObject {
    @Published private(set) var snapshots: [UUID: ProjectGitSnapshot] = [:]
    @Published private(set) var busyProjectIDs: Set<UUID> = []
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var currentOperations: [UUID: ProjectGitOperation] = [:]
    @Published private(set) var operationResults: [UUID: ProjectGitOperationResult] = [:]
    @Published private(set) var deploymentStates: [UUID: ProjectDeploymentState] = [:]

    private var deploymentTasks: [UUID: Task<Void, Never>] = [:]

    func snapshot(for projectID: UUID) -> ProjectGitSnapshot? {
        snapshots[projectID]
    }

    func isBusy(projectID: UUID) -> Bool {
        busyProjectIDs.contains(projectID)
    }

    func error(for projectID: UUID) -> String? {
        errors[projectID]
    }

    func operationResult(for projectID: UUID) -> ProjectGitOperationResult? {
        operationResults[projectID]
    }

    func clearOperationResult(for projectID: UUID) {
        operationResults[projectID] = nil
    }

    func deploymentState(for projectID: UUID) -> ProjectDeploymentState? {
        deploymentStates[projectID]
    }

    func refreshDeployment(project: ProjectProfile) {
        guard let commitOID = snapshots[project.id]?.headOID else { return }
        trackDeployment(project: project, commitOID: commitOID, waitsForNewRun: false)
    }

    @discardableResult
    func refresh(
        project: ProjectProfile,
        worker: ServerProfile,
        fetchRemote: Bool = false
    ) async -> Bool {
        guard begin(projectID: project.id, operation: .refreshing, clearsResult: false) else {
            return false
        }
        defer { end(projectID: project.id) }

        do {
            let snapshot = try await Self.fetchSnapshot(
                project: project,
                worker: worker,
                fetchRemote: fetchRemote
            )
            snapshots[project.id] = snapshot
            errors[project.id] = nil
            if fetchRemote, deploymentStates[project.id] == nil, let commitOID = snapshot.headOID {
                trackDeployment(project: project, commitOID: commitOID, waitsForNewRun: false)
            }
            return true
        } catch {
            errors[project.id] = Self.message(for: error)
            return false
        }
    }

    @discardableResult
    func switchBranch(
        _ branch: String,
        project: ProjectProfile,
        worker: ServerProfile
    ) async -> Bool {
        let branch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSafeBranchName(branch) else {
            errors[project.id] = ProjectGitError.invalidBranch.localizedDescription
            return false
        }
        guard begin(projectID: project.id, operation: .switchingBranch) else {
            return false
        }
        defer { end(projectID: project.id) }

        do {
            let script = Self.switchBranchScript(
                directory: project.workingDirectory,
                branch: branch
            )
            _ = try await Self.runChecked(worker: worker, script: script)
            operationResults[project.id] = .switchedBranch(branch)
            await updateSnapshotAfterMutation(project: project, worker: worker)
            return true
        } catch {
            errors[project.id] = Self.message(for: error)
            await updateSnapshotAfterMutation(
                project: project,
                worker: worker,
                preserveExistingError: true
            )
            return false
        }
    }

    @discardableResult
    func commitAndPush(
        message: String,
        project: ProjectProfile,
        worker: ServerProfile
    ) async -> Bool {
        let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            errors[project.id] = ProjectGitError.emptyCommitMessage.localizedDescription
            return false
        }
        guard begin(projectID: project.id, operation: .committingAndPushing) else {
            return false
        }
        defer { end(projectID: project.id) }

        do {
            let result = try await Subprocess.run(
                executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: GitHubProjectService.sshArguments(
                    for: worker,
                    script: Self.commitAndPushScript(
                        directory: project.workingDirectory,
                        message: message
                    )
                )
            )

            if result.exitCode == 0 {
                operationResults[project.id] = .committedAndPushed
                await updateSnapshotAfterMutation(project: project, worker: worker)
                trackLatestDeployment(project: project)
                return true
            }

            let failure = Self.failureMessage(for: result)
            let output = String(decoding: result.standardOutput, as: UTF8.self)
            if output.contains(Self.commitCompleteMarker) {
                operationResults[project.id] = .committedLocally(pushError: failure)
                errors[project.id] = operationResults[project.id]?.message
            } else {
                errors[project.id] = failure
            }
            await updateSnapshotAfterMutation(
                project: project,
                worker: worker,
                preserveExistingError: true
            )
            return false
        } catch {
            errors[project.id] = Self.message(for: error)
            await updateSnapshotAfterMutation(
                project: project,
                worker: worker,
                preserveExistingError: true
            )
            return false
        }
    }

    @discardableResult
    func push(project: ProjectProfile, worker: ServerProfile) async -> Bool {
        guard begin(projectID: project.id, operation: .pushing) else {
            return false
        }
        defer { end(projectID: project.id) }

        do {
            _ = try await Self.runChecked(
                worker: worker,
                script: Self.pushScript(directory: project.workingDirectory)
            )
            operationResults[project.id] = .pushed
            await updateSnapshotAfterMutation(project: project, worker: worker)
            trackLatestDeployment(project: project)
            return true
        } catch {
            let pushError = Self.message(for: error)
            operationResults[project.id] = .pushFailed(pushError)
            errors[project.id] = operationResults[project.id]?.message
            await updateSnapshotAfterMutation(
                project: project,
                worker: worker,
                preserveExistingError: true
            )
            return false
        }
    }

    static func parseSnapshot(
        _ data: Data,
        fetchedAt: Date = Date()
    ) throws -> ProjectGitSnapshot {
        var isReadingStatus = false
        var sawStatusStart = false
        var sawStatusEnd = false
        var sawComplete = false
        var branchHead: String?
        var headOID: String?
        var aheadCount = 0
        var behindCount = 0
        var hasUpstream = false
        var changedFileCount = 0
        var stagedFileCount = 0
        var unstagedFileCount = 0
        var untrackedFileCount = 0
        var localBranches: [String] = []
        var remoteBranches: [String] = []

        for substring in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let line = String(substring)

            if line == statusStartMarker {
                isReadingStatus = true
                sawStatusStart = true
                continue
            }
            if line == statusEndMarker, isReadingStatus {
                isReadingStatus = false
                sawStatusEnd = true
                continue
            }
            if line == completeMarker, sawStatusEnd {
                sawComplete = true
                continue
            }

            if isReadingStatus {
                if line.hasPrefix("# branch.head ") {
                    branchHead = String(line.dropFirst("# branch.head ".count))
                } else if line.hasPrefix("# branch.oid ") {
                    let value = String(line.dropFirst("# branch.oid ".count))
                    if value != "(initial)" {
                        headOID = value
                    }
                } else if line.hasPrefix("# branch.upstream ") {
                    hasUpstream = true
                } else if line.hasPrefix("# branch.ab ") {
                    let fields = line.dropFirst("# branch.ab ".count).split(separator: " ")
                    for field in fields {
                        if field.hasPrefix("+") {
                            aheadCount = Int(field.dropFirst()) ?? 0
                        } else if field.hasPrefix("-") {
                            behindCount = Int(field.dropFirst()) ?? 0
                        }
                    }
                } else if line.hasPrefix("? ") {
                    changedFileCount += 1
                    untrackedFileCount += 1
                } else if line.hasPrefix("u ") {
                    changedFileCount += 1
                } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                    changedFileCount += 1
                    let fields = line.split(separator: " ", omittingEmptySubsequences: true)
                    if fields.count > 1 {
                        let state = fields[1]
                        if state.first != "." {
                            stagedFileCount += 1
                        }
                        if state.count > 1, state[state.index(after: state.startIndex)] != "." {
                            unstagedFileCount += 1
                        }
                    }
                }
                continue
            }

            guard sawStatusEnd else { continue }
            if line.hasPrefix(localBranchMarker) {
                let branch = String(line.dropFirst(localBranchMarker.count))
                if !branch.isEmpty {
                    localBranches.append(branch)
                }
            } else if line.hasPrefix(remoteBranchMarker) {
                var branch = String(line.dropFirst(remoteBranchMarker.count))
                if branch.hasPrefix("origin/") {
                    branch.removeFirst("origin/".count)
                }
                if !branch.isEmpty, branch != "HEAD" {
                    remoteBranches.append(branch)
                }
            }
        }

        guard sawStatusStart, sawStatusEnd, sawComplete, let branchHead else {
            throw ProjectGitError.invalidStatusResponse
        }

        let isDetachedHead = branchHead == "(detached)"
        return ProjectGitSnapshot(
            currentBranch: isDetachedHead ? "Detached HEAD" : branchHead,
            headOID: headOID,
            isDetachedHead: isDetachedHead,
            localBranches: Array(Set(localBranches)).sorted(),
            remoteBranches: Array(Set(remoteBranches)).sorted(),
            changedFileCount: changedFileCount,
            stagedFileCount: stagedFileCount,
            unstagedFileCount: unstagedFileCount,
            untrackedFileCount: untrackedFileCount,
            aheadCount: aheadCount,
            behindCount: behindCount,
            hasUpstream: hasUpstream,
            fetchedAt: fetchedAt
        )
    }

    static func statusScript(directory: String, fetchRemote: Bool = false) -> String {
        let refreshCommand = fetchRemote
            ? """
            git -C "$repository" fetch --prune --quiet origin
            if [ -z "$(git -C "$repository" status --porcelain --untracked-files=all)" ] &&
               [ "$(git -C "$repository" symbolic-ref --quiet --short HEAD 2>/dev/null || true)" = "main" ] &&
               git -C "$repository" show-ref --verify --quiet refs/remotes/origin/main; then
              git -C "$repository" branch --set-upstream-to=origin/main main >/dev/null 2>&1 || true
              if git -C "$repository" merge-base --is-ancestor HEAD refs/remotes/origin/main; then
                git -C "$repository" merge --ff-only --quiet refs/remotes/origin/main
              fi
            fi
            """
            : ":"
        return """
        set -eu
        repository=\(GitHubProjectService.shellQuote(directory))
        git -C "$repository" rev-parse --is-inside-work-tree >/dev/null
        \(refreshCommand)
        printf '%s\\n' '\(statusStartMarker)'
        git -C "$repository" status --porcelain=v2 --branch --untracked-files=all
        printf '%s\\n' '\(statusEndMarker)'
        git -C "$repository" for-each-ref --format='\(localBranchMarker)%(refname:short)' refs/heads
        git -C "$repository" for-each-ref --format='\(remoteBranchMarker)%(refname:short)' refs/remotes/origin
        printf '%s\\n' '\(completeMarker)'
        """
    }

    static func switchBranchScript(directory: String, branch: String) -> String {
        """
        set -eu
        repository=\(GitHubProjectService.shellQuote(directory))
        branch=\(GitHubProjectService.shellQuote(branch))
        git -C "$repository" check-ref-format --branch "$branch" >/dev/null
        if [ -n "$(git -C "$repository" status --porcelain --untracked-files=all)" ]; then
          printf '%s\\n' 'Commit or discard the current changes before switching branches.' >&2
          exit 64
        fi
        git -C "$repository" fetch --prune origin
        if git -C "$repository" show-ref --verify --quiet "refs/heads/$branch"; then
          git -C "$repository" switch "$branch"
        elif git -C "$repository" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
          git -C "$repository" switch --track -c "$branch" "origin/$branch"
        else
          printf 'Branch %s does not exist.\\n' "$branch" >&2
          exit 65
        fi
        """
    }

    static func commitScript(directory: String, message: String) -> String {
        """
        set -eu
        repository=\(GitHubProjectService.shellQuote(directory))
        message=\(GitHubProjectService.shellQuote(message))
        branch="$(git -C "$repository" symbolic-ref --quiet --short HEAD)" || {
          printf '%s\\n' 'Check out a branch before committing.' >&2
          exit 66
        }
        if [ "$branch" != "main" ]; then
          printf 'Terminal Relay commits only from main; the worker is on %s.\\n' "$branch" >&2
          exit 67
        fi
        author_name="$(git -C "$repository" config --get user.name || printf '%s' 'Terminal Relay')"
        author_email="$(git -C "$repository" config --get user.email || printf '%s' 'terminal-relay@localhost')"
        git -C "$repository" add --all
        if git -C "$repository" diff --cached --quiet --exit-code; then
          printf '%s\\n' 'There are no changes to commit.' >&2
          exit 69
        fi
        git -C "$repository" -c user.name="$author_name" -c user.email="$author_email" commit --message="$message"
        """
    }

    static func commitAndPushScript(directory: String, message: String) -> String {
        """
        set -eu
        repository=\(GitHubProjectService.shellQuote(directory))
        message=\(GitHubProjectService.shellQuote(message))
        branch="$(git -C "$repository" symbolic-ref --quiet --short HEAD)" || {
          printf '%s\\n' 'Check out a branch before committing.' >&2
          exit 66
        }
        if [ "$branch" != "main" ]; then
          printf 'Terminal Relay commits only from main; the worker is on %s.\\n' "$branch" >&2
          exit 67
        fi
        author_name="$(git -C "$repository" config --get user.name || printf '%s' 'Terminal Relay')"
        author_email="$(git -C "$repository" config --get user.email || printf '%s' 'terminal-relay@localhost')"
        git -C "$repository" add --all
        if git -C "$repository" diff --cached --quiet --exit-code; then
          printf '%s\\n' 'There are no changes to commit.' >&2
          exit 69
        fi
        git -C "$repository" -c user.name="$author_name" -c user.email="$author_email" commit --message="$message"
        printf '%s\\n' '\(commitCompleteMarker)'
        current_branch="$(git -C "$repository" symbolic-ref --quiet --short HEAD)" || exit 70
        if [ "$current_branch" != "main" ]; then
          printf '%s\\n' 'The branch changed before the push; the commit was not pushed.' >&2
          exit 71
        fi
        git -C "$repository" push --set-upstream origin main
        """
    }

    static func pushScript(directory: String) -> String {
        """
        set -eu
        repository=\(GitHubProjectService.shellQuote(directory))
        branch="$(git -C "$repository" symbolic-ref --quiet --short HEAD)" || {
          printf '%s\\n' 'Check out a branch before pushing.' >&2
          exit 70
        }
        if [ "$branch" != "main" ]; then
          printf 'Terminal Relay pushes only main; the worker is on %s.\\n' "$branch" >&2
          exit 67
        fi
        git -C "$repository" push --set-upstream origin main
        """
    }

    static func isSafeBranchName(_ branch: String) -> Bool {
        !branch.isEmpty
            && branch.count <= 255
            && !branch.hasPrefix("-")
            && !branch.contains("\0")
            && !branch.contains("\n")
            && !branch.contains("\r")
    }

    static func workflowRunArguments(repository: String, commitOID: String) -> [String] {
        [
            "run", "list",
            "--repo", repository,
            "--commit", commitOID,
            "--limit", "1",
            "--json", "databaseId,displayTitle,workflowName,status,conclusion,url"
        ]
    }

    static func parseWorkflowRuns(_ data: Data) throws -> [GitHubWorkflowRun] {
        do {
            return try JSONDecoder().decode([GitHubWorkflowRun].self, from: data)
        } catch {
            throw GitHubProjectError.invalidGitHubResponse
        }
    }

    private static let statusStartMarker = "__TERMINAL_RELAY_GIT_STATUS_BEGIN__"
    private static let statusEndMarker = "__TERMINAL_RELAY_GIT_STATUS_END__"
    private static let localBranchMarker = "__TERMINAL_RELAY_GIT_LOCAL_BRANCH__"
    private static let remoteBranchMarker = "__TERMINAL_RELAY_GIT_REMOTE_BRANCH__"
    private static let commitCompleteMarker = "__TERMINAL_RELAY_GIT_COMMIT_COMPLETE__"
    private static let completeMarker = "__TERMINAL_RELAY_GIT_COMPLETE__"

    private func begin(
        projectID: UUID,
        operation: ProjectGitOperation,
        clearsResult: Bool = true
    ) -> Bool {
        guard busyProjectIDs.insert(projectID).inserted else { return false }
        currentOperations[projectID] = operation
        if operation != .refreshing {
            errors[projectID] = nil
        }
        if clearsResult {
            operationResults[projectID] = nil
        }
        return true
    }

    private func end(projectID: UUID) {
        busyProjectIDs.remove(projectID)
        currentOperations[projectID] = nil
    }

    private func trackLatestDeployment(project: ProjectProfile) {
        guard let commitOID = snapshots[project.id]?.headOID else { return }
        trackDeployment(project: project, commitOID: commitOID, waitsForNewRun: true)
    }

    private func trackDeployment(
        project: ProjectProfile,
        commitOID: String,
        waitsForNewRun: Bool
    ) {
        deploymentTasks[project.id]?.cancel()
        deploymentStates[project.id] = .checking(commitOID: commitOID)
        deploymentTasks[project.id] = Task { [weak self] in
            await self?.pollDeployment(
                project: project,
                commitOID: commitOID,
                waitsForNewRun: waitsForNewRun
            )
        }
    }

    private func pollDeployment(
        project: ProjectProfile,
        commitOID: String,
        waitsForNewRun: Bool
    ) async {
        defer { deploymentTasks[project.id] = nil }

        for attempt in 0..<75 {
            guard !Task.isCancelled else { return }

            do {
                let data = try await GitHubProjectService.runGitHubCLI(
                    arguments: Self.workflowRunArguments(
                        repository: project.githubRepository,
                        commitOID: commitOID
                    )
                )
                if let run = try Self.parseWorkflowRuns(data).first {
                    deploymentStates[project.id] = .run(run)
                    if run.isCompleted { return }
                } else if !waitsForNewRun || attempt >= 15 {
                    deploymentStates[project.id] = .noWorkflow(commitOID: commitOID)
                    return
                }
            } catch {
                deploymentStates[project.id] = .unavailable(Self.message(for: error))
                return
            }

            do {
                try await Task.sleep(for: .seconds(4))
            } catch {
                return
            }
        }
    }

    private func updateSnapshotAfterMutation(
        project: ProjectProfile,
        worker: ServerProfile,
        preserveExistingError: Bool = false
    ) async {
        let existingError = preserveExistingError ? errors[project.id] : nil
        do {
            snapshots[project.id] = try await Self.fetchSnapshot(project: project, worker: worker)
            if let existingError {
                errors[project.id] = existingError
            } else {
                errors[project.id] = nil
            }
        } catch {
            let refreshError = Self.message(for: error)
            if let existingError {
                errors[project.id] = "\(existingError) Status refresh also failed: \(refreshError)"
            } else {
                errors[project.id] = "The Git operation succeeded, but status could not be refreshed: \(refreshError)"
            }
        }
    }

    private static func fetchSnapshot(
        project: ProjectProfile,
        worker: ServerProfile,
        fetchRemote: Bool = false
    ) async throws -> ProjectGitSnapshot {
        let data = try await runChecked(
            worker: worker,
            script: statusScript(
                directory: project.workingDirectory,
                fetchRemote: fetchRemote
            )
        )
        return try parseSnapshot(data)
    }

    private static func runChecked(worker: ServerProfile, script: String) async throws -> Data {
        let result = try await Subprocess.run(
            executable: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: GitHubProjectService.sshArguments(for: worker, script: script)
        )
        guard result.exitCode == 0 else {
            throw ProjectGitError.commandFailed(failureMessage(for: result))
        }
        return result.standardOutput
    }

    private static func failureMessage(for result: Subprocess.Result) -> String {
        let standardError = String(decoding: result.standardError, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let standardOutput = String(decoding: result.standardOutput, as: UTF8.self)
            .split(separator: "\n")
            .filter { $0 != Substring(commitCompleteMarker) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = standardError.isEmpty ? standardOutput : standardError
        return detail.isEmpty ? "SSH exited with status \(result.exitCode)." : detail
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
