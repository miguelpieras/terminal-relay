import XCTest
@testable import TerminalRelay

final class ProjectProfileTests: XCTestCase {
    func testCodableRoundTripPreservesStoredFields() throws {
        let original = ProjectProfile(
            id: UUID(uuidString: "70C5B403-C7D6-48BA-8A2F-61AE88B0C705")!,
            serverID: UUID(uuidString: "50A309A8-FF38-4350-A80F-33653992B039")!,
            repositoryOwner: "example-user",
            repositoryName: "terminal-relay"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectProfile.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testRepositoryIdentityAndWorkingDirectoryAreDerivedFromRepositoryName() {
        let project = ProjectProfile(
            serverID: UUID(),
            repositoryOwner: "example-user",
            repositoryName: "  terminal-relay  "
        )

        XCTAssertEqual(project.displayName, "terminal-relay")
        XCTAssertEqual(project.githubRepository, "example-user/terminal-relay")
        XCTAssertEqual(project.workingDirectory, "/workspace/terminal-relay")
    }

    func testValidationRequiresSafeOwnerAndRepositoryName() {
        let serverID = UUID()
        var project = ProjectProfile(
            serverID: serverID,
            repositoryOwner: "example-user",
            repositoryName: "terminal-relay"
        )

        XCTAssertTrue(project.isValid)

        project.repositoryName = " "
        XCTAssertFalse(project.isValid)

        project.repositoryName = "../terminal-relay"
        XCTAssertFalse(project.isValid)

        project.repositoryName = ".."
        XCTAssertFalse(project.isValid)

        project.repositoryName = "terminal-relay"
        project.repositoryOwner = ""
        XCTAssertFalse(project.isValid)

        project.repositoryOwner = "example-user/team"
        XCTAssertFalse(project.isValid)

        project.repositoryOwner = "example-user"
        project.repositoryName = "terminal relay"
        XCTAssertFalse(project.isValid)
    }

    func testRepositoryNameNormalizationCreatesAStableGitHubSlug() {
        XCTAssertEqual(
            ProjectProfile.normalizedRepositoryName(from: "  Café Control / macOS  "),
            "cafe-control-macos"
        )
    }

    func testAssignedServerValidationUsesServerIdentifier() {
        let server = ServerProfile(name: "Worker", host: "worker")
        let project = ProjectProfile(
            serverID: server.id,
            repositoryOwner: "example-user",
            repositoryName: "terminal-relay"
        )

        XCTAssertTrue(project.hasAssignedServer(in: [server]))
        XCTAssertFalse(project.hasAssignedServer(in: []))
    }
}
