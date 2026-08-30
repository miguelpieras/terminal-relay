import XCTest
@testable import TerminalRelay

final class ToolGroupingTests: XCTestCase {
    private func tool(
        id: String,
        kind: ToolActivityKind = .shell,
        title: String = "Bash",
        status: ToolActivityStatus = .completed,
        input: String? = nil,
        exitCode: Int? = nil
    ) -> ConversationItem {
        .tool(ToolActivity(
            id: id,
            turnID: "turn",
            kind: kind,
            title: title,
            status: status,
            input: input,
            output: nil,
            errorMessage: nil,
            durationMilliseconds: nil,
            exitCode: exitCode,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        ))
    }

    private func message(id: String) -> ConversationItem {
        .message(ChatMessage(id: id, turnID: "turn", role: .assistant, text: "Hello"))
    }

    // MARK: Grouping

    func testConsecutiveToolsFormOneGroupAndSingletonsPassThrough() {
        let entries = TranscriptEntry.entries(of: [
            message(id: "m1"),
            tool(id: "t1"),
            tool(id: "t2"),
            tool(id: "t3"),
            message(id: "m2"),
            tool(id: "t4"),
        ])
        XCTAssertEqual(entries.count, 4)
        guard case .toolGroup(let group) = entries[1] else {
            return XCTFail("Expected a tool group, got \(entries[1])")
        }
        XCTAssertEqual(group.items.map(\.id), ["t1", "t2", "t3"])
        guard case .item(let single) = entries[3] else {
            return XCTFail("Expected a singleton tool, got \(entries[3])")
        }
        XCTAssertEqual(single.id, "t4")
    }

    func testGroupIdentityIsStableWhileStreamingAppendsMembers() {
        let initial = TranscriptEntry.entries(of: [
            tool(id: "t1"),
            tool(id: "t2"),
        ])
        let grown = TranscriptEntry.entries(of: [
            tool(id: "t1"),
            tool(id: "t2"),
            tool(id: "t3", status: .running),
        ])
        XCTAssertEqual(initial.first?.id, "toolgroup:t1")
        XCTAssertEqual(grown.first?.id, "toolgroup:t1")
    }

    func testWindowCutThroughToolRunKeepsOriginalGroupIdentity() throws {
        var items = (1...151).map { tool(id: "t\($0)") }

        func windowGroup(in items: [ConversationItem]) throws -> ToolGroup {
            let start = items.count - 150
            let identity = TranscriptEntry.leadingToolIdentityItemID(
                in: items,
                visibleStartIndex: start
            )
            let entry = try XCTUnwrap(TranscriptEntry.entries(
                of: items[start...],
                minimumGroupSize: 1,
                leadingToolIdentityItemID: identity
            ).first)
            return try XCTUnwrap({
                guard case .toolGroup(let group) = entry else { return nil }
                return group
            }(), "Expected a tool group")
        }

        let firstWindow = try windowGroup(in: items)
        XCTAssertEqual(firstWindow.items.first?.id, "t2")
        XCTAssertEqual(firstWindow.id, "toolgroup:t1")
        XCTAssertTrue(firstWindow.hasHiddenLeadingMembers)
        XCTAssertEqual(
            firstWindow.memberPresentation(
                itemID: "t2",
                isExplicitlyExpanded: false
            ),
            ToolGroupMemberPresentation(
                isExpanded: false,
                showsCompactLine: true
            )
        )

        items.append(tool(id: "t152", status: .running))
        let shiftedWindow = try windowGroup(in: items)
        XCTAssertEqual(shiftedWindow.items.first?.id, "t3")
        XCTAssertEqual(shiftedWindow.id, firstWindow.id)
        XCTAssertEqual(
            shiftedWindow.memberPresentation(
                itemID: "t3",
                isExplicitlyExpanded: false
            ),
            ToolGroupMemberPresentation(
                isExpanded: false,
                showsCompactLine: true
            )
        )
    }

    func testWindowContinuationWithOneVisibleMemberIsNotASingleton() throws {
        let group = ToolGroup(
            items: [tool(id: "t2")],
            identityItemID: "t1"
        )

        XCTAssertEqual(group.id, "toolgroup:t1")
        XCTAssertTrue(group.hasHiddenLeadingMembers)
        XCTAssertFalse(group.isStandaloneSingleton)
        XCTAssertEqual(group.leadItemID, "t1")
        XCTAssertEqual(
            group.memberPresentation(
                itemID: "t2",
                isExplicitlyExpanded: false
            ),
            ToolGroupMemberPresentation(
                isExpanded: false,
                showsCompactLine: true
            )
        )
    }

