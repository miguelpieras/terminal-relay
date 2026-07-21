import XCTest
@testable import TerminalRelay

final class ProjectProfileTests: XCTestCase {
    func testCodableRoundTripPreservesEveryField() throws {
        let original = ProjectProfile(
            id: UUID(uuidString: "70C5B403-C7D6-48BA-8A2F-61AE88B0C705")!,
            name: "Terminal Relay",
            serverID: UUID(uuidString: "50A309A8-FF38-4350-A80F-33653992B039")!,
            githubRepository: "owner/terminal-relay",
            workingDirectory: "/home/relay/dev/terminal-relay"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectProfile.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testValidationRequiresOnlyNameAndWorkingDirectory() {
        let serverID = UUID()
        var project = ProjectProfile(
            name: "  Terminal Relay  ",
            serverID: serverID,
            workingDirectory: "  /home/relay/dev/terminal-relay  "
        )

        XCTAssertTrue(project.isValid)
        XCTAssertEqual(project.displayName, "Terminal Relay")

        project.name = " \n "
        XCTAssertFalse(project.isValid)

        project.name = "Terminal Relay"
        project.workingDirectory = "\t"
        XCTAssertFalse(project.isValid)
    }

    func testAssignedServerValidationUsesServerIdentifier() {
        let server = ServerProfile(name: "Worker", host: "worker")
        let project = ProjectProfile(
            name: "Terminal Relay",
            serverID: server.id,
            workingDirectory: "/workspace"
        )

        XCTAssertTrue(project.hasAssignedServer(in: [server]))
        XCTAssertFalse(project.hasAssignedServer(in: []))
    }
}
