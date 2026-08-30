import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TerminalRelay

private let adversarialNotificationCenter = Foundation.NotificationCenter.default

/// Cross-cutting regressions for the transcript behavior that is most likely
/// to look correct in a snapshot while still blinking or changing shape under
/// real streaming and scrolling.
@MainActor
final class AdversarialConversationRegressionTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []

    private struct DeferredRow: MacConversationTableRow {
        let id: String
        let contentRevision: UInt64
        let isNative: Bool

        var reuseIdentifier: String { "adversarial.deferred" }

        func nativeTextPresentation(
            dynamicTypeSize: DynamicTypeSize,
            colorScheme: ColorScheme
        ) -> MacConversationNativeTextPresentation? {
            guard isNative else { return nil }
            return MacConversationNativeTextPresentation(
                fallbackString: "raw **markdown**",
                contentInsets: NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8),
                deferredAttributedString: {
                    MacConversationNativeTextPresentation.DeferredArtifact {
                        NSAttributedString(
                            string: "Rich markdown",
                            attributes: [
                                .font: NSFont.boldSystemFont(ofSize: 14),
                                .foregroundColor: NSColor.labelColor,
                            ]
                        )
                    }
                },
                usesFastPlainTextRenderer: true,
                promotesFastRendererWhenIdle: true
            )
        }
    }

    func testColdDeferredMarkdownRealizedDuringLiveScrollPromotesInPlaceAfterEnd() throws {
        let initial = DeferredRow(id: "cold-markdown", contentRevision: 1, isNative: false)
        let hosting = NSHostingView(rootView: deferredTable(row: initial))
        let window = mount(hosting, height: 300)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)

        adversarialNotificationCenter.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        let cold = DeferredRow(id: "cold-markdown", contentRevision: 2, isNative: true)
        hosting.rootView = deferredTable(row: cold)
        settle(hosting)

        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        let scrollingSurface = try XCTUnwrap(descendant(
            of: cell,
            type: MacConversationScrollTextView.self
        ))
        XCTAssertFalse(scrollingSurface.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(
            scrollingSurface.attributedString.string,
            "raw **markdown**"
        )

        MacConversationTableDiagnostics.reset()
        adversarialNotificationCenter.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()

        let promotedCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let rich = try XCTUnwrap(descendant(of: promotedCell, type: NSTextView.self))
        XCTAssertTrue(cell === promotedCell, "Promotion must not replace the mounted row.")
        XCTAssertTrue(scrollingSurface.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(rich.isHidden)
        XCTAssertEqual(rich.string, "Rich markdown")
        XCTAssertEqual(MacConversationTableDiagnostics.snapshot().reloadDataCalls, 0)
        XCTAssertEqual(MacConversationTableDiagnostics.snapshot().targetedRowReloads, 0)
        _ = window
    }

    func testToolRunIdentityIsStableFromFirstToolThroughGrouping() throws {
        let first = tool(id: "tool-1", status: .running)
        let second = tool(id: "tool-2", status: .running)
        let singleton = try XCTUnwrap(
            TranscriptEntry.entries(of: [first], minimumGroupSize: 1).first
        )
        let grown = try XCTUnwrap(
            TranscriptEntry.entries(
                of: [first, second],
                minimumGroupSize: 1
            ).first
        )

        XCTAssertEqual(
            singleton.id,
            grown.id,
            "A second tool must update the existing run instead of replacing its identity."
        )
        guard case .toolGroup(let initialGroup) = singleton,
              case .toolGroup(let grownGroup) = grown else {
            return XCTFail("Tool runs must use one stable container from their first member.")
        }
        XCTAssertEqual(initialGroup.items.map(\.id), ["tool-1"])
        XCTAssertEqual(grownGroup.items.map(\.id), ["tool-1", "tool-2"])
    }

    func testSecondRunningToolUpdatesOneStableHeaderWithoutMovingSpinner() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(#"{"command":"git status"}"#),
                ])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 400)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        XCTAssertEqual(table.numberOfRows, 1)
        let initialHeader = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )

        MacConversationTableDiagnostics.reset()
        try store.apply(
            ChatTestFixtures.event(
                "tool.completed",
                sequence: 2,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "title": .string("Command"),
                    "exitCode": .number(0),
                ])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 3,
                itemID: "tool-2",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("fileRead"),
                    "title": .string("Read"),
                    "status": .string("running"),
                    "input": .string(#"{"file_path":"/tmp/example.swift"}"#),
                ])
            )
        )
        settle(hosting)

        XCTAssertEqual(
            table.numberOfRows,
            1,
            "A new running member must update the existing spinner/header, not insert a live row."
        )
        let updatedHeader = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertTrue(initialHeader === updatedHeader)
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 0)
        _ = window
    }

    func testExpandedSingletonLeadDoesNotRedrawWhenSecondToolArrives() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(#"{"command":"swift test"}"#),
                ])
            )
        )
        store.toggleExpanded(itemID: "toolgroup:tool-1")
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 700)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        XCTAssertGreaterThan(
            table.numberOfRows,
            2,
            "The expanded singleton fixture must expose its lead body and stable trailing edge."
        )
        let initialRowCount = table.numberOfRows
        let leadIndexes = 1..<(initialRowCount - 1)
        let leadCells = try leadIndexes.map { index in
            try XCTUnwrap(
                table.view(atColumn: 0, row: index, makeIfNecessary: true)
            )
        }
        let leadRects = leadIndexes.map(table.rect(ofRow:))
        let trailingEdge = try XCTUnwrap(
            table.view(
                atColumn: 0,
                row: initialRowCount - 1,
                makeIfNecessary: true
            )
        )

        MacConversationTableDiagnostics.reset()
        MacConversationTableDiagnostics.watchConfigurations(for: "tool-1")
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 2,
                itemID: "tool-2",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("fileRead"),
                    "title": .string("Read"),
                    "status": .string("running"),
                    "input": .string(#"{"file_path":"/tmp/example.swift"}"#),
                ])
            )
        )
        settle(hosting)

        XCTAssertEqual(
            table.numberOfRows,
            initialRowCount + 1,
            "Growing the run must only append the new compact member row."
        )
        XCTAssertTrue(
            trailingEdge === table.view(
                atColumn: 0,
                row: table.numberOfRows - 1,
                makeIfNecessary: true
            ),
            "The stable trailing edge must move after the insertion without replacement."
        )
        for (offset, index) in leadIndexes.enumerated() {
            let current = try XCTUnwrap(
                table.view(atColumn: 0, row: index, makeIfNecessary: true)
            )
            XCTAssertTrue(
                leadCells[offset] === current,
                "Lead body row \(index) must retain its exact outer cell."
            )
            XCTAssertEqual(
                table.rect(ofRow: index),
                leadRects[offset],
                "Appending a member must not move or resize lead body row \(index)."
            )
        }
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 0)
        XCTAssertEqual(
            diagnostics.watchedSourceConfigurations,
            0,
            "The unchanged lead body must not be reconfigured or redrawn."
        )
        _ = window
    }

    func testTitlelessExpandedLeadUsesOnlyTheOuterGroupHeader() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "titleless-tool",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string(""),
                    "status": .string("running"),
                    "input": .string(#"{"command":"swift test"}"#),
                ])
            )
        )
        store.toggleExpanded(itemID: "toolgroup:titleless-tool")
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 700)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        XCTAssertEqual(
            table.numberOfRows,
            3,
            "A titleless singleton needs one outer header, one real input body, and the stable trailing edge."
        )
        let bodyCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        XCTAssertGreaterThan(
            table.rect(ofRow: 1).height,
            20,
            "The retained first input projection must render its body."
        )
        XCTAssertTrue(
            descendants(of: bodyCell, type: NSProgressIndicator.self).isEmpty,
            "The body must not repeat the running spinner already owned by the outer group header."
        )
        let bodyButtonLabels = descendants(of: bodyCell, type: NSButton.self)
            .compactMap { $0.accessibilityLabel() }
        XCTAssertFalse(
            bodyButtonLabels.contains { $0.hasSuffix(", expanded") },
            "The body must not repeat a compact disclosure header; labels: \(bodyButtonLabels)"
        )
        _ = window
    }

    func testExpandedToolOutputUpdatesBodyWithoutRedrawingGroupHeader() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 1,
                itemID: "streaming-tool",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(#"{"command":"swift test"}"#),
                ])
            )
        )
        store.toggleExpanded(itemID: "toolgroup:streaming-tool")
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 700)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let header = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let headerRect = table.rect(ofRow: 0)
        let initialRowCount = table.numberOfRows

        MacConversationTableDiagnostics.reset()
        MacConversationTableDiagnostics.watchConfigurations(
            for: "toolgroup:streaming-tool:header"
        )
        for (sequence, delta) in [(2, "first output"), (3, " and more")] {
            try store.apply(
                ChatTestFixtures.event(
                    "tool.updated",
                    sequence: Int64(sequence),
                    itemID: "streaming-tool",
                    turnID: "turn-1",
                    payload: .object([
                        "status": .string("running"),
                        "outputDelta": .string(delta),
                    ])
                )
            )
            settle(hosting)
            XCTAssertTrue(
                header === table.view(
                    atColumn: 0,
                    row: 0,
                    makeIfNecessary: true
                )
            )
            XCTAssertEqual(table.rect(ofRow: 0), headerRect)
        }
        XCTAssertGreaterThan(
            table.numberOfRows,
            initialRowCount,
            "Visible output must still be inserted and streamed below the stable header."
        )
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 0)
        XCTAssertEqual(
            diagnostics.watchedSourceConfigurations,
            0,
            "Body deltas must not reconfigure or redraw an unchanged group header."
        )
        _ = window
    }

    func testCompletedMarkdownTableRequestsHostedGridInsideStableNativeCell() throws {
        let item = ConversationItem.message(
            ChatMessage(
                id: "markdown-table",
                role: .assistant,
                text: "| Name | State |\n| --- | --- |\n| Relay | Running |",
                occurredAt: 1
            )
        )
        let projections = TranscriptRowProjection.makeRows(item: item)
        let rows = makeMacTranscriptRows(
            item: item,
            projections: projections,
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )
        let contentRows = rows.dropLast()
        XCTAssertFalse(contentRows.isEmpty)
        for row in contentRows {
            let presentation = try XCTUnwrap(
                row.nativeTextPresentation(
                    dynamicTypeSize: .large,
                    colorScheme: .light
                )
            )
            XCTAssertTrue(
                presentation.prefersHostedRenderer,
                "Tables must request the hosted grid without replacing the outer native cell."
            )
            XCTAssertEqual(
                presentation.accessibilityLabel,
                "Scrollable table",
                "The native fallback must preserve a table-specific accessibility cue until the grid adopts."
            )
        }
    }

    func testPipeAndRuleFalsePositiveStaysOnNativeTextRenderer() throws {
        let source = "A | B\n---"
        XCTAssertTrue(
            MarkdownSafety.containsTableCandidate(source),
            "The fixture must exercise the deliberately cheap candidate detector."
        )
        XCTAssertTrue(
            MarkdownTableAccessibility.tables(in: source).isEmpty,
            "A pipe followed by a horizontal rule is not a Markdown table."
        )

        let item = ConversationItem.message(
            ChatMessage(
                id: "not-a-markdown-table",
                role: .assistant,
                text: source,
                occurredAt: 1
            )
        )
        let rows = makeMacTranscriptRows(
            item: item,
            projections: TranscriptRowProjection.makeRows(item: item),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )
        let row = try XCTUnwrap(rows.dropLast().first)
        let presentation = try XCTUnwrap(
            row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )
        )

        XCTAssertFalse(
            presentation.prefersHostedRenderer,
            "Only successfully parsed tables may replace native text with the hosted grid."
        )
        XCTAssertNil(presentation.accessibilityTableSource)
        XCTAssertNotEqual(presentation.accessibilityLabel, "Scrollable table")
    }

    func testAccessibilitySizeTableExposesRealContentThroughItsScroller() throws {
        let source = "| Name | State |\n| --- | --- |\n| AccessibilityRelay | ReadyForVoiceOver |"
        let message = ChatMessage(
            id: "accessibility-size-table",
            role: .assistant,
            text: source,
            isStreaming: false
        )
        let rows = transcriptRows(for: message, revision: 1)
        let hosting = NSHostingView(
            rootView: transcriptTable(rows: rows, revision: 1)
                .dynamicTypeSize(.accessibility1)
        )
        let window = mount(hosting, height: 700)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let cell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )

        let deadline = Date().addingTimeInterval(2)
        var nestedHost = descendant(of: cell, type: NSHostingView<AnyView>.self)
        var scroller = nestedHost.flatMap(horizontalTableScrollView(in:))
        var semanticGroup: NSObject?
        var reachableText: [String] = []
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            nestedHost = descendant(of: cell, type: NSHostingView<AnyView>.self)
            if let nestedHost {
                let objects = accessibilityTree(from: nestedHost)
                semanticGroup = objects.dropFirst().first {
                    accessibilityLabel(of: $0) == "Scrollable table"
                        && !accessibilityChildren(of: $0).isEmpty
                }
                scroller = horizontalTableScrollView(in: nestedHost)
                if let semanticGroup {
                    reachableText = accessibilitySubtree(from: semanticGroup)
                        .flatMap(accessibilityText(of:))
                }
            }
            if scroller != nil,
               reachableText.contains(where: {
                   $0.contains("AccessibilityRelay")
                       || $0.contains("ReadyForVoiceOver")
               }) {
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
        }

        let realScroller = try XCTUnwrap(
            scroller,
            "Accessibility text sizes must retain a real tagged table scroller."
        )
        let realGroup = try XCTUnwrap(
            semanticGroup,
            "The hosted table must expose a labeled accessibility entry point."
        )
        XCTAssertTrue(
            accessibilitySubtree(from: realGroup).contains { $0 === realScroller },
            "The semantic group must lead to the real scroller rather than the synthetic fallback table."
        )
        XCTAssertTrue(
            reachableText.contains(where: {
                $0.contains("AccessibilityRelay")
                    || $0.contains("ReadyForVoiceOver")
            }),
            "Real table cell content must be reachable at accessibility1; reachable text: \(reachableText)"
        )
        _ = window
    }

    func testStreamingTableCompletionAdoptsGridWithoutReplacingOuterCell() throws {
        let wideCell = String(repeating: "UnbreakableColumn", count: 16)
        let source = "| Name | State |\n| --- | --- |\n| \(wideCell) | Running |"
        var message = ChatMessage(
            id: "streaming-table",
            role: .assistant,
            text: source,
            isStreaming: true
        )
        var rows = transcriptRows(for: message, revision: 1)
        let hosting = NSHostingView(
            rootView: transcriptTable(rows: rows, revision: 1)
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let streamingCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertTrue(streamingCell.identifier?.rawValue.hasSuffix(".native") == true)
        XCTAssertNil(descendant(
            of: streamingCell,
            type: NSHostingView<AnyView>.self
        ))

        message.complete(text: nil)
        rows = transcriptRows(for: message, revision: 2)
        MacConversationTableDiagnostics.reset()
        hosting.rootView = transcriptTable(rows: rows, revision: 2)

        // Completed tables are now sanitized into a populated Markdown source
        // synchronously. Still sample the promotion boundary: from the first
        // instant its host exists, either the old exact native surface must
        // remain visible or the real table scroll view must already be mounted.
        // Hiding the fallback first produces a one-frame empty row.
        var observedHostedTransition = false
        var observedBlankTransition = false
        let nonblankDeadline = Date().addingTimeInterval(0.5)
        while Date() < nonblankDeadline {
            hosting.layoutSubtreeIfNeeded()
            guard let currentCell = table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            ) else {
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
                continue
            }
            if let host = descendant(
                of: currentCell,
                type: NSHostingView<AnyView>.self
            ) {
                observedHostedTransition = true
                let tableIsReady = horizontalTableScrollView(in: host) != nil
                if !tableIsReady,
                   !hasVisibleExactTextSurface(in: currentCell, text: source) {
                    observedBlankTransition = true
                    break
                }
                if tableIsReady { break }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(
            observedHostedTransition,
            "Completion must adopt its table host during the observation window."
        )
        XCTAssertFalse(
            observedBlankTransition,
            "Table promotion must never hide exact text before the semantic grid is ready."
        )
        settle(hosting)

        let completedCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let nestedHost = try XCTUnwrap(descendant(
            of: completedCell,
            type: NSHostingView<AnyView>.self
        ))
        let semanticDeadline = Date().addingTimeInterval(2)
        var nestedScrollView = horizontalTableScrollView(in: nestedHost)
        var accessibilityObjects = accessibilityTree(from: nestedHost)
        var semanticElement = accessibilityObjects.dropFirst().first {
            accessibilityLabel(of: $0) == "Scrollable table"
                && !accessibilityChildren(of: $0).isEmpty
        }
        while (nestedScrollView == nil || semanticElement == nil),
              Date() < semanticDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            hosting.layoutSubtreeIfNeeded()
            nestedScrollView = horizontalTableScrollView(in: nestedHost)
            accessibilityObjects = accessibilityTree(from: nestedHost)
            semanticElement = accessibilityObjects.dropFirst().first {
                accessibilityLabel(of: $0) == "Scrollable table"
                    && !accessibilityChildren(of: $0).isEmpty
            }
        }
        XCTAssertTrue(
            streamingCell === completedCell,
            "Table completion must adopt the semantic renderer inside the existing cell."
        )
        XCTAssertTrue(completedCell.identifier?.rawValue.hasSuffix(".native") == true)
        XCTAssertNotNil(
            nestedScrollView,
            "The semantic table renderer must retain its horizontal scrolling surface."
        )
        XCTAssertNotNil(
            semanticElement,
            "The table and its descendants must be reachable through accessibilityChildren only; labels: \(accessibilityObjects.compactMap { accessibilityLabel(of: $0) })"
        )
        let horizontalScrollView = try XCTUnwrap(nestedScrollView)
        XCTAssertTrue(
            accessibilityObjects.contains { $0 === horizontalScrollView },
            "The accessibility group must lead to the real hosted table scroller, not a synthetic placeholder."
        )
        let clipView = horizontalScrollView.contentView
        let initialOrigin = clipView.bounds.origin.x
        var proposed = clipView.bounds
        proposed.origin.x = horizontalScrollView.documentView?.bounds.maxX ?? 0
        let constrained = clipView.constrainBoundsRect(proposed).origin
        XCTAssertGreaterThan(
            abs(constrained.x - initialOrigin),
            0.5,
            "The table fixture must genuinely overflow horizontally."
        )
        clipView.scroll(to: constrained)
        horizontalScrollView.reflectScrolledClipView(clipView)
        horizontalScrollView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            abs(clipView.bounds.origin.x - initialOrigin),
            0.5,
            "The real hosted table scroll view must accept horizontal movement."
        )
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 0)
        _ = window
    }

    func testCompletedMultiTileMarkdownTableKeepsEveryTileSemantic() throws {
        let header = "| Name | State | Detail |\n| --- | --- | --- |\n"
        let body = (0..<80).map { index in
            "| Relay \(index) | Running | semantic row \(index) |\n"
        }.joined()
        let message = ChatMessage(
            id: "multi-tile-table",
            role: .assistant,
            text: header + body,
            isStreaming: false
        )
        let projected = TranscriptRowProjection.makeRows(
            item: .message(message)
        )
        XCTAssertGreaterThan(
            projected.count,
            2,
            "The fixture must cross multiple bounded transcript tiles."
        )
        XCTAssertEqual(
            projected.map(\.sourceText).joined(),
            header + body,
            "Synthetic continuation headers must never replace or duplicate authoritative body bytes."
        )
        let renderedTileTexts = projected.compactMap { projection -> String? in
            guard case .message(let displayedMessage) = projection.displayItem,
                  let displayedContent = displayedMessage.contents.first else {
                XCTFail("Expected a projected message tile.")
                return nil
            }
            XCTAssertLessThanOrEqual(
                displayedContent.text.utf8.count,
                TranscriptRowProjection.maximumDisplayBytes,
                "A semantic continuation must remain a bounded renderer input."
            )
            XCTAssertTrue(
                MarkdownSafety.containsTableCandidate(displayedContent.text),
                "Each independently parsed continuation needs a header and delimiter."
            )
            return displayedContent.text
        }
        XCTAssertEqual(renderedTileTexts.count, projected.count)
        let expectedSemanticCells = try renderedTileTexts.map { tile -> String in
            let bodyLine = try XCTUnwrap(
                tile.split(separator: "\n").first {
                    $0.contains("| Relay ")
                },
                "Every continuation fixture tile must contain a body row."
            )
            return try XCTUnwrap(
                bodyLine.split(separator: "|").first {
                    $0.trimmingCharacters(in: .whitespaces)
                        .hasPrefix("Relay ")
                }
            )
            .trimmingCharacters(in: .whitespaces)
        }
        let allRenderedTiles = renderedTileTexts.joined(separator: "\n")
        for index in 0..<80 {
            XCTAssertEqual(
                allRenderedTiles.components(
                    separatedBy: "| Relay \(index) | Running | semantic row \(index) |"
                ).count - 1,
                1,
                "Body row \(index) must appear in exactly one hosted tile."
            )
        }
        let rows = transcriptRows(for: message, revision: 1)
        let contentRows = Array(rows.dropLast())
        XCTAssertEqual(contentRows.count, projected.count)
        for (index, row) in contentRows.enumerated() {
            let presentation = try XCTUnwrap(row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ))
            XCTAssertTrue(
                presentation.prefersHostedRenderer,
                "Table continuation tile \(index) must not fall back to flattened native text."
            )
            XCTAssertEqual(presentation.accessibilityLabel, "Scrollable table")
        }

        let hosting = NSHostingView(
            rootView: transcriptTable(rows: rows, revision: 1)
        )
        let window = mount(hosting, height: 4_000)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let semanticDeadline = Date().addingTimeInterval(5)
        var nonSemanticIndexes = Array(contentRows.indices)
        while !nonSemanticIndexes.isEmpty, Date() < semanticDeadline {
            hosting.layoutSubtreeIfNeeded()
            nonSemanticIndexes = contentRows.indices.filter { index in
                guard let cell = table.view(
                    atColumn: 0,
                    row: index,
                    makeIfNecessary: true
                ),
                let host = descendant(
                    of: cell,
                    type: NSHostingView<AnyView>.self
                ),
                let scrollView = horizontalTableScrollView(in: host) else {
                    return true
                }
                let objects = accessibilityTree(from: host)
                let semanticGroup = objects.dropFirst().first {
                    accessibilityLabel(of: $0) == "Scrollable table"
                        && !accessibilityChildren(of: $0).isEmpty
                }
                let realScrollerIsReachable = objects.contains {
                    $0 === scrollView
                }
                let expectedCellIsReachable = semanticGroup.map {
                    accessibilitySubtree(from: $0)
                        .flatMap(accessibilityText(of:))
                        .contains(expectedSemanticCells[index])
                } ?? false
                return semanticGroup == nil
                    || !realScrollerIsReachable
                    || !expectedCellIsReachable
            }
            if !nonSemanticIndexes.isEmpty {
                RunLoop.main.run(
                    until: Date().addingTimeInterval(1.0 / 60.0)
                )
            }
        }
        XCTAssertTrue(
            nonSemanticIndexes.isEmpty,
            "Every continuation tile must expose its real scroller and unique body cell through accessibility; missing indexes: \(nonSemanticIndexes)"
        )
        _ = window
    }

    func testEveryTableInOneTileOwnsAReachableAccessibilityGroup() throws {
        let source = """
        ```text
        short code block
        ```

        | First | Value |
        | --- | --- |
        | A | one |

        | Second | Value |
        | --- | --- |
        | B | two |
        """
        let message = ChatMessage(
            id: "two-tables-one-tile",
            role: .assistant,
            text: source,
            isStreaming: false
        )
        let projections = TranscriptRowProjection.makeRows(
            item: .message(message)
        )
        XCTAssertEqual(
            projections.count,
            1,
            "The fixture must exercise two tables inside the same hosted tile."
        )
        let rows = transcriptRows(for: message, revision: 1)
        let hosting = NSHostingView(
            rootView: transcriptTable(rows: rows, revision: 1)
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let cell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )

        let deadline = Date().addingTimeInterval(2)
        var host = descendant(of: cell, type: NSHostingView<AnyView>.self)
        var tableScrollViews = host.map {
            descendants(of: $0, type: NSScrollView.self).filter {
                $0.documentView != nil
            }
        } ?? []
        while (host == nil || tableScrollViews.count < 2), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            hosting.layoutSubtreeIfNeeded()
            host = descendant(of: cell, type: NSHostingView<AnyView>.self)
            tableScrollViews = host.map {
                descendants(of: $0, type: NSScrollView.self).filter {
                    $0.documentView != nil
                }
            } ?? []
        }
        XCTAssertEqual(
            tableScrollViews.count,
            2,
            "macOS code wraps; only the two tables should mount horizontal scroll views."
        )
        XCTAssertTrue(
            tableScrollViews.allSatisfy {
                $0.accessibilityIdentifier()
                    == MarkdownTableAccessibility.scrollViewIdentifier
            },
            "Each actual table scroller must carry the AppKit marker; identifiers: \(tableScrollViews.map { $0.accessibilityIdentifier() as Any })"
        )
        let nestedHost = try XCTUnwrap(host)
        let objects = accessibilityTree(from: nestedHost)
        let semanticGroups = objects.filter {
            accessibilityLabel(of: $0) == "Scrollable table"
                && !accessibilityChildren(of: $0).isEmpty
        }
        XCTAssertGreaterThanOrEqual(
            semanticGroups.count,
            tableScrollViews.count,
            "Each table needs its own labeled accessibility entry point."
        )
        for scrollView in tableScrollViews {
            XCTAssertTrue(
                semanticGroups.contains { group in
                    accessibilitySubtree(from: group).contains {
                        $0 === scrollView
                    }
                },
                "Every real table scroller must be reachable from its labeled accessibility group."
            )
        }
        _ = window
    }

    func testCompletedEmptyReasoningDoesNotLeaveAVisualRow() throws {
        let items: [ConversationItem] = [
            .reasoning(
                ChatReasoning(
                    id: "empty-reasoning",
                    turnID: "turn-1",
                    text: "  \n\t",
                    isStreaming: false,
                    occurredAt: 1
                )
            ),
            .message(
                ChatMessage(
                    id: "visible-message",
                    turnID: "turn-1",
                    role: .assistant,
                    text: "Visible response",
                    occurredAt: 2
                )
            ),
        ]
        let store = ConversationStore(
            state: ConversationState(
                snapshotGeneration: ChatTestFixtures.generation,
                lastAppliedSequence: 1,
                items: items,
                connectionState: .streaming
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))

        XCTAssertEqual(
            table.numberOfRows,
            2,
            "Only the visible message and its footer should remain."
        )
        for index in 0..<table.numberOfRows {
            let cell = try XCTUnwrap(
                table.view(atColumn: 0, row: index, makeIfNecessary: true)
            )
            XCTAssertNotEqual(
                cell.accessibilityIdentifier(),
                "conversation.item.empty-reasoning"
            )
        }
        _ = window
    }

    func testEmptyReasoningNeverBlinksAndKeepsStableWorkingShell() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        let whitespaceShell = String(repeating: " ", count: 1_025)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                turnID: "turn-1",
                payload: .object(["status": .string("streaming")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "reasoning.started",
                sequence: 2,
                itemID: "empty-reasoning-gap",
                turnID: "turn-1",
                payload: .object(["text": .string(whitespaceShell)])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        hosting.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        XCTAssertEqual(
            table.numberOfRows,
            1,
            "Empty reasoning must not create a transient Thinking row."
        )
        let stableShell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            descendants(of: hosting, type: NSProgressIndicator.self).filter {
                !$0.isHiddenOrHasHiddenAncestor
            }.count,
            0,
            "The cosmetic Working label must stay hidden during a short phase gap."
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            descendants(of: hosting, type: NSProgressIndicator.self).filter {
                !$0.isHiddenOrHasHiddenAncestor
            }.count,
            1,
            "A stable half-second gap should reveal one Working spinner."
        )
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            ),
            "Revealing Working must update the same fixed-height shell."
        )

        try store.apply(
            ChatTestFixtures.event(
                "reasoning.completed",
                sequence: 3,
                itemID: "empty-reasoning-gap",
                turnID: "turn-1",
                payload: .object(["text": .string(whitespaceShell)])
            )
        )
        settle(hosting)
        XCTAssertEqual(
            table.numberOfRows,
            1,
            "Completing empty reasoning must leave the same turn activity shell."
        )
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            )
        )
        XCTAssertFalse(
            descendants(of: hosting, type: NSView.self).contains {
                $0.accessibilityIdentifier() == "conversation.empty-state"
            },
            "The empty state must not cover a still-running pending turn."
        )

        try store.apply(
            ChatTestFixtures.event(
                "turn.completed",
                sequence: 4,
                turnID: "turn-1"
            )
        )
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            ),
            "Turn completion must not flash away a newly revealed Working cue."
        )
        XCTAssertEqual(visibleProgressIndicators(in: hosting).count, 1)
        XCTAssertFalse(
            descendants(of: hosting, type: NSView.self).contains {
                $0.accessibilityIdentifier() == "conversation.empty-state"
            },
            "The minimum dwell must finish before the empty overlay replaces the shell."
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(
            descendants(of: hosting, type: NSView.self).contains {
                $0.accessibilityIdentifier() == "conversation.empty-state"
            },
            "Once the turn settles with no visible content, the real empty state may appear."
        )
        _ = window
    }

    func testNewerCommandExclusivelyOwnsActivityWithoutMovingTailShell() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                turnID: "turn-1",
                payload: .object(["status": .string("streaming")])
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "reasoning.started",
                sequence: 2,
                itemID: "reasoning-1",
                turnID: "turn-1",
                payload: .object(["text": .string("Considering options")])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        XCTAssertEqual(table.numberOfRows, 2)
        let stableShell = try XCTUnwrap(
            table.view(atColumn: 0, row: 1, makeIfNecessary: true)
        )
        let reasoningCell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let thinkingMarkers = activityMarkers(
            in: reasoningCell,
            kind: "thinking"
        )
        XCTAssertEqual(
            thinkingMarkers.count,
            1,
            "The mounted reasoning row must expose exactly one concrete Thinking owner."
        )
        XCTAssertEqual(thinkingMarkers.first?.accessibilityLabel(), "Thinking…")
        XCTAssertEqual(
            visibleProgressIndicators(in: hosting).count,
            0,
            "Thinking uses its single reasoning owner; the Working spinner stays hidden."
        )

        MacConversationTableDiagnostics.reset()
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 3,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(#"{"command":"git status"}"#),
                ])
            )
        )
        settle(hosting)

        XCTAssertEqual(table.numberOfRows, 3)
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 2,
                makeIfNecessary: true
            ),
            "Starting a command must not replace the fixed turn activity shell."
        )
        XCTAssertEqual(
            visibleProgressIndicators(in: hosting).count,
            1,
            "Only the command owner may expose an active spinner."
        )
        XCTAssertTrue(
            activityMarkers(in: reasoningCell, kind: "thinking").isEmpty,
            "The older reasoning row must become neutral when the command owns activity."
        )
        let executingMarkers = activityMarkers(
            in: hosting,
            kind: "executing"
        )
        XCTAssertEqual(executingMarkers.count, 1)
        XCTAssertTrue(
            executingMarkers[0].accessibilityLabel()?.contains("git status") == true
        )
        XCTAssertEqual(
            MacConversationTableDiagnostics.snapshot().reloadDataCalls,
            0
        )
        _ = window
    }

    func testWorkingHandsOffToCommandWithoutOverlapOrShellReplacement() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                turnID: "turn-1",
                payload: .object(["status": .string("streaming")])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let stableShell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        let stableShellHeight = table.rect(ofRow: 0).height
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)

        MacConversationTableDiagnostics.reset()
        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 2,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(#"{"command":"git status"}"#),
                ])
            )
        )
        settle(hosting)

        XCTAssertEqual(table.numberOfRows, 2)
        let toolHeader = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 1,
                makeIfNecessary: true
            )
        )
        XCTAssertEqual(
            table.rect(ofRow: 1).height,
            stableShellHeight,
            accuracy: 0.5,
            "Inserting the command must not resize the stable activity shell."
        )
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)
        XCTAssertEqual(visibleProgressIndicators(in: toolHeader).count, 0)

        let deadline = Date().addingTimeInterval(0.55)
        while Date() < deadline {
            hosting.layoutSubtreeIfNeeded()
            let workingOwners = visibleProgressIndicators(in: stableShell).count
            let commandOwners = visibleProgressIndicators(in: toolHeader).count
            XCTAssertLessThanOrEqual(
                workingOwners + commandOwners,
                1,
                "Working and the command must never render active together."
            )
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 0)
        XCTAssertEqual(visibleProgressIndicators(in: toolHeader).count, 1)
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 1,
                makeIfNecessary: true
            ),
            "The fixed shell must survive the ownership handoff in place."
        )
        XCTAssertEqual(
            table.rect(ofRow: 1).height,
            stableShellHeight,
            accuracy: 0.5
        )
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 0)
        _ = window
    }

    func testNewTurnCancelsPendingWorkingHideWithoutBlinking() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                turnID: "turn-1",
                payload: .object(["status": .string("streaming")])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let stableShell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)

        try store.apply(
            ChatTestFixtures.event(
                "turn.completed",
                sequence: 2,
                turnID: "turn-1"
            )
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 3,
                turnID: "turn-2",
                payload: .object(["status": .string("streaming")])
            )
        )
        settle(hosting)

        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            )
        )
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.55))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            ),
            "A succeeding turn must cancel the old hide task without replacing the shell."
        )
        _ = window
    }

    func testNewTurnRestartsPendingWorkingRevealDelay() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                payload: .object(["status": .string("streaming")])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let stableShell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.24))
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.completed",
                sequence: 2
            )
        )
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 3,
                payload: .object(["status": .string("streaming")])
            )
        )
        settle(hosting)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        hosting.layoutSubtreeIfNeeded()

        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: 0,
                makeIfNecessary: true
            )
        )
        XCTAssertEqual(
            visibleProgressIndicators(in: stableShell).count,
            0,
            "Turn one’s timer must not reveal Working before turn two earns its own delay."
        )

        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)
        _ = window
    }

    func testOverdueRevealCannotFlashWorkingAfterTurnCompletion() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                turnID: "turn-1",
                payload: .object(["status": .string("streaming")])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)

        // Hold the main actor until the reveal task is overdue, then mutate the
        // authoritative state before queued SwiftUI work can run. A timer that
        // validates only its captured generation would now flash Working.
        Thread.sleep(forTimeInterval: 0.58)
        try store.apply(
            ChatTestFixtures.event(
                "turn.completed",
                sequence: 2,
                turnID: "turn-1"
            )
        )
        settle(hosting)

        XCTAssertEqual(visibleProgressIndicators(in: hosting).count, 0)
        XCTAssertTrue(activityMarkers(in: hosting, kind: "working").isEmpty)
        XCTAssertTrue(
            descendants(of: hosting, type: NSView.self).contains {
                $0.accessibilityIdentifier() == "conversation.empty-state"
            },
            "An overdue cosmetic reveal must yield to the completed turn."
        )
        _ = window
    }

    func testOverdueHideCannotBlinkWorkingAfterCommandCompletes() throws {
        let store = ConversationStore(streamingPublishNanoseconds: 0)
        try store.apply(
            ChatTestFixtures.event(
                "turn.started",
                sequence: 1,
                turnID: "turn-1",
                payload: .object(["status": .string("streaming")])
            )
        )
        let coordinator = ConversationCoordinator(
            store: store,
            transport: ChatFixtureTransport(),
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                isReadOnly: true,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = mount(hosting, height: 500)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let stableShell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)

        try store.apply(
            ChatTestFixtures.event(
                "tool.started",
                sequence: 2,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "kind": .string("shell"),
                    "title": .string("Command"),
                    "status": .string("running"),
                    "input": .string(#"{"command":"git status"}"#),
                ])
            )
        )
        settle(hosting)
        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)

        // The pending hide is now overdue but cannot run while this test owns
        // the main actor. Completing the command restores Working before the
        // queued callback resumes, so that stale callback must abort.
        Thread.sleep(forTimeInterval: 0.5)
        try store.apply(
            ChatTestFixtures.event(
                "tool.completed",
                sequence: 3,
                itemID: "tool-1",
                turnID: "turn-1",
                payload: .object([
                    "title": .string("Command"),
                    "exitCode": .number(0),
                ])
            )
        )
        settle(hosting)

        XCTAssertEqual(visibleProgressIndicators(in: stableShell).count, 1)
        XCTAssertEqual(activityMarkers(in: hosting, kind: "working").count, 1)
        XCTAssertTrue(activityMarkers(in: hosting, kind: "executing").isEmpty)
        XCTAssertTrue(
            stableShell === table.view(
                atColumn: 0,
                row: table.numberOfRows - 1,
                makeIfNecessary: true
            ),
            "The same fixed activity shell must survive the overdue handoff."
        )
        _ = window
    }

    func testRepeatedStreamingBoundaryGrowthNeverReloadsTableOrReplacesSealedCells() throws {
        var message = ChatMessage(
            id: "adversarial-stream",
            role: .assistant,
            text: String(repeating: "a", count: 300),
            isStreaming: true
        )
        var revision: UInt64 = 1
        var rows = transcriptRows(for: message, revision: revision)
        let hosting = NSHostingView(
            rootView: transcriptTable(rows: rows, revision: revision)
        )
        let window = mount(hosting, height: 1_800)
        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let originalTable = table
        var mountedByID = mountedCellsByID(rows: rows, in: table)

        MacConversationTableDiagnostics.reset()
        for _ in 0..<18 {
            let previouslySealedIDs = Set(rows.dropLast().map(\.id))
            message.append(String(repeating: "z", count: 173))
            revision &+= 1
            rows = transcriptRows(for: message, revision: revision)
            hosting.rootView = transcriptTable(rows: rows, revision: revision)
            settle(hosting)

            XCTAssertTrue(originalTable === descendant(of: hosting, type: NSTableView.self))
            let updated = mountedCellsByID(rows: rows, in: table)
            for id in previouslySealedIDs {
                XCTAssertTrue(
                    mountedByID[id] === updated[id],
                    "Sealed row \(id) was replaced by a later tail delta."
                )
            }
            mountedByID = updated
        }

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 0)
        XCTAssertLessThanOrEqual(
            diagnostics.rowConfigurations,
            40,
            "Tail growth should configure only the changing tail and inserted rows."
        )
        _ = window
    }

    private func deferredTable(
        row: DeferredRow
    ) -> MacConversationTableView<DeferredRow> {
        MacConversationTableView(
            sections: [
                MacConversationTableSection(
                    id: "cold-section",
                    revision: row.contentRevision,
                    rows: [row]
                ),
            ],
            snapshotGeneration: "generation",
            usesLiveScrollStandIns: false,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
            makeRow: { row, _, _ in AnyView(Text(row.id)) }
        )
    }

    private func transcriptTable(
        rows: [MacTranscriptRow],
        revision: UInt64
    ) -> MacConversationTableView<MacTranscriptRow> {
        MacConversationTableView(
            sections: [
                MacConversationTableSection(
                    id: "adversarial-stream",
                    revision: revision,
                    rows: rows
                ),
            ],
            snapshotGeneration: "generation",
            usesLiveScrollStandIns: false,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
            makeRow: { row, _, _ in
                guard case .item(let projection, _, _, _, _) = row,
                      case .message(let message) = projection.displayItem,
                      let content = message.contents.first else {
                    return AnyView(EmptyView())
                }
                return AnyView(
                    RichMarkdownView(
                        text: content.text,
                        exactFallbackText: projection.sourceText,
                        isStreaming: message.isStreaming
                    )
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 16)
                )
            }
        )
    }

    private func transcriptRows(
        for message: ChatMessage,
        revision: UInt64
    ) -> [MacTranscriptRow] {
        let item = ConversationItem.message(message)
        return makeMacTranscriptRows(
            item: item,
            projections: TranscriptRowProjection.makeRows(item: item),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: revision
        )
    }

    private func mountedCellsByID(
        rows: [MacTranscriptRow],
        in table: NSTableView
    ) -> [String: NSView] {
        Dictionary(uniqueKeysWithValues: rows.enumerated().compactMap { index, row in
            table.view(atColumn: 0, row: index, makeIfNecessary: true).map {
                (row.id, $0)
            }
        })
    }

    private func tool(id: String, status: ToolActivityStatus) -> ConversationItem {
        .tool(
            ToolActivity(
                id: id,
                turnID: "turn-1",
                kind: .shell,
                title: "Command",
                status: status,
                input: #"{"command":"git status"}"#,
                output: nil,
                errorMessage: nil,
                durationMilliseconds: nil,
                exitCode: nil,
                occurredAt: nil,
                isTruncated: false,
                originalByteCount: nil
            )
        )
    }

    @discardableResult
    private func mount<Content: View>(
        _ hosting: NSHostingView<Content>,
        height: CGFloat
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        settle(hosting)
        return window
    }

    private func settle(_ view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        view.layoutSubtreeIfNeeded()
    }

    private func descendant<T: NSView>(of root: NSView, type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, type: type) { return match }
        }
        return nil
    }

    private func descendants<T: NSView>(
        of root: NSView,
        type: T.Type
    ) -> [T] {
        var result: [T] = []
        if let match = root as? T { result.append(match) }
        for child in root.subviews {
            result.append(contentsOf: descendants(of: child, type: type))
        }
        return result
    }

    private func visibleProgressIndicators(in root: NSView) -> [NSProgressIndicator] {
        descendants(of: root, type: NSProgressIndicator.self).filter {
            !$0.isHiddenOrHasHiddenAncestor
        }
    }

    private func activityMarkers(in root: NSView, kind: String) -> [NSView] {
        descendants(of: root, type: NSView.self).filter { view in
            !view.isHiddenOrHasHiddenAncestor
                && view.accessibilityIdentifier()
                    == "conversation.activity.\(kind)"
        }
    }

    private func horizontalTableScrollView(in root: NSView) -> NSScrollView? {
        descendants(of: root, type: NSScrollView.self).first {
            $0.documentView != nil
        }
    }

    private func hasVisibleExactTextSurface(
        in root: NSView,
        text: String
    ) -> Bool {
        if descendants(
            of: root,
            type: MacConversationScrollTextView.self
        ).contains(where: {
            !$0.isHiddenOrHasHiddenAncestor
                && $0.attributedString.string == text
        }) {
            return true
        }
        if descendants(of: root, type: NSTextField.self).contains(where: {
            !$0.isHiddenOrHasHiddenAncestor
                && $0.attributedStringValue.string == text
        }) {
            return true
        }
        return descendants(of: root, type: NSTextView.self).contains(where: {
            !$0.isHiddenOrHasHiddenAncestor && $0.string == text
        })
    }

    /// Walks only the accessibility graph. Deliberately does not inspect raw
    /// NSView subviews: finding a visually mounted SwiftUI scroller is not proof
    /// that VoiceOver can reach it through the hosting bridge.
    private func accessibilityTree(from root: NSView) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        return accessibilityTree(
            from: root as NSObject,
            visited: &visited
        )
    }

    private func accessibilitySubtree(from root: NSObject) -> [NSObject] {
        var visited: Set<ObjectIdentifier> = []
        return accessibilityTree(from: root, visited: &visited)
    }

    private func accessibilityTree(
        from object: NSObject,
        visited: inout Set<ObjectIdentifier>
    ) -> [NSObject] {
        let identifier = ObjectIdentifier(object)
        guard visited.insert(identifier).inserted else { return [] }
        var result = [object]
        for child in accessibilityChildren(of: object) {
            result.append(contentsOf: accessibilityTree(
                from: child,
                visited: &visited
            ))
        }
        return result
    }

    private func accessibilityChildren(of object: NSObject) -> [NSObject] {
        let children: [Any]
        if let view = object as? NSView {
            children = view.accessibilityChildren() ?? []
        } else if let element = object as? NSAccessibilityElement {
            children = element.accessibilityChildren() ?? []
        } else {
            children = []
        }
        return children.compactMap { $0 as? NSObject }
    }

    private func accessibilityLabel(of object: NSObject) -> String? {
        if let view = object as? NSView {
            return view.accessibilityLabel()
        }
        if let element = object as? NSAccessibilityElement {
            return element.accessibilityLabel()
        }
        return nil
    }

    private func accessibilityText(of object: NSObject) -> [String] {
        let label = accessibilityLabel(of: object)
        let value: Any?
        if let view = object as? NSView {
            value = view.accessibilityValue()
        } else if let element = object as? NSAccessibilityElement {
            value = element.accessibilityValue()
        } else {
            value = nil
        }
        return [label, value as? String].compactMap { $0 }
    }
}
