import AppKit
import SwiftUI
import XCTest
@testable import TerminalRelay

@MainActor
final class MacConversationTableViewTests: XCTestCase {
    private static var retainedWindows: [NSWindow] = []
    private struct Row: MacConversationTableRow {
        let id: String
        let contentRevision: UInt64
        var reuseIdentifier: String { "test.row" }
    }

    private struct ProjectedRow: MacConversationTableRow {
        let id: String
        let mutationSourceID: String
        let contentRevision: UInt64
        var reuseIdentifier: String { "test.projected-row" }
    }

    func testMountedRowsDependOnViewportNotHistorySize() throws {
        let hundred = mount(rowCount: 100)
        let hundredMounted = mountedRowCount(in: hundred.table)
        let hundredVisible = visibleRowCount(in: hundred.table)
        XCTAssertGreaterThan(hundredMounted, 0)
        XCTAssertLessThanOrEqual(hundredMounted, hundredVisible + 12)

        let thousand = mount(rowCount: 1_000)
        let thousandMounted = mountedRowCount(in: thousand.table)
        let thousandVisible = visibleRowCount(in: thousand.table)
        XCTAssertGreaterThan(thousandMounted, 0)
        XCTAssertLessThanOrEqual(thousandMounted, thousandVisible + 12)
        XCTAssertLessThanOrEqual(abs(thousandMounted - hundredMounted), 2)
    }

    func testVisibleChangeConfiguresOneRowAndOffscreenChangeConfiguresNone() {
        var rows = makeRows(count: 1_000)
        let mounted = mount(rows: rows)

        MacConversationTableDiagnostics.reset()
        rows[rows.count - 1] = Row(
            id: rows[rows.count - 1].id,
            contentRevision: 2
        )
        mounted.hosting.rootView = table(rows: rows)
        settle(mounted.hosting)
        var diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.rowConfigurations, 1)
        XCTAssertEqual(diagnostics.explicitReconfigurations, 1)
        XCTAssertEqual(diagnostics.ordinaryMountConfigurations, 0)