    func testBrowsingFreezesBoundedWindowUntilReturningToLatest() {
        var items = (1...151).map { tool(id: "t\($0)") }
        let tail = ConversationTranscriptWindow.visibleItems(
            in: items,
            firstVisibleItemID: nil,
            lastVisibleItemID: nil,
            limit: 150
        )
        XCTAssertEqual(tail.first?.id, "t2")

        let browsingAnchor = ConversationTranscriptWindow.anchor(
            isNearBottom: false,
            current: ConversationTranscriptWindow.Anchor(
                firstItemID: nil,
                lastItemID: nil
            ),
            visibleItems: tail
        )
        XCTAssertEqual(browsingAnchor.firstItemID, "t2")
        XCTAssertEqual(browsingAnchor.lastItemID, "t151")

        items.append(tool(id: "t152", status: .running))
        let pinned = ConversationTranscriptWindow.visibleItems(
            in: items,
            firstVisibleItemID: browsingAnchor.firstItemID,
            lastVisibleItemID: browsingAnchor.lastItemID,
            limit: 150
        )
        XCTAssertEqual(pinned.first?.id, "t2")
        XCTAssertEqual(pinned.last?.id, "t151")
        XCTAssertEqual(pinned.count, 150)

        items.append(contentsOf: (153...10_152).map {
            tool(id: "t\($0)", status: .running)
        })
        let heavilyBacklogged = ConversationTranscriptWindow.visibleItems(
            in: items,
            firstVisibleItemID: browsingAnchor.firstItemID,
            lastVisibleItemID: browsingAnchor.lastItemID,
            limit: 150
        )
        XCTAssertEqual(heavilyBacklogged.first?.id, "t2")
        XCTAssertEqual(heavilyBacklogged.last?.id, "t151")
        XCTAssertEqual(heavilyBacklogged.count, 150)

        let latestAnchor = ConversationTranscriptWindow.anchor(
            isNearBottom: true,
            current: browsingAnchor,
            visibleItems: heavilyBacklogged
        )
        XCTAssertNil(latestAnchor.firstItemID)
        XCTAssertNil(latestAnchor.lastItemID)
        XCTAssertEqual(
            ConversationTranscriptWindow.visibleItems(
                in: items,
                firstVisibleItemID: latestAnchor.firstItemID,
                lastVisibleItemID: latestAnchor.lastItemID,
                limit: 150
            ).first?.id,
            "t10003"
        )
    }

    func testFirstOnlyWindowFallbackRemainsBounded() {
        let items = (1...10_151).map { tool(id: "t\($0)") }
        let visible = ConversationTranscriptWindow.visibleItems(
            in: items,
            firstVisibleItemID: "t2",
            lastVisibleItemID: nil,
            limit: 150
        )

        XCTAssertEqual(visible.first?.id, "t2")
        XCTAssertEqual(visible.last?.id, "t151")
        XCTAssertEqual(visible.count, 150)
    }

    func testWindowIdentitySkipsHiddenReasoningLikeProductionGrouping() {
        let items: [ConversationItem] = [
            tool(id: "t1"),
            .reasoning(ChatReasoning(
                id: "empty-reasoning",
                turnID: nil,
                text: " \n\t",
                isStreaming: true,
                occurredAt: nil
            )),
            tool(id: "t2"),
        ]

        XCTAssertEqual(
            TranscriptEntry.leadingToolIdentityItemID(
                in: items,
                visibleStartIndex: 1
            ),
            "t1"
        )
    }

