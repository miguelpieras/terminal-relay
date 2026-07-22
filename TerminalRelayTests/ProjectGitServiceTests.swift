import XCTest
@testable import TerminalRelay

@MainActor
final class ProjectGitServiceTests: XCTestCase {
    func testParsesBranchChangesAndAvailableBranches() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let data = Data(
            """
            Welcome to worker-1
            __TERMINAL_RELAY_GIT_STATUS_BEGIN__
            # branch.oid 0123456789abcdef
            # branch.head feature/login
            # branch.upstream origin/feature/login
            # branch.ab +2 -1
            1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb Sources/Staged.swift
            1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb Sources/Modified.swift
            1 MM N... 100644 100644 100644 aaaaaaa bbbbbbb Sources/Both.swift
            2 R. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 Sources/New.swift\tSources/Old.swift
            ? Sources/New File.swift
            __TERMINAL_RELAY_GIT_STATUS_END__
            __TERMINAL_RELAY_GIT_LOCAL_BRANCH__main
            __TERMINAL_RELAY_GIT_LOCAL_BRANCH__feature/login
            __TERMINAL_RELAY_GIT_REMOTE_BRANCH__origin/HEAD
            __TERMINAL_RELAY_GIT_REMOTE_BRANCH__origin/main
            __TERMINAL_RELAY_GIT_REMOTE_BRANCH__origin/release/v2
            __TERMINAL_RELAY_GIT_COMPLETE__
            """.utf8
        )

        let snapshot = try ProjectGitService.parseSnapshot(data, fetchedAt: fetchedAt)

