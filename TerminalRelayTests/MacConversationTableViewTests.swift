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

        MacConversationTableDiagnostics.reset()
        rows[0] = Row(id: rows[0].id, contentRevision: 2)
        mounted.hosting.rootView = table(rows: rows)
        settle(mounted.hosting)
        diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.rowConfigurations, 0)
    }

    func testPlainScrollingDoesNotReloadOrTouchOffscreenTranscriptRows() {
        let mounted = mount(rowCount: 1_000)
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }

        MacConversationTableDiagnostics.reset()
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 240)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertLessThanOrEqual(
            diagnostics.rowConfigurations,
            visibleRowCount(in: mounted.table) + 12
        )
        XCTAssertEqual(diagnostics.measuredRows, diagnostics.rowConfigurations)
        XCTAssertLessThan(diagnostics.rowConfigurations, mounted.table.numberOfRows)
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

    func testStyleChangeReconfiguresOnlyVisibleRowsWithoutReload() {
        let rows = makeRows(count: 1_000)
        let mounted = mount(rows: rows)

        MacConversationTableDiagnostics.reset()
        mounted.hosting.rootView = table(rows: rows, styleRevision: 1)
        settle(mounted.hosting)

        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertGreaterThan(diagnostics.rowConfigurations, 0)
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
        styleRevision: Int = 0
    ) -> MacConversationTableView<Row> {
        MacConversationTableView(
            rows: rows,
            snapshotGeneration: "generation",
            styleRevision: styleRevision,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
            makeRow: { row in
                AnyView(
                    Text(row.id)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
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

    private func mount(rows: [Row]) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<Row>>,
        table: NSTableView
    ) {
        let hosting = NSHostingView(rootView: table(rows: rows))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
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