    func testStableProductionGroupingStartsWithSingletonWrapper() {
        let initial = TranscriptEntry.entries(
            of: [tool(
                id: "t1",
                status: .running,
                input: #"{"command":"swift test"}"#
            )],
            minimumGroupSize: 1
        )
        let grown = TranscriptEntry.entries(
            of: [
                tool(id: "t1", input: #"{"command":"swift test"}"#),
                tool(id: "t2", status: .running),
            ],
            minimumGroupSize: 1
        )
        let settled = TranscriptEntry.entries(
            of: [tool(id: "t1"), tool(id: "t2")],
            minimumGroupSize: 1
        )

        guard case .toolGroup(let singleton) = initial.first,
              case .toolGroup(let group) = grown.first,
              case .toolGroup(let settledGroup) = settled.first else {
            return XCTFail("Expected stable tool-group wrappers")
        }
        XCTAssertEqual(singleton.id, group.id)
        XCTAssertEqual(singleton.headerModel(isExpanded: false).id,
                       group.headerModel(isExpanded: false).id)
        XCTAssertEqual(group.headerModel(isExpanded: false).id,
                       settledGroup.headerModel(isExpanded: false).id)
        XCTAssertFalse(settledGroup.headerModel(isExpanded: false).isRunning)
        XCTAssertEqual(settledGroup.headerModel(isExpanded: false).summary,
                       "Ran commands")
        XCTAssertEqual(singleton.headerModel(isExpanded: false).summary,
                       "Running swift test")
        XCTAssertTrue(singleton.headerModel(isExpanded: false).isRunning)
        XCTAssertEqual(group.headerModel(isExpanded: false).summary,
                       "Running a command")
        XCTAssertTrue(group.headerModel(isExpanded: false).isRunning)

        let neutral = singleton.headerModel(
            isExpanded: false,
            activeToolID: nil
        )
        XCTAssertFalse(neutral.isRunning)
        XCTAssertEqual(neutral.summary, "Ran swift test")
        XCTAssertFalse(
            group.headerModel(
                isExpanded: false,
                activeToolID: "not-in-this-group"
            ).isRunning
        )
    }

    func testExpandedLeadPresentationSurvivesSingletonToMultiTransition() throws {
        let first = tool(id: "t1", input: #"{"command":"swift test"}"#)
        let second = tool(id: "t2", status: .running)
        guard case .toolGroup(let singleton) = TranscriptEntry.entries(
            of: [first],
            minimumGroupSize: 1
        ).first,
        case .toolGroup(let grown) = TranscriptEntry.entries(
            of: [first, second],
            minimumGroupSize: 1
        ).first else {
            return XCTFail("Expected stable tool-group wrappers")
        }

        let singletonLead = singleton.memberPresentation(
            itemID: "t1",
            isExplicitlyExpanded: false
        )
        let grownLead = grown.memberPresentation(
            itemID: "t1",
            isExplicitlyExpanded: false
        )
        XCTAssertEqual(singletonLead, grownLead)
        XCTAssertTrue(grownLead.isExpanded)
        XCTAssertFalse(grownLead.showsCompactLine)

        let appended = grown.memberPresentation(
            itemID: "t2",
            isExplicitlyExpanded: false
        )
        XCTAssertFalse(appended.isExpanded)
        XCTAssertTrue(appended.showsCompactLine)
    }

    func testNonToolItemSplitsRuns() {
        let entries = TranscriptEntry.entries(of: [
            tool(id: "t1"),
            tool(id: "t2"),
            message(id: "m1"),
            tool(id: "t3"),
            tool(id: "t4"),
        ])
        XCTAssertEqual(
            entries.map(\.id),
            ["toolgroup:t1", "m1", "toolgroup:t3"]
        )
    }

    func testRunningToolDrivesTheLiveLine() {
        guard case .toolGroup(let group) = TranscriptEntry.entries(of: [
            tool(id: "t1"),
            tool(id: "t2", status: .running, input: #"{"command":"npm test"}"#),
        ]).first else {
            return XCTFail("Expected a group")
        }
        XCTAssertEqual(group.runningTool?.id, "t2")
        XCTAssertEqual(group.runningTool?.compactHeadline, "Running npm test")

        guard case .toolGroup(let settled) = TranscriptEntry.entries(of: [
            tool(id: "t1"),
            tool(id: "t2"),
        ]).first else {
            return XCTFail("Expected a group")
        }
        XCTAssertNil(settled.runningTool)
    }

    // MARK: Summary

    func testSummaryOrdersKindsByFirstAppearanceWithCounts() {
        guard case .toolGroup(let group) = TranscriptEntry.entries(of: [
            tool(id: "t1", kind: .fileRead, title: "Read"),
            tool(id: "t2", kind: .fileRead, title: "Read"),
            tool(id: "t3", kind: .shell, title: "Bash"),
            tool(id: "t4", kind: .search, title: "Grep"),
        ]).first else {
            return XCTFail("Expected a group")
        }
        XCTAssertEqual(group.summaryText, "Read files, ran a command, searched")
        XCTAssertEqual(group.dominantKind, .fileRead)
    }

    func testFailureSurfacesOnTheGroup() {
        guard case .toolGroup(let group) = TranscriptEntry.entries(of: [
            tool(id: "t1"),
            tool(id: "t2", status: .failed, exitCode: 1),
        ]).first else {
            return XCTFail("Expected a group")
        }
        XCTAssertTrue(group.hasFailure)
    }

    // MARK: Compact headlines

    func testShellHeadlineUsesTheCommand() {
        let running = ToolActivity.fixture(
            kind: .shell,
            title: "Bash",
            status: .running,
            input: #"{"command":"git status","description":"Show status"}"#
        )
        XCTAssertEqual(running.compactHeadline, "Running git status")
        var finished = running
        finished.status = .completed
        XCTAssertEqual(finished.compactHeadline, "Ran git status")
    }

    func testFileHeadlinesUseTheBasename() {
        let read = ToolActivity.fixture(
            kind: .fileRead,
            title: "Read",
            status: .completed,
            input: #"{"file_path":"/home/example-user/app/checkout.js"}"#
        )
        XCTAssertEqual(read.compactHeadline, "Read checkout.js")
        let edit = ToolActivity.fixture(
            kind: .edit,
            title: "Edit",
            status: .running,
            input: #"{"file_path":"/tmp/notes.md"}"#
        )
        XCTAssertEqual(edit.compactHeadline, "Editing notes.md")
    }

    func testSearchHeadlineUsesThePattern() {
        let search = ToolActivity.fixture(
            kind: .search,
            title: "Grep",
            status: .completed,
            input: #"{"pattern":"employeeType","path":"api"}"#
        )
        XCTAssertEqual(search.compactHeadline, "Searched for employeeType")
    }

    func testNonJSONInputIsTheDetailItself() {
        let codex = ToolActivity.fixture(
            kind: .shell,
            title: "Command",
            status: .completed,
            input: "ls -la\n"
        )
        XCTAssertEqual(codex.compactHeadline, "Ran ls -la")
    }

    func testTitleFallbacksWhenInputCarriesNothing() {
        let bare = ToolActivity.fixture(kind: .shell, title: "Bash", status: .completed, input: nil)
        XCTAssertEqual(bare.compactHeadline, "Ran a command")
        let mcp = ToolActivity.fixture(
            kind: .mcp,
            title: "mcp__browser__navigate",
            status: .completed,
            input: nil
        )
        XCTAssertEqual(mcp.compactHeadline, "mcp__browser__navigate")
    }

    func testHeadlineFlattensAndBoundsLongCommands() {
        let long = ToolActivity.fixture(
            kind: .shell,
            title: "Bash",
            status: .completed,
            input: "{\"command\":\"echo \(String(repeating: "a", count: 400))\"}"
        )
        XCTAssertFalse(long.compactHeadline.contains("\n"))
        XCTAssertLessThanOrEqual(long.compactHeadline.count, 210)
    }

    func testOutcomeOnlySurfacesFailures() {
        var tool = ToolActivity.fixture(kind: .shell, title: "Bash", status: .completed, input: nil)
        XCTAssertNil(tool.compactOutcome)
        tool.status = .failed
        tool.exitCode = 2
        XCTAssertEqual(tool.compactOutcome, "exit 2")
        tool.exitCode = nil
        XCTAssertEqual(tool.compactOutcome, "failed")
        tool.status = .cancelled
        XCTAssertEqual(tool.compactOutcome, "cancelled")
    }

    // MARK: First-row projection carries the precomputed headline

    func testFirstTitleTileCarriesTheBoundedCompactLine() throws {
        guard case .tool(let value) = tool(
            id: "t1",
            title: "Bash",
            input: #"{"command":"git status"}"#
        ) else {
            return XCTFail("Expected a tool")
        }
        let first = try XCTUnwrap(
            TranscriptRowProjection.makeFirstRow(item: .tool(value))?.row
        )
        XCTAssertEqual(first.compactLine, "Ran git status")
        guard case .tool(let displayed) = first.displayItem else {
            return XCTFail("Expected a tool display item")
        }
        // The tile itself never carries the raw input; the headline is
        // precomputed so tiles stay bounded.
        XCTAssertNil(displayed.input)

        // Both projection paths must produce the identical first row.
        let all = TranscriptRowProjection.makeRows(item: .tool(value))
        XCTAssertEqual(all.first, first)
    }

    func testCompactLineStaysBoundedForGraphemeBombInputs() throws {
        let bomb = "a" + String(repeating: "\u{301}", count: 50_000)
        let tool = ToolActivity.fixture(
            kind: .shell,
            title: "Bash",
            status: .completed,
            input: "{\"command\":\"\(bomb)\"}"
        )
        XCTAssertLessThanOrEqual(tool.compactHeadline.utf8.count, 1024)
    }
}

private extension ToolActivity {
    static func fixture(
        kind: ToolActivityKind,
        title: String,
        status: ToolActivityStatus,
        input: String?
    ) -> ToolActivity {
        ToolActivity(
            id: "tool",
            turnID: "turn",
            kind: kind,
            title: title,
            status: status,
            input: input,
            output: nil,
            errorMessage: nil,
            durationMilliseconds: nil,
            exitCode: nil,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        )
    }
}