        MacConversationTableDiagnostics.reset()
        rows[0] = Row(id: rows[0].id, contentRevision: 2)
        mounted.hosting.rootView = table(rows: rows)
        settle(mounted.hosting)
        diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.rowConfigurations, 0)
        XCTAssertEqual(diagnostics.explicitReconfigurations, 0)
    }

    func testPlainScrollingDoesNotReloadOrTouchOffscreenTranscriptRows() {
        let mounted = mount(rowCount: 1_000)
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }

        MacConversationTableDiagnostics.reset()
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 240)
        let requestedOrigin = scrollView.contentView.constrainBoundsRect(proposed).origin
        scrollView.contentView.setBoundsOrigin(requestedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.explicitReconfigurations, 0)
        XCTAssertEqual(diagnostics.heightInvalidationPasses, 0)
        XCTAssertEqual(diagnostics.scrollOriginCorrections, 0)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            requestedOrigin.y,
            accuracy: 0.01,
            "Queued cell-mount work must not rewrite a user scroll position"
        )
        XCTAssertLessThanOrEqual(
            diagnostics.rowConfigurations,
            visibleRowCount(in: mounted.table) + 12
        )
        XCTAssertEqual(diagnostics.measuredRows, diagnostics.rowConfigurations)
        XCTAssertLessThan(diagnostics.rowConfigurations, mounted.table.numberOfRows)
    }

    func testContentMutationDuringLiveScrollDoesNotCorrectClipOrigin() {
        var rows = makeRows(count: 1_000)
        let mounted = mount(rows: rows)
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 240)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(visible.location, NSNotFound)
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        defer {
            NotificationCenter.default.post(
                name: NSScrollView.didEndLiveScrollNotification,
                object: scrollView
            )
        }
        let userOwnedOrigin = scrollView.contentView.bounds.origin
        MacConversationTableDiagnostics.reset()
        rows[visible.location] = Row(
            id: rows[visible.location].id,
            contentRevision: 2
        )
        mounted.hosting.rootView = table(rows: rows)
        settle(mounted.hosting)

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.explicitReconfigurations, 1)
        XCTAssertEqual(diagnostics.heightInvalidationPasses, 0)
        XCTAssertEqual(diagnostics.scrollOriginCorrections, 0)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            userOwnedOrigin.y,
            accuracy: 0.01,
            "Streaming mutations must not fight live or momentum scrolling"
        )
    }

    func testLiveScrollNotificationsReportViewportOwnership() {
        var ownershipChanges: [Bool] = []
        let mounted = mount(
            rows: makeRows(count: 200),
            onLiveScrollingChange: { ownershipChanges.append($0) }
        )
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        XCTAssertEqual(ownershipChanges, [true, false])
    }

    func testNearBottomPublicationWaitsUntilLiveScrollEnds() {
        var nearBottomChanges: [Bool] = []
        let mounted = mount(
            rows: makeRows(count: 200),
            onNearBottomChange: { nearBottomChanges.append($0) }
        )
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 600)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)

        XCTAssertTrue(
            nearBottomChanges.isEmpty,
            "A live gesture must not publish transcript-wide threshold state"
        )

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        XCTAssertEqual(nearBottomChanges, [false])
    }

    func testLogicalItemMutationReconfiguresItsVisibleProjectedRow() {
        var rows = (0..<200).map {
            ProjectedRow(
                id: "projected-\($0):segment:0",
                mutationSourceID: "item-\($0)",
                contentRevision: 1
            )
        }
        // The final two rows are two independently virtualized segments of
        // the same logical transcript item. The logical mutation hint must
        // discover the changed tail projection without rebuilding its stable
        // prefix tile.
        rows[rows.count - 2] = ProjectedRow(
            id: rows[rows.count - 2].id,
            mutationSourceID: rows[rows.count - 1].mutationSourceID,
            contentRevision: 1
        )
        let mounted = mountProjected(rows: rows)

        MacConversationTableDiagnostics.reset()
        rows[rows.count - 1] = ProjectedRow(
            id: rows[rows.count - 1].id,
            mutationSourceID: rows[rows.count - 1].mutationSourceID,
            contentRevision: 2
        )
        var mutation = TranscriptMutation.empty
        mutation.revision = 1
        mutation.changedIDs = [rows[rows.count - 1].mutationSourceID]
        mounted.hosting.rootView = projectedTable(
            rows: rows,
            transcriptMutation: mutation
        )
        settle(mounted.hosting)

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.explicitReconfigurations, 1)
        XCTAssertEqual(diagnostics.ordinaryMountConfigurations, 0)
        XCTAssertEqual(diagnostics.heightInvalidationPasses, 1)
    }

    func testPrependPreservesFirstVisibleRowPixelAnchor() {
        let original = makeRows(count: 200)
        let mounted = mount(rows: original)
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 600)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        settle(mounted.hosting)

        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(visible.location, NSNotFound)
        let rowID = original[visible.location].id
        let offset = mounted.table.rect(ofRow: visible.location).minY
            - scrollView.contentView.bounds.minY

        let prepended = (0..<100).map {
            Row(id: "older-\($0)", contentRevision: 1)
        } + original
        mounted.hosting.rootView = table(rows: prepended)
        settle(mounted.hosting)

        let newIndex = prepended.firstIndex(where: { $0.id == rowID })!
        let newOffset = mounted.table.rect(ofRow: newIndex).minY
            - scrollView.contentView.bounds.minY
        XCTAssertEqual(newOffset, offset, accuracy: 1)
    }

    func testPinnedInsertRemainsAtBottom() {
        var rows = makeRows(count: 200)
        let mounted = mount(rows: rows)
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }
        rows.append(Row(id: "new-tail", contentRevision: 1))
        mounted.hosting.rootView = table(rows: rows)
        settle(mounted.hosting)

        let proposed = NSRect(
            x: scrollView.contentView.bounds.minX,
            y: mounted.table.frame.height,
            width: scrollView.contentView.bounds.width,
            height: scrollView.contentView.bounds.height
        )
        let maximum = scrollView.contentView.constrainBoundsRect(proposed).minY
        XCTAssertEqual(
            scrollView.contentView.bounds.minY,
            maximum,
            accuracy: 2
        )
    }

    func testKeyboardMovementAfterPinnedMutationCancelsDelayedCorrection() {
        var rows = makeRows(count: 200)
        let mounted = mount(rows: rows)
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }

        rows.append(Row(id: "new-tail", contentRevision: 1))
        mounted.hosting.rootView = table(rows: rows)
        mounted.hosting.needsLayout = true
        mounted.hosting.layoutSubtreeIfNeeded()

        var userOwned = scrollView.contentView.bounds
        userOwned.origin.y = max(0, userOwned.origin.y - 240)
        let userOwnedOrigin = scrollView.contentView
            .constrainBoundsRect(userOwned)
            .origin
        scrollView.contentView.setBoundsOrigin(userOwnedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        settle(mounted.hosting)

        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            userOwnedOrigin.y,
            accuracy: 0.01,
            "A delayed pinned correction must not overwrite newer keyboard or scrollbar movement"
        )
    }

    func testStyleChangeReconfiguresOnlyVisibleRowsWithoutReload() {
        let rows = makeRows(count: 1_000)
        let mounted = mount(rows: rows)

        MacConversationTableDiagnostics.reset()
        mounted.hosting.rootView = table(rows: rows, styleRevision: 1)
        settle(mounted.hosting)

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertGreaterThan(diagnostics.rowConfigurations, 0)
        XCTAssertEqual(
            diagnostics.explicitReconfigurations,
            diagnostics.rowConfigurations
        )
        XCTAssertEqual(diagnostics.heightInvalidationPasses, 1)
        XCTAssertLessThanOrEqual(
            diagnostics.rowConfigurations,
            visibleRowCount(in: mounted.table) + 12
        )
    }

    private func makeRows(count: Int) -> [Row] {
        (0..<count).map {
            Row(id: "row-\($0)", contentRevision: 1)
        }
    }

    private func table(
        rows: [Row],
        styleRevision: Int = 0,
        onNearBottomChange: @escaping (Bool) -> Void = { _ in },
        onLiveScrollingChange: @escaping (Bool) -> Void = { _ in }
    ) -> MacConversationTableView<Row> {
        MacConversationTableView(
            rows: rows,
            snapshotGeneration: "generation",
            styleRevision: styleRevision,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: onNearBottomChange,
            onLiveScrollingChange: onLiveScrollingChange,
            onAnchoredChange: { _ in },
            makeRow: { row in
                AnyView(
                    Text(row.id)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 56,
                            maxHeight: 56,
                            alignment: .leading
                        )
                )
            }
        )
    }

    private func projectedTable(
        rows: [ProjectedRow],
        transcriptMutation: TranscriptMutation? = nil
    ) -> MacConversationTableView<ProjectedRow> {
        MacConversationTableView(
            rows: rows,
            snapshotGeneration: "generation",
            transcriptMutation: transcriptMutation,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
            makeRow: { row in
                AnyView(
                    Text("\(row.id):\(row.contentRevision)")
                        .frame(
                            maxWidth: .infinity,
                            minHeight: 56,
                            maxHeight: 56,
                            alignment: .leading
                        )
                )
            }
        )
    }

    private func mount(rowCount: Int) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<Row>>,
        table: NSTableView
    ) {
        mount(rows: makeRows(count: rowCount))
    }

    private func mount(
        rows: [Row],
        onNearBottomChange: @escaping (Bool) -> Void = { _ in },
        onLiveScrollingChange: @escaping (Bool) -> Void = { _ in }
    ) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<Row>>,
        table: NSTableView
    ) {
        let hosting = NSHostingView(
            rootView: table(
                rows: rows,
                onNearBottomChange: onNearBottomChange,
                onLiveScrollingChange: onLiveScrollingChange
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        settle(hosting)
        let tableView = descendant(of: hosting, type: NSTableView.self)!
        return (window, hosting, tableView)
    }

    private func mountProjected(rows: [ProjectedRow]) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<ProjectedRow>>,
        table: NSTableView
    ) {
        let hosting = NSHostingView(rootView: projectedTable(rows: rows))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        settle(hosting)
        let tableView = descendant(of: hosting, type: NSTableView.self)!
        return (window, hosting, tableView)
    }

    private func settle(_ hosting: NSView) {
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        // AppKit publishes the document-range update after the host layout;
        // drain that callback so anchor assertions observe the same completed
        // layout transaction as an on-screen run loop.
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        hosting.layoutSubtreeIfNeeded()
    }

    private func descendant<T: NSView>(of root: NSView, type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, type: type) { return match }
        }
        return nil
    }

    private func visibleRowCount(in table: NSTableView) -> Int {
        guard let scrollView = table.enclosingScrollView else { return 0 }
        let range = table.rows(in: scrollView.contentView.bounds)
        return range.location == NSNotFound ? 0 : range.length
    }

    private func mountedRowCount(in table: NSTableView) -> Int {
        (0..<table.numberOfRows).reduce(into: 0) { count, row in
            if table.view(atColumn: 0, row: row, makeIfNecessary: false) != nil {
                count += 1
            }
        }
    }
}
