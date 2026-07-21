import XCTest
@testable import TerminalRelay

final class ServerProfileTests: XCTestCase {
    func testValidProfileAcceptsPortBoundariesAndTrimsRequiredText() {
        var profile = makeValidProfile()
        profile.name = "  Build Server  "
        profile.host = "  build.example.com  "
        profile.codexCommand = "  codex  "
        profile.claudeCommand = "  claude  "

        profile.port = 1
        XCTAssertTrue(profile.isValid)

        profile.port = 65_535
        XCTAssertTrue(profile.isValid)
    }

    func testValidationRejectsMissingRequiredTextAndOutOfRangePorts() {
        var profile = makeValidProfile()

        profile.name = " \n "
        XCTAssertFalse(profile.isValid)

        profile = makeValidProfile()
        profile.host = "\t"
        XCTAssertFalse(profile.isValid)

        profile = makeValidProfile()
        profile.codexCommand = " "
        XCTAssertFalse(profile.isValid)

        profile = makeValidProfile()
        profile.claudeCommand = "\n"
        XCTAssertFalse(profile.isValid)

        profile = makeValidProfile()
        profile.port = 0
        XCTAssertFalse(profile.isValid)

        profile.port = 65_536
        XCTAssertFalse(profile.isValid)
    }

    func testCodableRoundTripPreservesEveryField() throws {
        let original = ServerProfile(
            id: UUID(uuidString: "DAB59B20-7A21-459A-AD6A-E649C31C9660")!,
            name: "Remote Mac",
            host: "mac.example.com",
            port: 2_222,
            username: "runner",
            identityFile: "~/.ssh/terminal_relay",
            workingDirectory: "/Users/runner/Projects/Terminal Relay",
            codexAccountLabel: "Work Codex",
            claudeAccountLabel: "Work Claude",
            codexCommand: "codex --resume",
            claudeCommand: "claude --continue"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testConcurrencyKeyTreatsMagicDNSAndShortNameAsOneServer() {
        var shortProfile = makeValidProfile()
        shortProfile.host = "terminal-relay-worker-1"

        var magicDNSProfile = makeValidProfile()
        magicDNSProfile.host = "terminal-relay-worker-1.example-tailnet.ts.net."

        XCTAssertEqual(shortProfile.concurrencyKey, magicDNSProfile.concurrencyKey)
    }

    private func makeValidProfile() -> ServerProfile {
        ServerProfile(
            name: "Build Server",
            host: "build.example.com",
            codexCommand: "codex",
            claudeCommand: "claude"
        )
    }
}
