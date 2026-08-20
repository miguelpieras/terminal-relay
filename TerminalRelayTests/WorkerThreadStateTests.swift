import XCTest
@testable import TerminalRelay

final class WorkerThreadStateTests: XCTestCase {
    private let threadID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    private let accountID = ProviderAccountID(
        UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    )
    private let instanceToken =
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

    func testCatalogParsesVersionedMetadataAndCapabilities() throws {
        let response = try WorkerThreadProtocol.parse(
            """
            login banner
            \(WorkerThreadProtocol.marker)
            {"threads":[{"provider":"codex","accountID":"\(accountID.rawValue)","threadID":"\(threadID)","title":"Fix pagination","updatedAt":1700000000,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}}],"nextCursor":"page-2"}
            """,
            repositoryName: "terminal-relay",
            expectedAccountID: accountID
        )

        XCTAssertEqual(
            response,
            WorkerThreadResponse(
                threads: [
                    WorkerThreadSnapshot(
                        kind: .codex,
                        accountID: accountID,
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
            accountID: accountID,
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
            accountID: accountID,
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
        XCTAssertEqual(merged.threads[0].activityState, .relayActive)
        XCTAssertEqual(merged.threads[0].capabilities, WorkerThreadCapabilities.active)
    }

    func testIdenticalProviderThreadIDsRemainDistinctAcrossAccounts() {
        let secondAccountID = ProviderAccountID(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        )
        let first = WorkerThreadSnapshot(
            kind: .codex,
            accountID: accountID,
            repositoryName: "terminal-relay",
            threadID: threadID,
            title: "First",
            updatedAt: 1,
            isArchived: false,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .dormant
        )
        let second = WorkerThreadSnapshot(
            kind: .codex,
            accountID: secondAccountID,
            repositoryName: "terminal-relay",
            threadID: threadID,
            title: "Second",
            updatedAt: 2,
            isArchived: false,
            activeInstanceToken: nil,
            reportedWorking: nil,
            capabilities: .dormant
        )

        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set([first.id, second.id]).count, 2)
    }

    func testCatalogRejectsUnsafeOrAmbiguousRecordsAndLegacyWorkersRemainDetectable() {
        XCTAssertThrowsError(
            try WorkerThreadProtocol.parse(
                "\(WorkerThreadProtocol.marker)\n{\"threads\":[],\"nextCursor\":\"line\\nbreak\"}",
                repositoryName: "terminal-relay",
                expectedAccountID: accountID
            )
        ) { error in
            XCTAssertEqual(error as? WorkerThreadProtocolError, .invalidResponse)
        }
        XCTAssertThrowsError(
            try WorkerThreadProtocol.parse(
                "\(WorkerThreadProtocol.marker)\n{\"threads\":[{\"provider\":\"codex\",\"accountID\":\"\(accountID.rawValue)\",\"threadID\":\"\(threadID)\",\"title\":null,\"updatedAt\":1,\"archived\":false,\"activityState\":\"inactive\",\"activeInstanceToken\":null,\"isWorking\":null,\"capabilities\":{\"resume\":true,\"rename\":true,\"archive\":true,\"unarchive\":true}},{\"provider\":\"codex\",\"accountID\":\"\(accountID.rawValue)\",\"threadID\":\"\(threadID)\",\"title\":null,\"updatedAt\":1,\"archived\":false,\"activityState\":\"inactive\",\"activeInstanceToken\":null,\"isWorking\":null,\"capabilities\":{\"resume\":true,\"rename\":true,\"archive\":true,\"unarchive\":true}}],\"nextCursor\":null}",
                repositoryName: "terminal-relay",
                expectedAccountID: accountID
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

    func testClaudeInactiveExternalAndUnknownRowsStayDistinct() throws {
        let externalID = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        let unknownID = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        let response = try WorkerThreadProtocol.parse(
            """
            \(WorkerThreadProtocol.marker)
            {"threads":[{"provider":"claude","accountID":"\(accountID.rawValue)","threadID":"\(threadID)","title":"Inactive","updatedAt":3,"archived":false,"activityState":"inactive","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":true,"rename":true,"archive":true,"unarchive":false}},{"provider":"claude","accountID":"\(accountID.rawValue)","threadID":"\(externalID)","title":"External","updatedAt":2,"archived":false,"activityState":"external-active","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":false,"rename":false,"archive":false,"unarchive":false}},{"provider":"claude","accountID":"\(accountID.rawValue)","threadID":"\(unknownID)","title":"Unknown archived","updatedAt":1,"archived":true,"activityState":"unknown","activeInstanceToken":null,"isWorking":null,"capabilities":{"resume":false,"rename":false,"archive":false,"unarchive":false}}],"nextCursor":null}
            """,
            repositoryName: "terminal-relay",
            expectedAccountID: accountID
        )

        XCTAssertEqual(response.threads.map(\.kind), [.claude, .claude, .claude])
        XCTAssertTrue(response.threads[0].capabilities.resume)
        XCTAssertTrue(response.threads[1].isActive)
        XCTAssertFalse(response.threads[1].isAttachable)
        XCTAssertEqual(response.threads[2].activityState, .unknown)
        XCTAssertTrue(response.threads[2].isArchived)
        XCTAssertFalse(response.threads[2].capabilities.archive)
    }
}
