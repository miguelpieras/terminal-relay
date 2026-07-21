import XCTest
@testable import TerminalRelay

final class SSHCommandBuilderTests: XCTestCase {
    func testConfigurationBuildsSSHArgumentsInRequiredOrder() {
        let server = makeServer(
            port: 2_222,
            identityFile: "~/Keys/agent key",
            workingDirectory: "/srv/terminal relay"
        )

        let configuration = SSHCommandBuilder.configuration(for: server, kind: .codex)

        XCTAssertEqual(configuration.executable, "/usr/bin/ssh")
        XCTAssertEqual(
            configuration.arguments,
            [
                "-tt",
                "-o", "ServerAliveInterval=30",
                "-o", "ServerAliveCountMax=3",
                "-p", "2222",
                "-i", ("~/Keys/agent key" as NSString).expandingTildeInPath,
                "miguel@example.com",
                "exec \"${SHELL:-/bin/sh}\" -lic 'cd -- '\"'\"'/srv/terminal relay'\"'\"' && exec codex --resume'"
            ]
        )
    }

    func testConfigurationOmitsBlankIdentityFile() {
        let server = makeServer(identityFile: "  \n ", workingDirectory: "")

        let configuration = SSHCommandBuilder.configuration(for: server, kind: .claude)

        XCTAssertFalse(configuration.arguments.contains("-i"))
        XCTAssertEqual(configuration.arguments.suffix(2), [
            "miguel@example.com",
            "exec \"${SHELL:-/bin/sh}\" -lic 'exec claude'"
        ])
    }

    func testDefaultPortDoesNotOverrideSSHConfig() {
        let server = makeServer(port: 22)

        let configuration = SSHCommandBuilder.configuration(for: server, kind: .codex)

        XCTAssertFalse(configuration.arguments.contains("-p"))
    }

    func testRemoteCommandQuotesApostrophesInWorkingDirectory() {
        let server = makeServer(
            workingDirectory: "/srv/Miguel's agents",
            codexCommand: "  codex --resume  "
        )

        let command = SSHCommandBuilder.remoteCommand(for: server, kind: .codex)
        let quotedDirectory = SSHCommandBuilder.shellQuote("/srv/Miguel's agents")
        let payload = "cd -- \(quotedDirectory) && exec codex --resume"

        XCTAssertEqual(
            command,
            "exec \"${SHELL:-/bin/sh}\" -lic \(SSHCommandBuilder.shellQuote(payload))"
        )
    }

    func testShellQuoteProtectsSingleQuotes() {
        XCTAssertEqual(SSHCommandBuilder.shellQuote("plain text"), "'plain text'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote("it's safe"), "'it'\"'\"'s safe'")
        XCTAssertEqual(SSHCommandBuilder.shellQuote(""), "''")
    }

    private func makeServer(
        port: Int = 22,
        identityFile: String = "",
        workingDirectory: String = "/srv/agents",
        codexCommand: String = "codex --resume"
    ) -> ServerProfile {
        ServerProfile(
            name: "Production",
            host: "example.com",
            port: port,
            username: "miguel",
            identityFile: identityFile,
            workingDirectory: workingDirectory,
            codexCommand: codexCommand,
            claudeCommand: "claude"
        )
    }
}