        XCTAssertEqual(snapshot.currentBranch, "feature/login")
        XCTAssertEqual(snapshot.headOID, "0123456789abcdef")
        XCTAssertFalse(snapshot.isDetachedHead)
        XCTAssertEqual(snapshot.localBranches, ["feature/login", "main"])
        XCTAssertEqual(snapshot.remoteBranches, ["main", "release/v2"])
        XCTAssertEqual(snapshot.availableBranches, ["feature/login", "main", "release/v2"])
        XCTAssertEqual(snapshot.changedFileCount, 5)
        XCTAssertEqual(snapshot.stagedFileCount, 3)
        XCTAssertEqual(snapshot.unstagedFileCount, 2)
        XCTAssertEqual(snapshot.untrackedFileCount, 1)
        XCTAssertEqual(snapshot.aheadCount, 2)
        XCTAssertEqual(snapshot.behindCount, 1)
        XCTAssertTrue(snapshot.hasUpstream)
        XCTAssertTrue(snapshot.hasChanges)
        XCTAssertTrue(snapshot.hasPendingPush)
        XCTAssertEqual(snapshot.originBranch, "origin/feature/login")
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
    }

    func testParsesDetachedHeadAndInitialBranch() throws {
        let detached = try ProjectGitService.parseSnapshot(
            Data(
                """
                __TERMINAL_RELAY_GIT_STATUS_BEGIN__
                # branch.oid abcdef0123456789
                # branch.head (detached)
                __TERMINAL_RELAY_GIT_STATUS_END__
                __TERMINAL_RELAY_GIT_LOCAL_BRANCH__main
                __TERMINAL_RELAY_GIT_COMPLETE__
                """.utf8
            )
        )
        XCTAssertEqual(detached.currentBranch, "Detached HEAD")
        XCTAssertEqual(detached.headOID, "abcdef0123456789")
        XCTAssertTrue(detached.isDetachedHead)
        XCTAssertNil(detached.originBranch)
        XCTAssertFalse(detached.hasUpstream)
        XCTAssertFalse(detached.hasPendingPush)
        XCTAssertEqual(detached.availableBranches, ["main"])

        let initial = try ProjectGitService.parseSnapshot(
            Data(
                """
                __TERMINAL_RELAY_GIT_STATUS_BEGIN__
                # branch.oid (initial)
                # branch.head main
                __TERMINAL_RELAY_GIT_STATUS_END__
                __TERMINAL_RELAY_GIT_COMPLETE__
                """.utf8
            )
        )
        XCTAssertEqual(initial.currentBranch, "main")
        XCTAssertNil(initial.headOID)
        XCTAssertFalse(initial.hasUpstream)
        XCTAssertFalse(initial.hasPendingPush)
        XCTAssertEqual(initial.availableBranches, ["main"])
    }

    func testLocalCommitWithoutUpstreamRemainsPushable() throws {
        let snapshot = try ProjectGitService.parseSnapshot(
            Data(
                """
                __TERMINAL_RELAY_GIT_STATUS_BEGIN__
                # branch.oid abcdef0123456789
                # branch.head feature/new
                __TERMINAL_RELAY_GIT_STATUS_END__
                __TERMINAL_RELAY_GIT_LOCAL_BRANCH__feature/new
                __TERMINAL_RELAY_GIT_COMPLETE__
                """.utf8
            )
        )

        XCTAssertFalse(snapshot.hasUpstream)
        XCTAssertTrue(snapshot.hasPendingPush)
    }

    func testConflictCountsAsOneChangeWithoutInventingStagingState() throws {
        let snapshot = try ProjectGitService.parseSnapshot(
            Data(
                """
                __TERMINAL_RELAY_GIT_STATUS_BEGIN__
                # branch.oid abcdef0123456789
                # branch.head main
                u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc Conflict.swift
                __TERMINAL_RELAY_GIT_STATUS_END__
                __TERMINAL_RELAY_GIT_COMPLETE__
                """.utf8
            )
        )

        XCTAssertEqual(snapshot.changedFileCount, 1)
        XCTAssertEqual(snapshot.stagedFileCount, 0)
        XCTAssertEqual(snapshot.unstagedFileCount, 0)
    }

    func testRejectsIncompleteOrUnmarkedStatusOutput() {
        XCTAssertThrowsError(
            try ProjectGitService.parseSnapshot(Data("# branch.head main\n".utf8))
        ) { error in
            XCTAssertEqual(error as? ProjectGitError, .invalidStatusResponse)
        }

        XCTAssertThrowsError(
            try ProjectGitService.parseSnapshot(
                Data(
                    """
                    __TERMINAL_RELAY_GIT_STATUS_BEGIN__
                    # branch.head main
                    __TERMINAL_RELAY_GIT_STATUS_END__
                    """.utf8
                )
            )
        ) { error in
            XCTAssertEqual(error as? ProjectGitError, .invalidStatusResponse)
        }
    }

    func testStatusScriptQuotesDirectoryAndUsesMachineReadableGitOutput() {
        let directory = "/workspace/repo'; touch /tmp/pwned; '"
        let script = ProjectGitService.statusScript(directory: directory)

        XCTAssertTrue(
            script.contains("repository=\(GitHubProjectService.shellQuote(directory))")
        )
        XCTAssertTrue(script.contains("status --porcelain=v2 --branch --untracked-files=all"))
        XCTAssertTrue(script.contains("for-each-ref"))
        XCTAssertTrue(script.contains("refs/remotes/origin"))
        XCTAssertFalse(script.contains("repository=\(directory)\n"))

        let fetchingScript = ProjectGitService.statusScript(
            directory: directory,
            fetchRemote: true
        )
        XCTAssertTrue(fetchingScript.contains("fetch --prune --quiet origin"))
        XCTAssertFalse(fetchingScript.contains("fetch --prune --quiet origin || true"))
    }

    func testSwitchScriptQuotesBranchRefusesDirtyTreeAndTracksRemote() throws {
        let directory = "/workspace/example"
        let branch = "feature/it's-safe"
        let script = ProjectGitService.switchBranchScript(
            directory: directory,
            branch: branch
        )

        XCTAssertTrue(script.contains("branch=\(GitHubProjectService.shellQuote(branch))"))
        XCTAssertTrue(script.contains("check-ref-format --branch \"$branch\""))
        XCTAssertTrue(script.contains("status --porcelain --untracked-files=all"))
        XCTAssertTrue(script.contains("Commit or discard the current changes before switching branches."))
        XCTAssertTrue(script.contains("fetch --prune origin"))
        XCTAssertTrue(script.contains("show-ref --verify --quiet \"refs/heads/$branch\""))
        XCTAssertTrue(script.contains("show-ref --verify --quiet \"refs/remotes/origin/$branch\""))
        XCTAssertTrue(script.contains("switch --track -c \"$branch\" \"origin/$branch\""))

        let statusCheck = try XCTUnwrap(script.range(of: "status --porcelain"))
        let fetch = try XCTUnwrap(script.range(of: "fetch --prune"))
        XCTAssertLessThan(statusCheck.lowerBound, fetch.lowerBound)
    }

    func testRejectsObviouslyUnsafeBranchNamesBeforeSSH() {
        XCTAssertTrue(ProjectGitService.isSafeBranchName("feature/login"))
        XCTAssertTrue(ProjectGitService.isSafeBranchName("release/v2.0"))
        XCTAssertFalse(ProjectGitService.isSafeBranchName(""))
        XCTAssertFalse(ProjectGitService.isSafeBranchName("-force"))
        XCTAssertFalse(ProjectGitService.isSafeBranchName("main\nmalicious"))
        XCTAssertFalse(ProjectGitService.isSafeBranchName("main\0malicious"))
    }

    func testCommitScriptQuotesMessageUsesSafeIdentityFallbackAndStagesAllChanges() throws {
        let directory = "/workspace/example"
        let message = "Fix worker's status; $(touch /tmp/pwned)"
        let script = ProjectGitService.commitScript(directory: directory, message: message)

        XCTAssertTrue(script.contains("repository=\(GitHubProjectService.shellQuote(directory))"))
        XCTAssertTrue(script.contains("message=\(GitHubProjectService.shellQuote(message))"))
        XCTAssertTrue(script.contains("symbolic-ref --quiet --short HEAD"))
        XCTAssertTrue(script.contains("config --get user.name || printf '%s' 'Terminal Relay'"))
        XCTAssertTrue(script.contains("config --get user.email || printf '%s' 'terminal-relay@localhost'"))
        XCTAssertTrue(script.contains("add --all"))
        XCTAssertTrue(script.contains("diff --cached --quiet --exit-code"))
        XCTAssertTrue(script.contains("-c user.name=\"$author_name\""))
        XCTAssertTrue(script.contains("-c user.email=\"$author_email\""))
        XCTAssertTrue(script.contains("commit --message=\"$message\""))

        let identityCheck = try XCTUnwrap(script.range(of: "config --get user.name"))
        let staging = try XCTUnwrap(script.range(of: "add --all"))
        XCTAssertLessThan(identityCheck.lowerBound, staging.lowerBound)
    }

    func testPushScriptUsesAttachedValidatedBranchAndSetsUpstream() {
        let directory = "/workspace/example'; false; '"
        let script = ProjectGitService.pushScript(directory: directory)

        XCTAssertTrue(
            script.contains("repository=\(GitHubProjectService.shellQuote(directory))")
        )
        XCTAssertTrue(script.contains("symbolic-ref --quiet --short HEAD"))
        XCTAssertTrue(script.contains("check-ref-format --branch \"$branch\""))
        XCTAssertTrue(script.contains("push --set-upstream origin \"$branch\""))
    }

    func testCommitAndPushUsesOneRemoteScriptAndMarksCompletedCommit() {
        let script = ProjectGitService.commitAndPushScript(
            directory: "/workspace/example",
            message: "Ship Git controls"
        )

        XCTAssertTrue(script.contains("commit --message=\"$message\""))
        XCTAssertTrue(script.contains("__TERMINAL_RELAY_GIT_COMMIT_COMPLETE__"))
        XCTAssertTrue(script.contains("current_branch="))
        XCTAssertTrue(script.contains("push --set-upstream origin \"$branch\""))
    }

    func testBuildsAndParsesWorkflowRunLookupForPushedCommit() throws {
        XCTAssertEqual(
            ProjectGitService.workflowRunArguments(
                repository: "worklific/worklific-app",
                commitOID: "0123456789abcdef"
            ),
            [
                "run", "list",
                "--repo", "worklific/worklific-app",
                "--commit", "0123456789abcdef",
                "--limit", "1",
                "--json", "databaseId,displayTitle,workflowName,status,conclusion,url"
            ]
        )

        let runs = try ProjectGitService.parseWorkflowRuns(Data(
            """
            [{
              "databaseId": 42,
              "displayTitle": "Ship environment panel",
              "workflowName": "Deploy",
              "status": "completed",
              "conclusion": "success",
              "url": "https://github.com/worklific/worklific-app/actions/runs/42"
            }]
            """.utf8
        ))

        XCTAssertEqual(runs.first?.workflowName, "Deploy")
        XCTAssertTrue(try XCTUnwrap(runs.first).isCompleted)
        XCTAssertTrue(try XCTUnwrap(runs.first).succeeded)
    }

    func testOperationResultMessagesPreservePartialPushFailure() {
        XCTAssertEqual(
            ProjectGitOperationResult.switchedBranch("main").message,
            "Switched to main."
        )
        XCTAssertEqual(
            ProjectGitOperationResult.committedLocally(pushError: "Permission denied").message,
            "Committed locally, but the push failed: Permission denied"
        )
        XCTAssertEqual(
            ProjectGitOperationResult.pushFailed("Permission denied").message,
            "Push failed: Permission denied"
        )
    }

    func testPartialPushFailureRemainsActionable() {
        let result = ProjectGitOperationResult.committedLocally(pushError: "Network unavailable")

        XCTAssertEqual(
            result.message,
            "Committed locally, but the push failed: Network unavailable"
        )
    }
}
