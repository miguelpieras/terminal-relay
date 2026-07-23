import XCTest
@testable import TerminalRelay

@MainActor
final class GitHubProjectServiceTests: XCTestCase {
    func testParsesRepositoryListFromGitHubCLIJSON() throws {
        let data = Data(
            """
            [
              {
                "id": "R_repo_two",
                "name": "second-project",
                "nameWithOwner": "miguelpieras/second-project",
                "isPrivate": true,
                "isArchived": false
              },
              {
                "id": "R_repo_one",
                "name": "first-project",
                "nameWithOwner": "miguelpieras/first-project",
                "isPrivate": false,
                "isArchived": false
              }
            ]
            """.utf8
        )

        let repositories = try GitHubProjectService.parseRepositories(data)

        XCTAssertEqual(repositories.count, 2)
        XCTAssertEqual(repositories[0].id, "R_repo_two")
        XCTAssertEqual(repositories[0].name, "second-project")
        XCTAssertEqual(repositories[0].nameWithOwner, "miguelpieras/second-project")
        XCTAssertTrue(repositories[0].isPrivate)
        XCTAssertFalse(repositories[0].isArchived)
    }

    func testRejectsMalformedGitHubCLIJSON() {
        XCTAssertThrowsError(
            try GitHubProjectService.parseRepositories(Data("{}".utf8))
        ) { error in
            XCTAssertEqual(error as? GitHubProjectError, .invalidGitHubResponse)
        }
    }

    func testTreatsEmptyDeployKeyOutputAsNoKeys() throws {
        XCTAssertTrue(try GitHubProjectService.parseDeployKeys(Data()).isEmpty)
        XCTAssertTrue(try GitHubProjectService.parseDeployKeys(Data(" \n".utf8)).isEmpty)
    }

    func testBuildsAllAccessibleRepositoryListAndPrivateCreateCommands() {
        XCTAssertEqual(
            GitHubProjectService.listRepositoryArguments(),
            [
                "api", "user/repos",
                "--method", "GET",
                "--paginate",
                "--slurp",
                "-f", "affiliation=owner,collaborator,organization_member",
                "-f", "per_page=100"
            ]
        )
        XCTAssertEqual(
            GitHubProjectService.createRepositoryArguments(repository: "worklific/terminal-relay"),
            [
                "repo", "create", "worklific/terminal-relay",
                "--private",
                "--add-readme"
            ]
        )
    }

    func testBuildsOwnerScopedRepositoryCommands() {
        XCTAssertEqual(
            GitHubProjectService.listRepositoryArguments(owner: "miguelpieras"),
            [
                "api", "user/repos",
                "--method", "GET",
                "--paginate",
                "--slurp",
                "-f", "affiliation=owner",
                "-f", "per_page=100"
            ]
        )
        XCTAssertEqual(
            GitHubProjectService.listRepositoryArguments(owner: "worklific"),
            [
                "api", "orgs/worklific/repos",
                "--method", "GET",
                "--paginate",
                "--slurp",
                "-f", "type=all",
                "-f", "per_page=100"
            ]
        )
    }

    func testParsesOrganizationPages() throws {
        let data = Data(
            """
            [
              [
                { "login": "worklific" },
                { "login": "CloudBrowser-AI" }
              ]
            ]
            """.utf8
        )

        XCTAssertEqual(
            try GitHubProjectService.parseOrganizationPages(data),
            ["CloudBrowser-AI", "worklific"]
        )
    }

    func testParsesPersonalAndOrganizationRepositoryPages() throws {
        let data = Data(
            """
            [
              [
                {
                  "node_id": "R_personal",
                  "name": "terminal-relay",
                  "full_name": "miguelpieras/terminal-relay",
                  "private": true,
                  "archived": false
                },
                {
                  "node_id": "R_org",
                  "name": "worklific-app",
                  "full_name": "worklific/worklific-app",
                  "private": true,
                  "archived": false
                }
              ]
            ]
            """.utf8
        )

        let repositories = try GitHubProjectService.parseRepositoryPages(data)

        XCTAssertEqual(repositories.map(\.nameWithOwner), [
            "miguelpieras/terminal-relay",
            "worklific/worklific-app"
        ])
        XCTAssertEqual(repositories[1].owner, "worklific")
    }

