import XCTest
@testable import TerminalRelay

final class WorkerThreadStateTests: XCTestCase {
    private let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let instanceToken =
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testCatalogParsesVersionedMetadataAndCapabilities() throws {
        let response = try WorkerThreadProtocol.parse(
            """
            login banner
            \(WorkerThreadProtocol.marker)
            {"threads":[{"provider":"codex","threadID":"\(threadID)","title":"Fix pagination","updatedAt":1700000000,"archived":false,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":"page-2"}
            """,
            repositoryName: "terminal-relay"
        )

        XCTAssertEqual(
            response,
            WorkerThreadResponse(
                threads: [
                    WorkerThreadSnapshot(
                        kind: .codex,
                        repositoryName: "terminal-relay",
                        threadID: threadID,
                        title: "Fix pagination",
                        updatedAt: 1_700_000_000,
                        isArchived: false,
                        activeInstanceToken: nil,
                        reportedWorking: nil,
                        capabilities: .dormantCodex
                    )
                ],
                nextCursor: "page-2"
            )
        )
    }

    func testLiveSessionsReplaceDormantRowsWithoutConflatingThreadAndInstanceIDs() {
        let dormant = WorkerThreadSnapshot(
            kind: .codex,
            repositoryName: "terminal-relay",
            threadID: threadID,
            title: "Dormant title",
            updatedAt: 10,
            isArchived: false,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .dormantCodex
        )
        let live = WorkerSessionSnapshot(
            kind: .codex,
            repositoryName: "terminal-relay",
            attachedClientCount: 2,
            instanceToken: instanceToken,
            title: "Live title",
            lastActivityAt: 20,
            reportedWorking: true,
            threadID: threadID
        )

        let merged = WorkerThreadResponse(
            threads: [dormant],
            nextCursor: nil
        ).merging(liveSessions: [live])

        XCTAssertEqual(merged.threads.count, 1)
        XCTAssertEqual(merged.threads[0].threadID, threadID)
        XCTAssertEqual(merged.threads[0].activeInstanceToken, instanceToken)
        XCTAssertEqual(merged.threads[0].title, "Live title")
        XCTAssertTrue(merged.threads[0].reportedWorking == true)
        XCTAssertEqual(merged.threads[0].capabilities, WorkerThreadCapabilities.active)
    }

    func testCatalogRejectsUnsafeOrAmbiguousRecordsAndLegacyWorkersRemainDetectable() {
        XCTAssertThrowsError(
            try WorkerThreadProtocol.parse(
                "\(WorkerThreadProtocol.marker)\n{\"threads\":[],\"nextCursor\":\"line\\nbreak\"}",
                repositoryName: "terminal-relay"
            )
        ) { error in
            XCTAssertEqual(error as? WorkerThreadProtocolError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try WorkerThreadProtocol.parse(
                "\(WorkerThreadProtocol.marker)\n{\"threads\":[{\"provider\":\"codex\",\"threadID\":\"\(threadID)\",\"title\":null,\"updatedAt\":1,\"archived\":false,\"capabilities\":{\"resume\":true,\"rename\":true,\"archive\":true,\"unarchive\":true}},{\"provider\":\"codex\",\"threadID\":\"\(threadID)\",\"title\":null,\"updatedAt\":1,\"archived\":false,\"capabilities\":{\"resume\":true,\"rename\":true,\"archive\":true,\"unarchive\":true}}],\"nextCursor\":null}",
                repositoryName: "terminal-relay"
            )
        ) { error in
            XCTAssertEqual(error as? WorkerThreadProtocolError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try WorkerThreadProtocol.parse(
                "\(WorkerSessionProtocol.marker)\n",
                repositoryName: "terminal-relay"
            )
        ) { error in
            XCTAssertEqual(error as? WorkerThreadProtocolError, .missingMarker)
        }
    }
}