    func testNormalizesHumanProjectNameToSafeRepositoryComponent() {
        let name = GitHubProjectService.normalizedRepositoryName(
            from: "  Café Control / macOS; $(touch nope)  "
        )

        XCTAssertEqual(name, "cafe-control-macos-touch-nope")
        XCTAssertNotNil(name.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression))
        XCTAssertFalse(name.contains("/"))
    }

    func testExistingGitHubRepositoryNamesCanKeepDotsAndUnderscores() {
        XCTAssertTrue(GitHubProjectService.isSafeRepositoryName("Existing_Project.v2"))
        XCTAssertFalse(GitHubProjectService.isSafeRepositoryName("owner/project"))
        XCTAssertFalse(GitHubProjectService.isSafeRepositoryName(".."))
        XCTAssertTrue(GitHubProjectService.isSafeRepositoryReference("worklific/Existing_Project.v2"))
        XCTAssertFalse(GitHubProjectService.isSafeRepositoryReference("worklific/team/project"))
    }

    func testSSHArgumentsHonorWorkerDestinationPortAndIdentity() {
        let worker = ServerProfile(
            name: "Worker 7",
            host: "worker.example.com",
            port: 2_222,
            username: "relay",
            identityFile: "~/Keys/worker key"
        )
        let script = "printf '%s' \"ready\""

        let arguments = GitHubProjectService.sshArguments(for: worker, script: script)

        XCTAssertEqual(
            arguments,
            [
                "-o", "BatchMode=yes",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-o", "StrictHostKeyChecking=accept-new",
                "-p", "2222",
                "-i", ("~/Keys/worker key" as NSString).expandingTildeInPath,
                "--",
                "relay@worker.example.com",
                "exec /bin/sh -c \(GitHubProjectService.shellQuote(script))"
            ]
        )
    }

    func testProvisionScriptQuotesRepositoryInputAndChecksExistingCheckout() {
        let repositoryName = "project'; printf PWNED; '"
        let script = GitHubProjectService.checkoutProvisionScript(
            repositoryOwner: "worklific",
            repositoryName: repositoryName
        )

        XCTAssertTrue(
            script.contains("repo=\(GitHubProjectService.shellQuote(repositoryName))")
        )
        XCTAssertTrue(script.contains("git -C \"$destination\" remote get-url origin"))
        XCTAssertTrue(script.contains("git -C \"$destination\" remote set-url origin \"$ssh_url\""))
        XCTAssertTrue(script.contains("Project checkout %s uses origin %s; expected %s."))
        XCTAssertTrue(script.contains("Project path %s is not an empty Git checkout."))
        XCTAssertTrue(script.contains("GIT_SSH_COMMAND=\"$ssh_command\" git clone"))
        XCTAssertTrue(script.contains("refs/remotes/origin/main"))
        XCTAssertTrue(script.contains("switch --quiet --track -c main origin/main"))
        XCTAssertTrue(script.contains("branch -m main"))
        XCTAssertTrue(script.contains("push --set-upstream origin main"))
    }

    func testWorkerKeyScriptUsesRepoScopedKeyWithoutEmbeddingCredentials() {
        let script = GitHubProjectService.workerKeyScript(
            repositoryOwner: "miguelpieras",
            repositoryName: "terminal-relay"
        )

        XCTAssertTrue(script.contains("$HOME/.ssh/terminal-relay"))
        XCTAssertTrue(script.contains("miguelpieras-terminal-relay.ed25519"))
        XCTAssertTrue(script.contains("ssh-keygen -q -t ed25519"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(script.contains("https://"))
    }

    func testParsesMarkedDeployKeyDespiteWorkerLoginBanner() throws {
        let output = """
        Welcome to worker-1
        __TERMINAL_RELAY_DEPLOY_KEY__ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest terminal-relay
        """

        XCTAssertEqual(
            try GitHubProjectService.parseDeployPublicKey(output),
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITest terminal-relay"
        )
    }
}
