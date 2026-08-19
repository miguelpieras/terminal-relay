import AppKit
import QuartzCore
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

    private struct MixedRow: MacConversationTableRow {
        let id: String
        let contentRevision: UInt64
        let text: String
        let usesNativeText: Bool
        var nativeAccessibilityIdentifier: String? = nil
        var firstRowTopInsetAdjustment: CGFloat = 0
        var lastRowBottomInsetAdjustment: CGFloat = 0
        var maximumContentWidth: CGFloat? = 320
        var maximumTextWidth: CGFloat? = nil
        var hugsTextWidth = false
        var horizontalAlignment:
            MacConversationNativeTextPresentation.HorizontalAlignment = .fill
        var backgroundCornerRadius: CGFloat = 0
        var usesFastPlainTextRenderer = false
        var promotesFastRendererWhenIdle = false
        var usesLiveScrollText = false
        var linkURL: URL? = nil
        var mutationSourceIDOverride: String? = nil
        var selectionRoleLabelOverride: String? = nil

        var reuseIdentifier: String { "test.mixed-row" }
        var mutationSourceID: String { mutationSourceIDOverride ?? id }
        var selectionText: String? { text }
        var selectionRoleLabel: String? { selectionRoleLabelOverride }
        var selectionSectionID: String? { "mixed-section" }

        func nativeTextPresentation(
            dynamicTypeSize: DynamicTypeSize,
            colorScheme: ColorScheme
        ) -> MacConversationNativeTextPresentation? {
            guard usesNativeText else { return nil }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.labelColor,
            ]
            if let linkURL {
                attributes[.link] = linkURL
            }
            return MacConversationNativeTextPresentation(
                attributedString: NSAttributedString(
                    string: text,
                    attributes: attributes
                ),
                fallbackString: text,
                contentInsets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12),
                firstRowTopInsetAdjustment: firstRowTopInsetAdjustment,
                lastRowBottomInsetAdjustment: lastRowBottomInsetAdjustment,
                textContainerInset: NSSize(width: 2, height: 2),
                maximumContentWidth: maximumContentWidth,
                maximumTextWidth: maximumTextWidth,
                hugsTextWidth: hugsTextWidth,
                backgroundColor: NSColor.controlBackgroundColor,
                backgroundCornerRadius: backgroundCornerRadius,
                horizontalAlignment: horizontalAlignment,
                accessibilityLabel: "Native transcript text",
                accessibilityIdentifier: nativeAccessibilityIdentifier,
                usesFastPlainTextRenderer: usesFastPlainTextRenderer,
                promotesFastRendererWhenIdle: promotesFastRendererWhenIdle
            )
        }

        func liveScrollTextPresentation(
            dynamicTypeSize: DynamicTypeSize,
            colorScheme: ColorScheme
        ) -> MacConversationNativeTextPresentation? {
            guard usesLiveScrollText else {
                return nativeTextPresentation(
                    dynamicTypeSize: dynamicTypeSize,
                    colorScheme: colorScheme
                )
            }
            return MacConversationNativeTextPresentation(
                fallbackString: text,
                contentInsets: NSEdgeInsets(
                    top: 8,
                    left: 12,
                    bottom: 8,
                    right: 12
                ),
                fallbackFont: NSFont.systemFont(ofSize: 14),
                fallbackColor: .labelColor,
                accessibilityLabel: "Live scroll transcript text",
                accessibilityIdentifier: nativeAccessibilityIdentifier,
                usesFastPlainTextRenderer: true
            )
        }
    }

    private struct FooterRow: MacConversationTableRow {
        let id: String
        let contentRevision: UInt64
        let itemID: String
        let isTrailing: Bool

        var reuseIdentifier: String { "test.footer-row" }

        func nativeFooterPresentation(
            dynamicTypeSize: DynamicTypeSize,
            colorScheme: ColorScheme
        ) -> MacConversationNativeFooterPresentation? {
            MacConversationNativeFooterPresentation(
                itemID: itemID,
                timestampLabel: "12:34",
                timestampAccessibilityLabel: "Thursday, 6 August 2026 at 12:34",
                isTrailing: isTrailing,
                fontScale: 1,
                accessibilityIdentifier: "footer.\(itemID)"
            )
        }
    }

    func testNativeAndHostedRowsCreateDedicatedReusableCells() {
        let rows = [
            MixedRow(
                id: "hosted",
                contentRevision: 1,
                text: "Hosted row",
                usesNativeText: false
            ),
            MixedRow(
                id: "native",
                contentRevision: 1,
                text: "Selectable native row",
                usesNativeText: true,
                nativeAccessibilityIdentifier: "native.segment"
            ),
        ]
        var hostedRows: [String] = []
        let mounted = mountMixed(rows: rows) { hostedRows.append($0.id) }

        let hostedCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let nativeCell = mounted.table.view(
            atColumn: 0,
            row: 1,
            makeIfNecessary: true
        )!
        let nativeTextView = descendant(of: nativeCell, type: NSTextView.self)

        XCTAssertTrue(hostedCell.identifier?.rawValue.hasSuffix(".hosted") == true)
        XCTAssertTrue(nativeCell.identifier?.rawValue.hasSuffix(".native") == true)
        XCTAssertNotNil(descendant(of: hostedCell, type: NSHostingView<AnyView>.self))
        XCTAssertNil(descendant(of: nativeCell, type: NSHostingView<AnyView>.self))
        XCTAssertEqual(hostedRows, ["hosted"])
        XCTAssertEqual(nativeTextView?.string, "Selectable native row")
        // Table-level cross-transcript selection is the single selection
        // authority; per-view selection stays off.
        XCTAssertEqual(nativeTextView?.isSelectable, false)
        XCTAssertEqual(nativeTextView?.isEditable, false)
        XCTAssertEqual(nativeTextView?.textContainer?.widthTracksTextView, true)
        XCTAssertGreaterThan(nativeTextView?.intrinsicContentSize.height ?? 0, 0)
        XCTAssertLessThanOrEqual(nativeTextView?.frame.width ?? .infinity, 320.5)
        XCTAssertEqual(
            nativeTextView.map {
                $0.convert($0.bounds, to: nativeCell).midX
            } ?? 0,
            nativeCell.bounds.midX,
            accuracy: 1
        )
        XCTAssertNil(
            descendant(of: nativeCell, type: NSScrollView.self),
            "Native transcript text must not create a nested scrolling surface"
        )
        XCTAssertEqual(nativeTextView?.accessibilityLabel(), "Native transcript text")
        XCTAssertEqual(nativeTextView?.accessibilityIdentifier(), "native.segment")
    }

    func testFastPlainNativeRowUsesSelectableWrappingTextField() {
        let source = String(repeating: "fast selectable code line\n", count: 40)
        let rows = [
            MixedRow(
                id: "native-fast",
                contentRevision: 1,
                text: source,
                usesNativeText: true,
                backgroundCornerRadius: 12,
                usesFastPlainTextRenderer: true
            )
        ]
        let mounted = mountMixed(rows: rows)
        let cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let textField = descendant(of: cell, type: NSTextField.self)
        let textView = descendant(of: cell, type: NSTextView.self)

        XCTAssertTrue(cell.identifier?.rawValue.hasSuffix(".native") == true)
        XCTAssertNil(descendant(of: cell, type: NSHostingView<AnyView>.self))
        XCTAssertEqual(textView?.isHidden, true)
        XCTAssertEqual(textField?.isHidden, false)
        XCTAssertEqual(textField?.attributedStringValue.string, source)
        // Table-level cross-transcript selection is the single selection
        // authority; per-view selection stays off.
        XCTAssertEqual(textField?.isSelectable, false)
        XCTAssertEqual(textField?.isEditable, false)
        XCTAssertGreaterThan(textField?.frame.height ?? 0, 0)
    }

    func testLegacyMouseWheelSynthesizesLiveScrollWindow() throws {
        let initial = MixedRow(
            id: "wheel-row",
            contentRevision: 1,
            text: "Interactive hosted content",
            usesNativeText: false,
            nativeAccessibilityIdentifier: "wheel-row",
            usesLiveScrollText: true
        )
        let mounted = mountMixed(rows: [initial])
        let scrollView = mounted.table.enclosingScrollView!

        // A legacy mouse wheel posts no willStart/didEndLiveScroll pair; the
        // phase-less event itself must open the same protection window.
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -30,
            wheel2: 0,
            wheel3: 0
        ))
        let wheelEvent = try XCTUnwrap(NSEvent(cgEvent: cgEvent))
        scrollView.scrollWheel(with: wheelEvent)

        let changed = MixedRow(
            id: "wheel-row",
            contentRevision: 2,
            text: "Exact wheel-mode text",
            usesNativeText: false,
            nativeAccessibilityIdentifier: "wheel-row",
            usesLiveScrollText: true
        )
        mounted.hosting.rootView = mixedTable(rows: [changed])
        settle(mounted.hosting)

        let cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        XCTAssertTrue(cell.identifier?.rawValue.hasSuffix(".native-scroll") == true)

        // After 250ms of wheel quiescence the window closes on its own and
        // incremental restoration promotes the row back to its rich cell.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        mounted.hosting.layoutSubtreeIfNeeded()
        waitForLiveScrollRestoration(in: mounted.table, hosting: mounted.hosting)
        let idleCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        XCTAssertTrue(idleCell.identifier?.rawValue.hasSuffix(".hosted") == true)
    }

    func testFastRichTextPromotesOnlyAfterLiveScrollEnds() {
        let initial = MixedRow(
            id: "promoted-native",
            contentRevision: 1,
            text: "Initial native text",
            usesNativeText: true
        )
        let mounted = mountMixed(rows: [initial])
        let scrollView = mounted.table.enclosingScrollView!
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )

        let scrolling = MixedRow(
            id: "promoted-native",
            contentRevision: 2,
            text: "Exact text while scrolling",
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            promotesFastRendererWhenIdle: true
        )
        mounted.hosting.rootView = mixedTable(rows: [scrolling])
        mounted.hosting.needsLayout = true
        mounted.hosting.layoutSubtreeIfNeeded()
        let cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let textField = descendant(of: cell, type: NSTextField.self)
        let textView = descendant(of: cell, type: NSTextView.self)
        let scrollTextView = descendant(
            of: cell,
            type: MacConversationScrollTextView.self
        )
        XCTAssertNil(textField)
        XCTAssertNil(textView)
        XCTAssertEqual(
            scrollTextView?.attributedString.string,
            "Exact text while scrolling"
        )
        XCTAssertEqual(scrollTextView?.isHidden, false)

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        settle(mounted.hosting)
        let idleCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let idleTextField = descendant(of: idleCell, type: NSTextField.self)
        let idleTextView = descendant(of: idleCell, type: NSTextView.self)
        XCTAssertEqual(idleTextField?.isHidden, true)
        XCTAssertNil(descendant(
            of: idleCell,
            type: MacConversationScrollTextView.self
        ))
        XCTAssertEqual(idleTextView?.isHidden, false)
        XCTAssertEqual(idleTextView?.string, "Exact text while scrolling")
    }

    func testHostedRowUsesExactLightweightCellOnlyDuringLiveScroll() {
        let initial = MixedRow(
            id: "live-display-row",
            contentRevision: 1,
            text: "Interactive hosted content",
            usesNativeText: false,
            nativeAccessibilityIdentifier: "live-display-row",
            usesLiveScrollText: true
        )
        let mounted = mountMixed(rows: [initial])
        let scrollView = mounted.table.enclosingScrollView!
        XCTAssertTrue(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )?.identifier?.rawValue.hasSuffix(".hosted") == true)

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        XCTAssertTrue(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: false
        )?.identifier?.rawValue.hasSuffix(".hosted") == true)
        let changed = MixedRow(
            id: "live-display-row",
            contentRevision: 2,
            text: "Every exact character remains visible",
            usesNativeText: false,
            nativeAccessibilityIdentifier: "live-display-row",
            usesLiveScrollText: true
        )
        mounted.hosting.rootView = mixedTable(rows: [changed])
        settle(mounted.hosting)

        var cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let scrollTextView = descendant(
            of: cell,
            type: MacConversationScrollTextView.self
        )
        XCTAssertTrue(cell.identifier?.rawValue.hasSuffix(".native-scroll") == true)
        XCTAssertNil(descendant(of: cell, type: NSHostingView<AnyView>.self))
        XCTAssertEqual(
            scrollTextView?.attributedString.string,
            "Every exact character remains visible"
        )

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        settle(mounted.hosting)
        cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        XCTAssertTrue(cell.identifier?.rawValue.hasSuffix(".hosted") == true)
        XCTAssertNotNil(descendant(of: cell, type: NSHostingView<AnyView>.self))
    }

    func testLiveScrollEndRestoresTransitionedCellOutsideVisibleBounds() throws {
        let rows = (0..<30).map { index in
            MixedRow(
                id: "offscreen-live-\(index)",
                contentRevision: 1,
                text: "Exact offscreen row \(index)",
                usesNativeText: false,
                usesLiveScrollText: true
            )
        }
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertFalse(NSLocationInRange(0, visible))

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        let transitioned = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        XCTAssertTrue(
            transitioned.identifier?.rawValue.hasSuffix(".native-scroll") == true
        )

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        let pending = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: false
        ))
        XCTAssertTrue(
            pending.identifier?.rawValue.hasSuffix(".native-scroll") == true,
            "Gesture end must enqueue restoration instead of rebuilding the row synchronously."
        )
        settle(mounted.hosting)
        let restored = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        XCTAssertTrue(restored.identifier?.rawValue.hasSuffix(".hosted") == true)
        XCTAssertNotNil(descendant(of: restored, type: NSHostingView<AnyView>.self))
        XCTAssertFalse(restored === transitioned)
        // Promotion is always a cell-class swap, so it must rebuild the row
        // view. reloadData(forRowIndexes:) left the row view owning the old
        // stand-in cell, and the promoted cell kept its own fitting width —
        // the transcript column stopped lining up with every other row.
        let rowView = try XCTUnwrap(restored.superview as? NSTableRowView)
        XCTAssertFalse(
            rowView.subviews.contains(transitioned),
            "The stand-in cell must leave the row view when its row promotes."
        )
    }

    func testVisibleStandInPromotionRebuildsTheRowView() throws {
        let rows = (0..<40).map { index in
            MixedRow(
                id: "visible-live-\(index)",
                contentRevision: 1,
                text: "Visible stand-in row \(index)",
                usesNativeText: false,
                usesLiveScrollText: true
            )
        }
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        let settledVisible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(settledVisible.location, NSNotFound)
        let referenceCell = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: settledVisible.location,
            makeIfNecessary: false
        ), "Expected a settled cell to reference for width parity")
        let referenceWidth = referenceCell.frame.width

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        // Scroll upward inside the gesture window so unrealized rows enter
        // the viewport and mount as draw-only stand-ins.
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 400)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)
        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(visible.location, NSNotFound)
        var standInRow: Int?
        var standInCell: NSView?
        for row in visible.location..<NSMaxRange(visible) {
            if let cell = mounted.table.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ), cell.identifier?.rawValue.hasSuffix(".native-scroll") == true {
                standInRow = row
                standInCell = cell
                break
            }
        }
        let row = try XCTUnwrap(
            standInRow,
            "Expected a visible stand-in mounted inside the gesture window"
        )
        let standIn = try XCTUnwrap(standInCell)
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        settle(mounted.hosting)

        let promoted = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: row,
            makeIfNecessary: false
        ))
        XCTAssertTrue(
            promoted.identifier?.rawValue.hasSuffix(".hosted") == true,
            "The visible stand-in must promote to its settled cell class."
        )
        // Promotion is a cell-class swap and must rebuild the row view.
        // reloadData(forRowIndexes:) left the row view owning the stand-in,
        // and the promoted cell kept its own fitting width — sibling tiles of
        // one message rendered at different x-offsets after a manual scroll.
        let rowView = try XCTUnwrap(promoted.superview as? NSTableRowView)
        XCTAssertFalse(
            rowView.subviews.contains(standIn),
            "The stand-in cell must leave the row view when its row promotes."
        )
        XCTAssertEqual(
            promoted.frame.width,
            referenceWidth,
            accuracy: 0.5,
            "The promoted cell must adopt the table's cell width, not its own fitting width."
        )
    }

    // MARK: - Cross-transcript selection integration

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at windowPoint: NSPoint,
        in window: NSWindow,
        clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        )!
    }

    private func dragSelection(
        in mounted: (
            window: NSWindow,
            hosting: NSHostingView<MacConversationTableView<MixedRow>>,
            table: NSTableView
        ),
        fromTablePoint start: NSPoint,
        toTablePoint end: NSPoint,
        mutateBetween: (() -> Void)? = nil
    ) {
        let startWindow = mounted.table.convert(start, to: nil)
        let endWindow = mounted.table.convert(end, to: nil)
        mounted.table.mouseDown(
            with: mouseEvent(.leftMouseDown, at: startWindow, in: mounted.window)
        )
        let midWindow = NSPoint(
            x: (startWindow.x + endWindow.x) / 2,
            y: (startWindow.y + endWindow.y) / 2
        )
        mounted.table.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: midWindow, in: mounted.window)
        )
        if let mutateBetween {
            mutateBetween()
            settle(mounted.hosting)
        }
        mounted.table.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: endWindow, in: mounted.window)
        )
        mounted.table.mouseUp(
            with: mouseEvent(.leftMouseUp, at: endWindow, in: mounted.window)
        )
    }

    func testSelectionDragAcrossRowsPaintsAndCopiesTheExactSpan() throws {
        let rows = [
            MixedRow(
                id: "fast-a",
                contentRevision: 1,
                text: "alpha one\nalpha two\n",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "shared-item"
            ),
            MixedRow(
                id: "fast-b",
                contentRevision: 1,
                text: "beta one\nbeta two",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "shared-item"
            ),
        ]
        let mounted = mountMixed(rows: rows)

        // The routing guarantee: text rows are hit-test transparent down to
        // the table, so the drag owner can never be destroyed mid-drag.
        let firstRect = mounted.table.rect(ofRow: 0)
        let probeInContent = mounted.window.contentView!.convert(
            NSPoint(x: firstRect.midX, y: firstRect.minY + 4),
            from: mounted.table
        )
        XCTAssertTrue(
            mounted.window.contentView!.hitTest(probeInContent)
                === mounted.table,
            "Text rows must hit-test through to the table."
        )

        let lastRect = mounted.table.rect(ofRow: 1)
        dragSelection(
            in: mounted,
            fromTablePoint: NSPoint(x: firstRect.minX + 1, y: firstRect.minY + 1),
            toTablePoint: NSPoint(x: lastRect.maxX - 1, y: lastRect.maxY - 1)
        )

        for row in 0...1 {
            let cell = try XCTUnwrap(mounted.table.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: false
            ))
            let underlay = try XCTUnwrap(descendant(
                of: cell,
                type: MacConversationSelectionUnderlay.self
            ))
            XCTAssertFalse(
                underlay.highlightRects.isEmpty,
                "Row \(row) must paint its part of the selection."
            )
        }

        NSPasteboard.general.clearContents()
        (mounted.table as? MacTranscriptTableView)?.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            rows[0].text + rows[1].text,
            "A full-span drag must copy both rows joined seamlessly."
        )
    }

    func testStreamingChurnMidDragKeepsSelectionAndDragAlive() throws {
        var rows = [
            MixedRow(
                id: "fast-a",
                contentRevision: 1,
                text: "alpha one\nalpha two\n",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "shared-item"
            ),
            MixedRow(
                id: "fast-b",
                contentRevision: 1,
                text: "beta one\nbeta two",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "shared-item"
            ),
        ]
        let mounted = mountMixed(rows: rows)
        let firstRect = mounted.table.rect(ofRow: 0)
        let lastRect = mounted.table.rect(ofRow: 1)
        dragSelection(
            in: mounted,
            fromTablePoint: NSPoint(x: firstRect.minX + 1, y: firstRect.minY + 1),
            toTablePoint: NSPoint(x: lastRect.maxX - 1, y: lastRect.maxY - 1),
            mutateBetween: {
                // A streaming-style model churn while the button is down.
                rows[1] = MixedRow(
                    id: "fast-b",
                    contentRevision: 2,
                    text: "beta one\nbeta two",
                    usesNativeText: true,
                    usesFastPlainTextRenderer: true,
                    mutationSourceIDOverride: "shared-item"
                )
                mounted.hosting.rootView = self.mixedTable(rows: rows)
            }
        )

        NSPasteboard.general.clearContents()
        (mounted.table as? MacTranscriptTableView)?.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            rows[0].text + rows[1].text,
            "A mid-drag model mutation must not strand the drag or the selection."
        )
    }

    func testPlainClickOpensLinksAndDragsDoNot() throws {
        var opened: [URL] = []
        let link = URL(string: "https://example.com/docs")!
        let rows = [
            MixedRow(
                id: "rich-link",
                contentRevision: 1,
                text: "Open the documentation link now",
                usesNativeText: true,
                maximumContentWidth: nil,
                linkURL: link
            )
        ]
        let mounted = mountMixed(rows: rows, onNativeLink: { url in
            opened.append(url)
            return true
        })
        let rect = mounted.table.rect(ofRow: 0)
        // Fill alignment: the text begins at the content insets, so a point
        // just inside the first line sits on the link's glyphs.
        let onText = NSPoint(x: rect.minX + 44, y: rect.minY + 16)
        let windowPoint = mounted.table.convert(onText, to: nil)
        mounted.table.mouseDown(
            with: mouseEvent(.leftMouseDown, at: windowPoint, in: mounted.window)
        )
        mounted.table.mouseUp(
            with: mouseEvent(.leftMouseUp, at: windowPoint, in: mounted.window)
        )
        XCTAssertEqual(
            opened,
            [link],
            "A movement-free click on link glyphs must route to the policy handler."
        )

        opened.removeAll()
        dragSelection(
            in: mounted,
            fromTablePoint: onText,
            toTablePoint: NSPoint(x: rect.maxX - 1, y: rect.minY + 16)
        )
        XCTAssertTrue(
            opened.isEmpty,
            "A drag that selects text must never open the link under it."
        )
    }

    func testHostedPlainTextFallsThroughWhileControlsKeepHits() throws {
        let rows = [
            MixedRow(
                id: "hosted-row",
                contentRevision: 1,
                text: "Plain hosted streaming text",
                usesNativeText: false
            )
        ]
        let mounted = mountMixed(rows: rows)
        let rect = mounted.table.rect(ofRow: 0)
        // With transcript textSelection disabled, plain SwiftUI text is
        // hit-test transparent: the table receives the event, so drags can
        // START on hosted rows (row-granular). Interactive controls inside
        // hosted rows still take their own hits (covered by the footer copy
        // button test and the disclosure toggle tests).
        let probe = mounted.window.contentView!.convert(
            NSPoint(x: rect.midX, y: rect.midY),
            from: mounted.table
        )
        let hit = mounted.window.contentView!.hitTest(probe)
        XCTAssertTrue(
            hit === mounted.table,
            "Non-interactive hosted content must not block table drags."
        )
    }

    private func fastSelectableRows(count: Int) -> [MixedRow] {
        (0..<count).map { index in
            MixedRow(
                id: "drag-row-\(index)",
                contentRevision: 1,
                text: "drag line one \(index)\ndrag line two \(index)\n",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "drag-item"
            )
        }
    }

    func testHeldDragPinsTheViewportAgainstStreamingBatches() throws {
        var rows = fastSelectableRows(count: 60)
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)

        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(visible.location, NSNotFound)
        let anchorRect = mounted.table.rect(ofRow: visible.location + 1)
        let startWindow = mounted.table.convert(
            NSPoint(x: anchorRect.minX + 40, y: anchorRect.minY + 6),
            to: nil
        )
        let endWindow = mounted.table.convert(
            NSPoint(x: anchorRect.minX + 120, y: anchorRect.maxY + 20),
            to: nil
        )
        mounted.table.mouseDown(
            with: mouseEvent(.leftMouseDown, at: startWindow, in: mounted.window)
        )
        mounted.table.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: endWindow, in: mounted.window)
        )

        // Streaming keeps publishing while the button is held: batches must
        // neither move the clip origin nor drop the selection.
        let heldOrigin = scrollView.contentView.bounds.origin.y
        for revision in UInt64(2)...5 {
            rows.append(MixedRow(
                id: "drag-row-appended-\(revision)",
                contentRevision: revision,
                text: "appended \(revision)\n",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "drag-item"
            ))
            mounted.hosting.rootView = mixedTable(rows: rows)
            settle(mounted.hosting)
            XCTAssertEqual(
                scrollView.contentView.bounds.origin.y,
                heldOrigin,
                accuracy: 0.5,
                "A streaming batch moved the viewport under a held drag."
            )
        }

        mounted.table.mouseUp(
            with: mouseEvent(.leftMouseUp, at: endWindow, in: mounted.window)
        )
        NSPasteboard.general.clearContents()
        (mounted.table as? MacTranscriptTableView)?.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string)?.isEmpty,
            false,
            "The selection survives the streaming churn under the drag."
        )
    }

    func testNoScrollDragDuringStreamingRetainsStickyFollow() throws {
        var rows = fastSelectableRows(count: 60)
        let mounted = mountMixed(rows: rows)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)

        let visible = mounted.table.rows(
            in: mounted.table.enclosingScrollView!.contentView.bounds
        )
        let anchorRect = mounted.table.rect(ofRow: visible.location + 1)
        dragSelection(
            in: mounted,
            fromTablePoint: NSPoint(
                x: anchorRect.minX + 40,
                y: anchorRect.minY + 6
            ),
            toTablePoint: NSPoint(
                x: anchorRect.minX + 160,
                y: anchorRect.maxY + 30
            )
        )

        // Follow was restored at mouse-up (the drag never scrolled), so the
        // next streamed batch pins the new content into view.
        rows.append(MixedRow(
            id: "post-drag-append",
            contentRevision: 9,
            text: String(
                repeating: "post drag growth line\n",
                count: 12
            ),
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            mutationSourceIDOverride: "drag-item"
        ))
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)
        XCTAssertLessThanOrEqual(
            distanceFromBottom(in: mounted.table),
            8,
            "A no-scroll selection drag must not disengage sticky follow."
        )
    }

    func testWheelEventDuringDragMountsNoStandIns() throws {
        let initial = MixedRow(
            id: "drag-wheel-row",
            contentRevision: 1,
            text: "wheel target text",
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            usesLiveScrollText: true
        )
        let mounted = mountMixed(rows: [initial])
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        let rect = mounted.table.rect(ofRow: 0)
        let startWindow = mounted.table.convert(
            NSPoint(x: rect.minX + 40, y: rect.minY + 6),
            to: nil
        )
        mounted.table.mouseDown(
            with: mouseEvent(.leftMouseDown, at: startWindow, in: mounted.window)
        )
        mounted.table.mouseDragged(
            with: mouseEvent(
                .leftMouseDragged,
                at: NSPoint(x: startWindow.x + 60, y: startWindow.y - 8),
                in: mounted.window
            )
        )

        // A phase-less wheel tick mid-drag must not open the synthesized
        // live-scroll window: a changed row keeps its real cell instead of a
        // draw-only stand-in.
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: -30,
            wheel2: 0,
            wheel3: 0
        ))
        scrollView.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cgEvent)))
        var changed = initial
        changed = MixedRow(
            id: "drag-wheel-row",
            contentRevision: 2,
            text: "wheel target text changed",
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            usesLiveScrollText: true
        )
        mounted.hosting.rootView = mixedTable(rows: [changed])
        settle(mounted.hosting)
        let cell = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        XCTAssertFalse(
            cell.identifier?.rawValue.hasSuffix(".native-scroll") == true,
            "Wheel events under a held drag must not mount stand-in cells."
        )
        mounted.table.mouseUp(
            with: mouseEvent(
                .leftMouseUp,
                at: startWindow,
                in: mounted.window
            )
        )
    }

    func testEdgeAutoscrollExtendsTheSelectionAndReleasesFollow() throws {
        var rows = fastSelectableRows(count: 60)
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)
        let originBefore = scrollView.contentView.bounds.origin.y

        // Anchor mid-viewport, then hold the pointer 4pt under the top edge.
        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        let anchorRect = mounted.table.rect(ofRow: visible.location + 3)
        let startWindow = mounted.table.convert(
            NSPoint(x: anchorRect.minX + 40, y: anchorRect.minY + 6),
            to: nil
        )
        let clipTopInTable = scrollView.contentView.bounds.minY + 4
        let holdWindow = mounted.table.convert(
            NSPoint(x: anchorRect.minX + 40, y: clipTopInTable),
            to: nil
        )
        mounted.table.mouseDown(
            with: mouseEvent(.leftMouseDown, at: startWindow, in: mounted.window)
        )
        mounted.table.mouseDragged(
            with: mouseEvent(.leftMouseDragged, at: holdWindow, in: mounted.window)
        )
        // Let the .common-mode autoscroll timer tick with the pointer held.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertLessThan(
            scrollView.contentView.bounds.origin.y,
            originBefore - 40,
            "Holding the pointer at the top edge must scroll the transcript up."
        )
        mounted.table.mouseUp(
            with: mouseEvent(.leftMouseUp, at: holdWindow, in: mounted.window)
        )

        // The selection extended upward across rows realized during the
        // autoscroll: the copied text reaches rows above the anchor.
        NSPasteboard.general.clearContents()
        (mounted.table as? MacTranscriptTableView)?.copy(nil)
        let copied = try XCTUnwrap(NSPasteboard.general.string(forType: .string))
        let anchorRowIndex = visible.location + 3
        XCTAssertTrue(
            copied.contains("drag line one \(anchorRowIndex - 2)"),
            "Autoscroll must extend the selection across newly realized rows."
        )

        // The drag scrolled, so follow re-derives from the resting position
        // (off-bottom): a new streamed batch must NOT yank the viewport down.
        let restingOrigin = scrollView.contentView.bounds.origin.y
        rows.append(MixedRow(
            id: "post-autoscroll-append",
            contentRevision: 7,
            text: "appended after autoscroll\n",
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            mutationSourceIDOverride: "drag-item"
        ))
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            restingOrigin,
            accuracy: 0.5,
            "An off-bottom autoscroll release must leave follow disengaged."
        )
    }

    func testEscapeClearsSelectionAndReturnsFocus() throws {
        let rows = fastSelectableRows(count: 8)
        let mounted = mountMixed(rows: rows)
        let priorResponder = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        mounted.window.contentView?.addSubview(priorResponder)
        mounted.window.makeFirstResponder(priorResponder)

        let rect = mounted.table.rect(ofRow: 1)
        dragSelection(
            in: mounted,
            fromTablePoint: NSPoint(x: rect.minX + 40, y: rect.minY + 6),
            toTablePoint: NSPoint(x: rect.minX + 160, y: rect.maxY + 20)
        )
        XCTAssertTrue(
            mounted.window.firstResponder === mounted.table,
            "An established selection takes first responder."
        )

        let table = try XCTUnwrap(mounted.table as? MacTranscriptTableView)
        table.cancelOperation(nil)
        NSPasteboard.general.clearContents()
        table.copy(nil)
        XCTAssertNil(
            NSPasteboard.general.string(forType: .string),
            "Escape must clear the selection."
        )
        XCTAssertTrue(
            mounted.window.firstResponder === priorResponder.currentEditor()
                || mounted.window.firstResponder === priorResponder,
            "Escape must hand focus back to the previous responder."
        )
    }

    func testContextMenuOffersCopyOrCopyMessage() throws {
        var rows = fastSelectableRows(count: 4)
        rows[1] = MixedRow(
            id: rows[1].id,
            contentRevision: 1,
            text: rows[1].text,
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            mutationSourceIDOverride: "drag-item",
            selectionRoleLabelOverride: "You:"
        )
        let mounted = mountMixed(rows: rows)
        let table = try XCTUnwrap(mounted.table as? MacTranscriptTableView)
        let rect = mounted.table.rect(ofRow: 1)
        let windowPoint = mounted.table.convert(
            NSPoint(x: rect.minX + 40, y: rect.minY + 6),
            to: nil
        )

        // No selection: a message row offers Copy Message.
        let messageMenu = table.selectionDelegate?.selectionContextMenu(
            atWindowPoint: windowPoint
        )
        XCTAssertEqual(messageMenu?.items.first?.title, "Copy Message")

        // No selection over a non-message row: no menu.
        let plainRect = mounted.table.rect(ofRow: 2)
        let plainPoint = mounted.table.convert(
            NSPoint(x: plainRect.minX + 40, y: plainRect.minY + 6),
            to: nil
        )
        XCTAssertNil(table.selectionDelegate?.selectionContextMenu(
            atWindowPoint: plainPoint
        ))

        // With a selection: Copy.
        dragSelection(
            in: mounted,
            fromTablePoint: NSPoint(x: rect.minX + 40, y: rect.minY + 6),
            toTablePoint: NSPoint(x: rect.minX + 160, y: rect.maxY + 10)
        )
        let copyMenu = table.selectionDelegate?.selectionContextMenu(
            atWindowPoint: windowPoint
        )
        XCTAssertEqual(copyMenu?.items.first?.title, "Copy")
    }

    func testDoubleClickSelectsAWordAcrossATileSeam() throws {
        let rows = [
            MixedRow(
                id: "seam-a",
                contentRevision: 1,
                text: "wor",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "seam-item"
            ),
            MixedRow(
                id: "seam-b",
                contentRevision: 1,
                text: "d tail",
                usesNativeText: true,
                usesFastPlainTextRenderer: true,
                mutationSourceIDOverride: "seam-item"
            ),
        ]
        let mounted = mountMixed(rows: rows)
        let rect = mounted.table.rect(ofRow: 0)
        let windowPoint = mounted.table.convert(
            NSPoint(x: rect.minX + 34, y: rect.minY + 12),
            to: nil
        )
        mounted.table.mouseDown(with: NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mounted.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        )!)
        mounted.table.mouseUp(with: NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: mounted.window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1
        )!)

        NSPasteboard.general.clearContents()
        (mounted.table as? MacTranscriptTableView)?.copy(nil)
        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            "word",
            "A word straddling a tile seam must select whole across both rows."
        )
    }

    func testSelectionCursorsMatchContentUnderThePointer() throws {
        let link = URL(string: "https://example.com/cursor")!
        let rows = [
            MixedRow(
                id: "cursor-text",
                contentRevision: 1,
                text: "plain cursor text row",
                usesNativeText: true,
                usesFastPlainTextRenderer: true
            ),
            MixedRow(
                id: "cursor-link",
                contentRevision: 1,
                text: "linked cursor text row",
                usesNativeText: true,
                maximumContentWidth: nil,
                linkURL: link
            ),
        ]
        let mounted = mountMixed(rows: rows)
        let table = try XCTUnwrap(mounted.table as? MacTranscriptTableView)
        let textRect = mounted.table.rect(ofRow: 0)
        let textCursor = table.selectionDelegate?.selectionCursor(
            atWindowPoint: mounted.table.convert(
                NSPoint(x: textRect.minX + 40, y: textRect.minY + 12),
                to: nil
            )
        )
        XCTAssertTrue(textCursor === NSCursor.iBeam)

        let linkRect = mounted.table.rect(ofRow: 1)
        let linkCursor = table.selectionDelegate?.selectionCursor(
            atWindowPoint: mounted.table.convert(
                NSPoint(x: linkRect.minX + 44, y: linkRect.minY + 16),
                to: nil
            )
        )
        XCTAssertTrue(linkCursor === NSCursor.pointingHand)
    }

    /// Marks user scroll intent without opening a gesture window or moving
    /// content: a momentum-phase wheel event reaches the scroll view's
    /// scrollWheel (the user-input funnel) but is ignored by the window
    /// synthesis, exactly like the tail of a real momentum scroll.
    private func markUserScrollInput(in table: NSTableView) {
        let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        )!
        cgEvent.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 1)
        table.enclosingScrollView?.scrollWheel(with: NSEvent(cgEvent: cgEvent)!)
    }

    /// A line-structured assistant reply: Markdown collapses its soft line
    /// breaks, so the plain and rich renderings differ in shape entirely —
    /// exactly the content that made format flips obvious in the field.
    private func lineStructuredAssistantMessage(
        id: String = "assistant-warm"
    ) -> ConversationItem {
        // The prepared-markdown cache is process-wide and keyed by text, so
        // each test needs its own source or one test warms another's cold case.
        .message(ChatMessage(
            id: id,
            turnID: "turn",
            role: .assistant,
            text: "\(id)\n" + (0..<40)
                .map { index in
                    (1...10)
                        .map { String(index * 10 + $0) }
                        .joined(separator: " ")
                }
                .joined(separator: "\n"),
            occurredAt: 1
        ))
    }

    private func warmPreparedArtifact(
        for row: MacTranscriptRow,
        fontScale: CGFloat = 1,
        colorScheme: ColorScheme = .light
    ) async {
        guard case .item(let projection, _, _) = row,
              case .message(let message) = projection.displayItem,
              let source = message.contents.first?.text,
              let prepared = await SanitizedMarkdownCache.shared
                .preparedMarkdown(raw: source) else {
            return XCTFail("Expected a preparable markdown tile")
        }
        // Populating the style-keyed AppKit memo is what makes the artifact
        // mountable without any main-actor translation at realization time.
        _ = await MainActor.run {
            prepared.appKitAttributedText(
                fontScale: fontScale,
                colorScheme: colorScheme
            )
        }
    }

    func testWarmMarkdownArtifactMountsRichInsteadOfPlainSource() async {
        let projections = TranscriptRowProjection.makeRows(
            item: lineStructuredAssistantMessage()
        )
        XCTAssertGreaterThan(projections.count, 1, "Fixture must tile")
        let row = MacTranscriptRow.item(
            projections[0],
            isExpanded: false,
            copiedItemID: nil
        )

        let cold = await MainActor.run {
            row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )
        }
        XCTAssertEqual(
            cold?.usesFastPlainTextRenderer,
            true,
            "A cold tile still paints exact source first."
        )
        XCTAssertNil(cold?.attributedString)

        await warmPreparedArtifact(for: row)

        let warm = await MainActor.run {
            row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )
        }
        XCTAssertNotNil(
            warm?.attributedString,
            """
            An assistant tile whose rich artifact is already translated must \
            mount it directly; mounting plain source first made every scroll \
            pass reformat the message.
            """
        )
        XCTAssertEqual(warm?.usesFastPlainTextRenderer, false)
        XCTAssertEqual(
            warm?.promotesFastRendererWhenIdle,
            false,
            "A directly-mounted rich tile has nothing left to promote."
        )
        XCTAssertNotEqual(
            warm?.attributedString?.string,
            cold?.fallbackString,
            "The rich rendering must differ from raw source for this fixture."
        )
    }

    func testWarmLiveScrollStandInDrawsTheRichRenderingNotRawSource() async {
        let projections = TranscriptRowProjection.makeRows(
            item: lineStructuredAssistantMessage(id: "assistant-standin")
        )
        let row = MacTranscriptRow.item(
            projections[0],
            isExpanded: false,
            copiedItemID: nil
        )

        let coldStandIn = await MainActor.run {
            row.liveScrollTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )
        }
        XCTAssertNil(
            coldStandIn?.attributedString,
            "Cold stand-ins keep exact source, matching the cell they settle into."
        )

        await warmPreparedArtifact(for: row)

        let warmStandIn = await MainActor.run {
            row.liveScrollTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )
        }
        XCTAssertNotNil(
            warmStandIn?.attributedString,
            """
            A row realized mid-gesture must draw the same rich rendering its \
            settled neighbours show, or one message appears in two shapes.
            """
        )
        XCTAssertNil(
            warmStandIn?.linkHandler,
            "Stand-ins stay non-interactive."
        )
        XCTAssertNil(
            warmStandIn?.deferredAttributedString,
            "Stand-ins never carry deferred work."
        )
    }

    func testMachineOriginDriftCannotKillStickyFollow() throws {
        // The seal kill-chain from the 2026-08-19 field repro: a visible-row
        // remove+insert drops the row's height cache, the frame transiently
        // shrinks, the clip clamps, and when the real height lands the origin
        // sits above the bottom with NO user input — that must re-pin, never
        // release follow.
        var rows = fastSelectableRows(count: 60)
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)

        // Machine drift: the origin moves up with no user-input funnel fired.
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 120)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        // The next streamed batch must still pin to the bottom.
        rows.append(MixedRow(
            id: "post-drift-append",
            contentRevision: 3,
            text: "post drift line\n",
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            mutationSourceIDOverride: "drag-item"
        ))
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)
        XCTAssertLessThanOrEqual(
            distanceFromBottom(in: mounted.table),
            8,
            "Machine origin drift must re-pin, not silently release follow."
        )
    }

    func testUserWheelInputStillReleasesFollowOnDrift() throws {
        var rows = fastSelectableRows(count: 60)
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)

        // The same origin move, but preceded by real user wheel input.
        markUserScrollInput(in: mounted.table)
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 120)
        let requested = scrollView.contentView
            .constrainBoundsRect(proposed).origin
        scrollView.contentView.setBoundsOrigin(requested)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        rows.append(MixedRow(
            id: "post-user-append",
            contentRevision: 3,
            text: "post user line\n",
            usesNativeText: true,
            usesFastPlainTextRenderer: true,
            mutationSourceIDOverride: "drag-item"
        ))
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            requested.y,
            accuracy: 0.5,
            "A user-initiated move away from the bottom must release follow."
        )
    }

    func testFollowOwnerSurvivesLateDocumentGrowth() throws {
        let mounted = mount(rowCount: 60)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        mounted.hosting.rootView = table(rows: makeRows(count: 61))
        settle(mounted.hosting)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)

        // Hosted streaming rows publish their intrinsic height after the
        // mutation batch's correction pass. Grow the document without any
        // snapshot mutation and run one synchronous scroll-view layout: the
        // still-armed follow owner must pin to the new bottom instead of
        // letting the growth slip below the viewport.
        let originBefore = scrollView.contentView.bounds.origin.y
        var frame = mounted.table.frame
        frame.size.height += 600
        mounted.table.frame = frame
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(
            scrollView.contentView.bounds.origin.y,
            originBefore + 300,
            "Late document growth while following must re-pin to the bottom."
        )
    }

    func testUserScrollUpReleasesFollowAndLaterGrowthDoesNotFightIt() throws {
        let mounted = mount(rowCount: 60)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        mounted.hosting.rootView = table(rows: makeRows(count: 61))
        settle(mounted.hosting)
        XCTAssertLessThanOrEqual(distanceFromBottom(in: mounted.table), 8)

        markUserScrollInput(in: mounted.table)
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 240)
        let requestedOrigin = scrollView.contentView
            .constrainBoundsRect(proposed).origin
        scrollView.contentView.setBoundsOrigin(requestedOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()

        // The move away from the bottom released follow, so neither manual
        // document growth nor a later mutation batch may pull the viewport
        // back down.
        var frame = mounted.table.frame
        frame.size.height += 600
        mounted.table.frame = frame
        scrollView.needsLayout = true
        scrollView.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            requestedOrigin.y,
            accuracy: 0.5,
            "Growth after the user leaves the bottom must not move the viewport."
        )
        mounted.hosting.rootView = table(rows: makeRows(count: 62))
        settle(mounted.hosting)
        XCTAssertEqual(
            scrollView.contentView.bounds.origin.y,
            requestedOrigin.y,
            accuracy: 0.5,
            "Mutations after the user leaves the bottom must anchor, not pin."
        )
    }

    func testStreamingMutationPressureCannotStarveRestorationForever() throws {
        let rows = (0..<30).map { index in
            MixedRow(
                id: "starved-live-\(index)",
                contentRevision: 1,
                text: "Starved row \(index)",
                usesNativeText: false,
                usesLiveScrollText: true
            )
        }
        let mounted = mountMixed(rows: rows)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        let transitioned = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        XCTAssertTrue(
            transitioned.identifier?.rawValue.hasSuffix(".native-scroll") == true
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        // A streaming turn re-arms the mutation correction every ~33ms.
        // Restoration used to yield to that ownership unconditionally, so the
        // stand-in stayed mounted for the entire reply. Keep the pressure on
        // for ~0.7s and require the promotion to land anyway.
        var revision: UInt64 = 1
        let deadline = Date().addingTimeInterval(0.7)
        while Date() < deadline {
            revision += 1
            var mutated = rows
            mutated[rows.count - 1] = MixedRow(
                id: mutated[rows.count - 1].id,
                contentRevision: revision,
                text: "Streamed update \(revision)",
                usesNativeText: false,
                usesLiveScrollText: true
            )
            mounted.hosting.rootView = mixedTable(rows: mutated)
            RunLoop.main.run(until: Date().addingTimeInterval(0.033))
        }
        let promoted = try XCTUnwrap(mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        ))
        XCTAssertTrue(
            promoted.identifier?.rawValue.hasSuffix(".hosted") == true,
            "Continuous mutation pressure must not keep stand-in cells mounted."
        )
    }

    func testGenerationOnlyChangeWithIdenticalRowsDoesNotReloadTheTable() {
        let rows = makeRows(count: 40)
        let mounted = mount(rows: rows)
        settle(mounted.hosting)

        MacConversationTableDiagnostics.reset()
        mounted.hosting.rootView = MacConversationTableView(
            sections: sections(rows),
            snapshotGeneration: "rebroadcast-generation",
            styleRevision: 0,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onLiveScrollingChange: { _ in },
            onAnchoredChange: { _ in },
            prefetchRows: { _ in },
            makeRow: { row, _, _ in
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
        settle(mounted.hosting)
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(
            diagnostics.reloadDataCalls,
            0,
            "A rebroadcast generation with identical rows is bookkeeping, not a repaint."
        )
    }

    private func distanceFromBottom(in table: NSTableView) -> CGFloat {
        guard let scrollView = table.enclosingScrollView else { return 0 }
        let clip = scrollView.contentView
        let maximumOriginY = max(
            0,
            table.frame.height - clip.bounds.height
        )
        return maximumOriginY - clip.bounds.origin.y
    }

    func testCompletedAssistantUsesNativeTextForEveryTileAndASeparateNativeFooter() {
        let source = String(repeating: "bounded assistant line\n", count: 400)
        let item = ConversationItem.message(
            ChatMessage(
                id: "assistant",
                turnID: "turn",
                role: .assistant,
                text: source,
                occurredAt: 1
            )
        )
        let projections = TranscriptRowProjection.makeRows(item: item)
        XCTAssertGreaterThan(projections.count, 2)

        let rows = makeMacTranscriptRows(
            item: item,
            projections: projections,
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 7
        )

        XCTAssertEqual(rows.count, projections.count + 1)
        for row in rows.dropLast() {
            guard case .item = row else {
                return XCTFail("Every bounded text row must remain a projected item row.")
            }
            XCTAssertNotNil(
                row.nativeTextPresentation(
                    dynamicTypeSize: .large,
                    colorScheme: .light
                ),
                "Completed assistant text must bypass NSHostingView, including its final tile."
            )
            XCTAssertTrue(row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )?.usesFastPlainTextRenderer == true)
            XCTAssertTrue(row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )?.promotesFastRendererWhenIdle == true)
        }
        guard case .messageFooter(let footer, let revision) = rows.last else {
            return XCTFail("Expected a separate small assistant action footer.")
        }
        XCTAssertEqual(footer.itemID, "assistant")
        XCTAssertEqual(revision, 7)
        let nativeFooter = rows.last?.nativeFooterPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        )
        XCTAssertEqual(nativeFooter?.itemID, "assistant")
        XCTAssertEqual(nativeFooter?.isTrailing, false)
        XCTAssertEqual(
            projections.map(\.sourceText).joined(),
            source,
            "Separating the footer must not hide or duplicate message text."
        )
    }

    func testLiveScrollMessagePresentationAlwaysUsesExactPlainSource() throws {
        let source = "[Rendered label](https://example.com/path) and **bold source**"
        let item = ConversationItem.message(
            ChatMessage(id: "markdown-user", role: .user, text: source)
        )
        let row = try XCTUnwrap(makeMacTranscriptRows(
            item: item,
            projections: TranscriptRowProjection.makeRows(item: item),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)

        let live = try XCTUnwrap(row.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        XCTAssertNil(live.attributedString)
        XCTAssertNil(live.deferredAttributedString)
        XCTAssertNil(live.linkHandler)
        XCTAssertEqual(live.fallbackString, source)
        XCTAssertLessThanOrEqual(
            live.fallbackString.utf8.count,
            TranscriptRowProjection.maximumDisplayBytes
        )
    }

    func testHostedCodeRowsKeepMonospacedFontDuringLiveScroll() throws {
        for (id, role, isStreaming) in [
            ("streaming-code", ChatMessageRole.assistant, true),
            ("user-code", ChatMessageRole.user, false),
        ] {
            var message = ChatMessage(
                id: id,
                role: role,
                text: "let value = 42",
                isStreaming: isStreaming
            )
            message.contents = [
                MessageContent(
                    id: "\(id):content:0",
                    kind: .code,
                    text: "let value = 42",
                    language: "swift",
                    isComplete: !isStreaming
                )
            ]
            let item = ConversationItem.message(message)
            let row = try XCTUnwrap(makeMacTranscriptRows(
                item: item,
                projections: TranscriptRowProjection.makeRows(item: item),
                isExpanded: false,
                copiedItemID: nil,
                sectionRevision: 1
            ).first)

            let live = try XCTUnwrap(row.liveScrollTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ))
            let font = try XCTUnwrap(live.fallbackFont)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.monoSpace))
        }
    }

    func testLiveScrollHeaderOnlyToolStaysVisibleAndControlSized() throws {
        let tool = ToolActivity(
            id: "waiting-tool",
            turnID: "turn",
            kind: .shell,
            title: "Run command",
            status: .running,
            input: nil,
            output: nil,
            errorMessage: nil,
            durationMilliseconds: nil,
            exitCode: nil,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        )
        let item = ConversationItem.tool(tool)
        let row = try XCTUnwrap(makeMacTranscriptRows(
            item: item,
            projections: TranscriptRowProjection.makeRows(item: item),
            isExpanded: true,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)

        let live = try XCTUnwrap(row.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        XCTAssertTrue(live.fallbackString.contains("Run command"))
        XCTAssertEqual(
            TranscriptTextProjection.logicalLineCount(live.fallbackString),
            1
        )
        XCTAssertEqual(
            live.minimumTextContainerHeight,
            ChatTypography.activityLineHeight
        )
        XCTAssertLessThanOrEqual(
            live.fallbackString.utf8.count,
            TranscriptRowProjection.maximumDisplayBytes
        )
    }

    func testCollapsedDisclosureLiveScrollDoesNotRealizeHiddenBody() throws {
        let hiddenOutput = String(repeating: "hidden line\n", count: 127)
        let tool = ToolActivity(
            id: "collapsed-tool",
            turnID: "turn",
            kind: .shell,
            title: "Run bounded command",
            status: .completed,
            input: nil,
            output: hiddenOutput,
            errorMessage: nil,
            durationMilliseconds: nil,
            exitCode: 0,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        )
        let item = ConversationItem.tool(tool)
        let projection = try XCTUnwrap(
            TranscriptRowProjection.makeFirstRow(item: item)
        ).row
        let row = try XCTUnwrap(makeMacTranscriptRows(
            item: item,
            projections: [projection],
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)

        let live = try XCTUnwrap(row.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        XCTAssertTrue(live.fallbackString.contains("Run bounded command"))
        XCTAssertFalse(live.fallbackString.contains("hidden line"))
        XCTAssertEqual(
            TranscriptTextProjection.logicalLineCount(live.fallbackString),
            1
        )
        XCTAssertEqual(
            live.minimumTextContainerHeight,
            ChatTypography.activityLineHeight
        )
    }

    func testLiveScrollSemanticHeaderNeverExceedsProjectionLineBudget() throws {
        let source = String(repeating: "line\n", count: 127)
        let tool = ToolActivity(
            id: "line-dense-tool",
            turnID: "turn",
            kind: .shell,
            title: String(repeating: "provider title\n", count: 40),
            status: .completed,
            input: source,
            output: nil,
            errorMessage: nil,
            durationMilliseconds: nil,
            exitCode: 0,
            occurredAt: nil,
            isTruncated: false,
            originalByteCount: nil
        )
        let item = ConversationItem.tool(tool)
        let projection = try XCTUnwrap(
            TranscriptRowProjection.makeRows(item: item).first {
                $0.section == .toolInput
            }
        )
        let row = try XCTUnwrap(makeMacTranscriptRows(
            item: item,
            projections: [projection],
            isExpanded: true,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)

        let live = try XCTUnwrap(row.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        XCTAssertEqual(live.fallbackString, projection.sourceText)
        XCTAssertLessThanOrEqual(
            1 + live.fallbackString.utf8.filter { $0 == 0x0A }.count,
            TranscriptRowProjection.maximumDisplayLines
        )
    }

    func testLiveScrollSemanticHeaderBoundsHugeExtendedGraphemeByBytes() throws {
        let hugeGrapheme = "a" + String(repeating: "\u{301}", count: 50_000)
        let item = ConversationItem.generic(
            ChatGenericItem(
                id: "huge-generic-header",
                turnID: nil,
                type: hugeGrapheme,
                title: hugeGrapheme,
                detail: "exact body",
                occurredAt: nil
            )
        )
        let projection = try XCTUnwrap(
            TranscriptRowProjection.makeRows(item: item).first
        )
        let row = try XCTUnwrap(makeMacTranscriptRows(
            item: item,
            projections: [projection],
            isExpanded: true,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)

        let live = try XCTUnwrap(row.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        // The compact activity line bounds bytes even when the source hides
        // kilobytes inside one extended grapheme cluster.
        XCTAssertLessThanOrEqual(live.fallbackString.utf8.count, 256)
        XCTAssertEqual(
            TranscriptTextProjection.logicalLineCount(live.fallbackString),
            1
        )
        XCTAssertEqual(
            live.minimumTextContainerHeight,
            ChatTypography.activityLineHeight
        )
    }

    func testLiveGenericHeaderPreservesExactBoundaryAndControlBytes() throws {
        let type = "  provider\ttype\u{000B}"
        let titleBudget = TranscriptRowProjection.maximumDisplayBytes
            - type.utf8.count
            - 1
        let titlePrefix = " title\twith\u{000B}controls\n"
        let title = titlePrefix
            + String(repeating: "x", count: titleBudget - titlePrefix.utf8.count)
        let item = ConversationItem.generic(
            ChatGenericItem(
                id: "exact-generic-header",
                turnID: nil,
                type: type,
                title: title,
                detail: "exact body",
                occurredAt: nil
            )
        )
        let projection = try XCTUnwrap(
            TranscriptRowProjection.makeRows(item: item).first
        )
        guard case .generic(let displayed) = projection.displayItem else {
            return XCTFail("Expected bounded generic header")
        }
        let row = try XCTUnwrap(makeMacTranscriptRows(
            item: item,
            projections: [projection],
            isExpanded: true,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)
        let live = try XCTUnwrap(row.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))

        XCTAssertEqual(projection.rowText, title)
        XCTAssertEqual(displayed.type, type)
        // The compact activity line flattens provider whitespace and control
        // separators into single spaces and truncates to one bounded line —
        // exactly what the hosted single-line row renders.
        XCTAssertTrue(live.fallbackString.hasPrefix("title with controls"))
        XCTAssertFalse(live.fallbackString.contains("\n"))
        XCTAssertFalse(live.fallbackString.contains("\t"))
        XCTAssertTrue(live.fallbackString.hasSuffix("…"))
        XCTAssertLessThanOrEqual(live.fallbackString.utf8.count, 256)
        XCTAssertEqual(
            TranscriptTextProjection.logicalLineCount(live.fallbackString),
            1
        )
    }

    func testLiveScrollCopyPreservesNativeParagraphGeometry() throws {
        let codeText = String(repeating: "let value = 42\n", count: 80)
        var codeMessage = ChatMessage(
            id: "paragraph-code",
            role: .assistant,
            text: codeText
        )
        codeMessage.contents = [
            MessageContent(
                id: "paragraph-code:content:0",
                kind: .code,
                text: codeText,
                language: "swift"
            )
        ]
        let codeItem = ConversationItem.message(codeMessage)
        let codeRow = try XCTUnwrap(makeMacTranscriptRows(
            item: codeItem,
            projections: TranscriptRowProjection.makeRows(item: codeItem),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)
        let ordinaryCode = try XCTUnwrap(codeRow.nativeTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        let liveCode = try XCTUnwrap(codeRow.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        XCTAssertEqual(liveCode.fallbackParagraphStyle?.lineSpacing, 3)
        XCTAssertEqual(
            liveCode.fallbackParagraphStyle?.lineBreakMode,
            .byCharWrapping
        )
        XCTAssertEqual(
            measuredTextHeight(liveCode),
            measuredTextHeight(ordinaryCode),
            accuracy: 1
        )

        let detail = String(repeating: "wrapping generic detail ", count: 80)
        let genericItem = ConversationItem.generic(
            ChatGenericItem(
                id: "paragraph-generic",
                turnID: nil,
                type: "activity",
                title: "Activity",
                detail: detail,
                occurredAt: nil
            )
        )
        let detailProjection = try XCTUnwrap(
            TranscriptRowProjection.makeRows(item: genericItem).first {
                $0.section == .generic
            }
        )
        let detailRow = try XCTUnwrap(makeMacTranscriptRows(
            item: genericItem,
            projections: [detailProjection],
            isExpanded: true,
            copiedItemID: nil,
            sectionRevision: 1
        ).first)
        let ordinaryDetail = try XCTUnwrap(detailRow.nativeTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        let liveDetail = try XCTUnwrap(detailRow.liveScrollTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
        XCTAssertEqual(liveDetail.fallbackParagraphStyle?.headIndent, 23)
        XCTAssertEqual(liveDetail.fallbackParagraphStyle?.firstLineHeadIndent, 23)
        XCTAssertEqual(
            measuredTextHeight(liveDetail),
            measuredTextHeight(ordinaryDetail),
            accuracy: 1
        )
    }

    func testStreamingTailHasExactDisplayOnlyPresentationDuringLiveScroll() throws {
        let source = String(repeating: "streaming exact text ", count: 200)
        let item = ConversationItem.message(
            ChatMessage(
                id: "streaming-display",
                role: .assistant,
                text: source,
                isStreaming: true
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
        for (index, row) in rows.enumerated() {
            guard case .item = row else { continue }
            if row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .dark
            ) == nil {
                let live = try XCTUnwrap(row.liveScrollTextPresentation(
                    dynamicTypeSize: .large,
                    colorScheme: .dark
                ))
                XCTAssertEqual(live.fallbackString, projections[index].sourceText)
                XCTAssertTrue(live.usesFastPlainTextRenderer)
            }
        }
        XCTAssertEqual(projections.map(\.sourceText).joined(), source)
    }

    func testCompletedCodeUsesSelectableNativeTilesWithoutDroppingSourceText() throws {
        let source = String(repeating: "let value = 42 // bounded code\n", count: 300)
        var message = ChatMessage(
            id: "assistant-code",
            role: .assistant,
            text: source,
            occurredAt: 1
        )
        message.contents = [
            MessageContent(
                id: "assistant-code:content:0",
                kind: .code,
                text: source,
                language: "swift"
            )
        ]
        let item = ConversationItem.message(message)
        let projections = TranscriptRowProjection.makeRows(item: item)
        XCTAssertGreaterThan(projections.count, 2)

        let rows = makeMacTranscriptRows(
            item: item,
            projections: projections,
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )
        XCTAssertEqual(rows.count, projections.count + 1)
        for (index, row) in rows.dropLast().enumerated() {
            let presentation = try XCTUnwrap(row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ))
            XCTAssertEqual(presentation.attributedString?.string, projections[index].sourceText)
            XCTAssertEqual(presentation.fallbackString, projections[index].sourceText)
            XCTAssertNotNil(presentation.backgroundColor)
            XCTAssertEqual(presentation.backgroundCornerRadius, 12)
            XCTAssertEqual(presentation.horizontalAlignment, .fill)
            XCTAssertTrue(presentation.usesFastPlainTextRenderer)
            XCTAssertEqual(presentation.textEdgeInsets.left, 12)
            XCTAssertEqual(presentation.textEdgeInsets.right, 12)
            XCTAssertEqual(
                presentation.roundedCorners.contains(.topLeading),
                index == 0
            )
            XCTAssertEqual(
                presentation.roundedCorners.contains(.bottomLeading),
                index == projections.count - 1
            )
        }
        XCTAssertEqual(projections.map(\.sourceText).joined(), source)
    }

    func testStreamingCodeKeepsOnlyChangingTailHosted() {
        let source = String(repeating: "streaming code line\n", count: 500)
        var message = ChatMessage(
            id: "streaming-code",
            role: .assistant,
            text: source,
            isStreaming: true
        )
        message.contents = [
            MessageContent(
                id: "streaming-code:content:0",
                kind: .code,
                text: source,
                language: "swift",
                isComplete: false
            )
        ]
        let item = ConversationItem.message(message)
        let rows = makeMacTranscriptRows(
            item: item,
            projections: TranscriptRowProjection.makeRows(item: item),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )
        XCTAssertGreaterThan(rows.count, 2)
        XCTAssertTrue(rows.dropLast().allSatisfy {
            $0.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ) != nil
        })
        XCTAssertNil(rows.last?.nativeTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
    }

    func testCompletedUserCodeKeepsHostedBubbleComposition() {
        let source = String(repeating: "user code line\n", count: 200)
        var message = ChatMessage(
            id: "user-code",
            role: .user,
            text: source,
            occurredAt: 1
        )
        message.contents = [
            MessageContent(
                id: "user-code:content:0",
                kind: .code,
                text: source,
                language: "swift"
            )
        ]
        let item = ConversationItem.message(message)
        let projections = TranscriptRowProjection.makeRows(item: item)
        let rows = makeMacTranscriptRows(
            item: item,
            projections: projections,
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )

        XCTAssertEqual(rows.count, projections.count + 1)
        XCTAssertTrue(rows.dropLast().allSatisfy {
            $0.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ) == nil
        })
        XCTAssertNotNil(rows.last?.nativeFooterPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ))
    }

    func testStableExpandedToolAndDiffBodiesUseNativeTailTiles() {
        let source = String(repeating: "bounded output line\n", count: 250)
        let input = String(repeating: "bounded input line\n", count: 250)
        let tool = ConversationItem.tool(
            ToolActivity(
                id: "tool-native-tail",
                turnID: "turn",
                kind: .shell,
                title: "Run command",
                status: .completed,
                input: input,
                output: source,
                errorMessage: nil,
                durationMilliseconds: 1,
                exitCode: 0,
                occurredAt: 1,
                isTruncated: false,
                originalByteCount: nil
            )
        )
        let diff = ConversationItem.diff(
            ChatDiff(
                id: "diff-native-tail",
                turnID: "turn",
                path: "Fixture.swift",
                unifiedDiff: source,
                occurredAt: 1,
                isTruncated: false
            )
        )

        for item in [tool, diff] {
            let projections = TranscriptRowProjection.makeRows(item: item)
            XCTAssertGreaterThan(projections.count, 2)
            let expanded = makeMacTranscriptRows(
                item: item,
                projections: projections,
                isExpanded: true,
                copiedItemID: nil,
                sectionRevision: 1
            )
            for (index, row) in expanded.enumerated() {
                let presentation = row.nativeTextPresentation(
                    dynamicTypeSize: .large,
                    colorScheme: .light
                )
                let projection = projections[index]
                let shouldUseNativeText: Bool
                switch item {
                case .tool:
                    shouldUseNativeText = !projection.isFirstInItem
                        && !projection.isFirstInSection
                case .diff:
                    shouldUseNativeText = !projection.isFirstInItem
                default:
                    shouldUseNativeText = false
                }
                if shouldUseNativeText {
                    XCTAssertNotNil(presentation)
                    XCTAssertEqual(
                        presentation?.fallbackString,
                        projection.sourceText
                    )
                } else {
                    XCTAssertNil(
                        presentation,
                        "Disclosure and tool-section headers must retain their hosted controls."
                    )
                }
            }

            let collapsed = makeMacTranscriptRows(
                item: item,
                projections: projections,
                isExpanded: false,
                copiedItemID: nil,
                sectionRevision: 1
            )
            XCTAssertTrue(collapsed.allSatisfy {
                $0.nativeTextPresentation(
                    dynamicTypeSize: .large,
                    colorScheme: .light
                ) == nil
            })
        }

        guard case .tool(var runningTool) = tool else {
            return XCTFail("Expected tool fixture.")
        }
        runningTool.status = .running
        let runningItem = ConversationItem.tool(runningTool)
        let runningRows = makeMacTranscriptRows(
            item: runningItem,
            projections: TranscriptRowProjection.makeRows(item: runningItem),
            isExpanded: true,
            copiedItemID: nil,
            sectionRevision: 1
        )
        XCTAssertTrue(runningRows.allSatisfy {
            $0.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ) == nil
        })
    }

    func testFooterDecisionDoesNotMaterializeAChunkedMessage() throws {
        var message = ChatMessage(
            id: "chunked-footer",
            role: .assistant,
            text: "",
            isStreaming: true
        )
        for _ in 0..<128 {
            message.append(String(repeating: "f", count: 1_024))
        }
        message.complete(text: nil)
        XCTAssertFalse(try XCTUnwrap(message.contents.first).isTextStorageMaterialized)

        let rows = makeMacTranscriptRows(
            item: .message(message),
            projections: [],
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )

        XCTAssertEqual(rows.count, 1)
        guard case .messageFooter = rows.first else {
            return XCTFail("Expected the structural footer row.")
        }
        XCTAssertFalse(
            try XCTUnwrap(message.contents.first).isTextStorageMaterialized,
            "Discovering a footer must not join the complete message on the UI actor."
        )
    }

    func testStreamingMessageRemainsHostedButCompletedUserUsesNativeBubbleAndFooter() {
        let streaming = ConversationItem.message(
            ChatMessage(
                id: "streaming",
                role: .assistant,
                text: "still changing",
                isStreaming: true
            )
        )
        let userSource = String(repeating: "user bubble text\n", count: 200)
        let user = ConversationItem.message(
            ChatMessage(
                id: "user",
                role: .user,
                text: userSource,
                occurredAt: 1
            )
        )

        let streamingRows = makeMacTranscriptRows(
            item: streaming,
            projections: TranscriptRowProjection.makeRows(item: streaming),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        )
        XCTAssertTrue(streamingRows.allSatisfy { row in
            guard case .item = row else { return false }
            return row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ) == nil
        })

        let userProjections = TranscriptRowProjection.makeRows(item: user)
        let userRows = makeMacTranscriptRows(
            item: user,
            projections: userProjections,
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 2
        )
        XCTAssertEqual(userRows.count, userProjections.count + 1)
        for (index, row) in userRows.dropLast().enumerated() {
            guard let presentation = row.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            ) else {
                return XCTFail("Every stable user text tile must bypass NSHostingView.")
            }
            XCTAssertEqual(presentation.maximumContentWidth, 760)
            XCTAssertEqual(presentation.maximumTextWidth, 640)
            XCTAssertEqual(presentation.horizontalAlignment, .trailing)
            XCTAssertNotNil(presentation.backgroundColor)
            XCTAssertEqual(presentation.backgroundCornerRadius, 16)
            XCTAssertFalse(
                presentation.hugsTextWidth,
                "A segment of a divided message shares the bubble width."
            )
            if index == 0 {
                XCTAssertTrue(presentation.roundedCorners.contains(.topLeading))
                XCTAssertTrue(presentation.roundedCorners.contains(.topTrailing))
            } else {
                XCTAssertFalse(presentation.roundedCorners.contains(.topLeading))
                XCTAssertFalse(presentation.roundedCorners.contains(.topTrailing))
            }
            if index == userProjections.count - 1 {
                XCTAssertTrue(presentation.roundedCorners.contains(.bottomLeading))
                XCTAssertTrue(presentation.roundedCorners.contains(.bottomTrailing))
            } else {
                XCTAssertFalse(presentation.roundedCorners.contains(.bottomLeading))
                XCTAssertFalse(presentation.roundedCorners.contains(.bottomTrailing))
            }
        }
        guard case .messageFooter(let footer, let revision) = userRows.last else {
            return XCTFail("Expected one separate user action footer.")
        }
        XCTAssertEqual(footer.itemID, "user")
        XCTAssertEqual(footer.role, .user)
        XCTAssertEqual(revision, 2)
        let nativeFooter = userRows.last?.nativeFooterPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        )
        XCTAssertEqual(nativeFooter?.itemID, "user")
        XCTAssertEqual(nativeFooter?.isTrailing, true)
        XCTAssertEqual(userProjections.map(\.sourceText).joined(), userSource)

        let short = ConversationItem.message(
            ChatMessage(id: "short-user", role: .user, text: "hello", occurredAt: 2)
        )
        let shortProjections = TranscriptRowProjection.makeRows(item: short)
        XCTAssertEqual(shortProjections.count, 1)
        let shortRows = makeMacTranscriptRows(
            item: short,
            projections: shortProjections,
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 3
        )
        XCTAssertEqual(
            shortRows.first?.nativeTextPresentation(
                dynamicTypeSize: .large,
                colorScheme: .light
            )?.hugsTextWidth,
            true,
            "An undivided user message must size its bubble to the text."
        )
    }

    func testNativeFooterUsesReusableAppKitControlsAndRoutesCopy() throws {
        let row = FooterRow(
            id: "message:footer",
            contentRevision: 1,
            itemID: "message",
            isTrailing: true
        )
        var copiedItemID: String?
        var hostedBuilds = 0
        let hosting = NSHostingView(
            rootView: MacConversationTableView(
                sections: [
                    MacConversationTableSection(
                        id: "message",
                        revision: 1,
                        rows: [row]
                    )
                ],
                snapshotGeneration: "generation",
                reduceMotion: true,
                commandHandle: MacConversationTableCommandHandle(),
                onNearBottomChange: { _ in },
                onAnchoredChange: { _ in },
                onNativeCopyMessage: { copiedItemID = $0 },
                makeRow: { _, _, _ in
                    hostedBuilds += 1
                    return AnyView(Text("Hosted fallback"))
                }
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 300),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        settle(hosting)

        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let cell = try XCTUnwrap(
            table.view(atColumn: 0, row: 0, makeIfNecessary: true)
        )
        XCTAssertNil(descendant(of: cell, type: NSHostingView<AnyView>.self))
        XCTAssertEqual(hostedBuilds, 0)
        let controls = try XCTUnwrap(descendant(of: cell, type: NSStackView.self))
        XCTAssertEqual(
            controls.alphaValue,
            0,
            "Footer controls stay hidden until the pointer reveals them."
        )
        let button = try XCTUnwrap(descendant(of: cell, type: NSButton.self))
        XCTAssertGreaterThanOrEqual(button.frame.width, 22)
        XCTAssertGreaterThanOrEqual(button.frame.height, 22)
        button.performClick(nil)
        XCTAssertEqual(copiedItemID, "message")
        XCTAssertEqual(button.accessibilityLabel(), "Message copied")
    }

    func testCompletedAssistantNativeFallbackTracksDynamicType() {
        let source = "dynamic-type-\(UUID().uuidString)"
        let item = ConversationItem.message(
            ChatMessage(id: "assistant-scale", role: .assistant, text: source)
        )
        guard let row = makeMacTranscriptRows(
            item: item,
            projections: TranscriptRowProjection.makeRows(item: item),
            isExpanded: false,
            copiedItemID: nil,
            sectionRevision: 1
        ).first,
        let regular = row.nativeTextPresentation(
            dynamicTypeSize: .large,
            colorScheme: .light
        ),
        let accessibility = row.nativeTextPresentation(
            dynamicTypeSize: .accessibility1,
            colorScheme: .light
        ) else {
            return XCTFail("Expected native completed assistant text.")
        }

        XCTAssertGreaterThan(
            accessibility.fallbackFont?.pointSize ?? 0,
            regular.fallbackFont?.pointSize ?? .infinity
        )
        XCTAssertNotNil(regular.deferredAttributedString)
        XCTAssertNotNil(accessibility.deferredAttributedString)
    }

    func testNativeReuseClearsAccessibilityIdentifierWhenPresentationOmitsIt() {
        var rows = [
            MixedRow(
                id: "native-reuse",
                contentRevision: 1,
                text: "First",
                usesNativeText: true,
                nativeAccessibilityIdentifier: "native.first"
            )
        ]
        let mounted = mountMixed(rows: rows)
        let originalCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        XCTAssertEqual(
            descendant(of: originalCell, type: NSTextView.self)?
                .accessibilityIdentifier(),
            "native.first"
        )

        rows[0] = MixedRow(
            id: "native-reuse",
            contentRevision: 2,
            text: "Second",
            usesNativeText: true
        )
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)

        let reusedCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        XCTAssertTrue(originalCell === reusedCell)
        XCTAssertTrue(
            descendant(of: reusedCell, type: NSTextView.self)?
                .accessibilityIdentifier().isEmpty ?? true
        )
    }

    func testOneRowCanTransitionBetweenHostedAndNativeWithoutFullReload() {
        var rows = [
            MixedRow(
                id: "transition",
                contentRevision: 1,
                text: "Hosted first",
                usesNativeText: false
            )
        ]
        let mounted = mountMixed(rows: rows)
        let originalHostedCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        XCTAssertNotNil(
            descendant(of: originalHostedCell, type: NSHostingView<AnyView>.self)
        )

        MacConversationTableDiagnostics.reset()
        rows[0] = MixedRow(
            id: "transition",
            contentRevision: 2,
            text: "Native second",
            usesNativeText: true
        )
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)

        let nativeCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        var diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 1)
        XCTAssertFalse(originalHostedCell === nativeCell)
        XCTAssertEqual(
            descendant(of: nativeCell, type: NSTextView.self)?.string,
            "Native second"
        )

        MacConversationTableDiagnostics.reset()
        rows[0] = MixedRow(
            id: "transition",
            contentRevision: 3,
            text: "Hosted third",
            usesNativeText: false
        )
        mounted.hosting.rootView = mixedTable(rows: rows)
        settle(mounted.hosting)

        let finalHostedCell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        diagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.targetedRowReloads, 1)
        XCTAssertFalse(nativeCell === finalHostedCell)
        XCTAssertNotNil(
            descendant(of: finalHostedCell, type: NSHostingView<AnyView>.self)
        )
    }

    func testNativeMountedRowsRemainViewportBoundedAsHistoryGrows() {
        let hundred = mountMixed(rows: makeMixedRows(count: 100))
        let hundredMounted = mountedRowCount(in: hundred.table)
        let hundredVisible = visibleRowCount(in: hundred.table)
        XCTAssertGreaterThan(hundredMounted, 0)
        XCTAssertLessThanOrEqual(hundredMounted, hundredVisible + 12)

        let thousand = mountMixed(rows: makeMixedRows(count: 1_000))
        let thousandMounted = mountedRowCount(in: thousand.table)
        let thousandVisible = visibleRowCount(in: thousand.table)
        XCTAssertGreaterThan(thousandMounted, 0)
        XCTAssertLessThanOrEqual(thousandMounted, thousandVisible + 12)
        XCTAssertLessThanOrEqual(abs(thousandMounted - hundredMounted), 2)
    }

    func testColdNativeMountMeasuresHeightOnlyAfterConstrainedWidthIsKnown() {
        let text = (0..<30).map {
            "Line \($0) has enough text to exercise the bounded native layout width."
        }.joined(separator: "\n")
        let mounted = mountMixed(rows: [
            MixedRow(
                id: "cold-native",
                contentRevision: 1,
                text: text,
                usesNativeText: true
            )
        ])
        let cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let textView = descendant(of: cell, type: NSTextView.self)!
        let rowHeight = mounted.table.rect(ofRow: 0).height

        XCTAssertEqual(textView.frame.width, 320, accuracy: 1)
        XCTAssertGreaterThan(textView.intrinsicContentSize.height, 100)
        XCTAssertGreaterThan(rowHeight, 100)
        XCTAssertLessThan(
            rowHeight,
            2_000,
            "Cold mounting must never measure the tile against a provisional one-point width"
        )
    }

    func testTrailingNativeBubbleAlignsInsideCenteredTranscriptWidth() {
        let mounted = mountMixed(
            rows: [
                MixedRow(
                    id: "trailing-bubble",
                    contentRevision: 1,
                    text: "Short user message",
                    usesNativeText: true,
                    maximumContentWidth: 760,
                    maximumTextWidth: 640,
                    hugsTextWidth: true,
                    horizontalAlignment: .trailing,
                    backgroundCornerRadius: 16
                )
            ],
            windowWidth: 1_200
        )
        let cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let textView = try! XCTUnwrap(
            descendant(of: cell, type: NSTextView.self)
        )

        XCTAssertLessThanOrEqual(textView.frame.width, 640.5)
        XCTAssertLessThan(
            textView.frame.width,
            240,
            "A short user message must hug its text, not stretch the bubble to the 640-point limit."
        )
        XCTAssertEqual(
            textView.convert(textView.bounds, to: cell).maxX,
            cell.bounds.midX + 380,
            accuracy: 1,
            "The user bubble must trail the centered 760-point transcript, not the window edge."
        )
        XCTAssertEqual(textView.superview?.layer?.cornerRadius, 16)
    }

    func testSegmentedBubbleTilesKeepOneSharedWidth() throws {
        let mounted = mountMixed(
            rows: (0..<2).map { index in
                MixedRow(
                    id: "segment-\(index)",
                    contentRevision: 1,
                    text: index == 0
                        ? "A first bubble segment that is clearly the wider one"
                        : "short tail",
                    usesNativeText: true,
                    maximumContentWidth: 760,
                    maximumTextWidth: 640,
                    horizontalAlignment: .trailing,
                    backgroundCornerRadius: 16
                )
            },
            windowWidth: 1_200
        )
        let widths = try (0..<2).map { row -> CGFloat in
            let cell = mounted.table.view(
                atColumn: 0,
                row: row,
                makeIfNecessary: true
            )!
            return try XCTUnwrap(
                descendant(of: cell, type: NSTextView.self)
            ).frame.width
        }

        XCTAssertEqual(
            widths[0],
            640,
            accuracy: 0.5,
            "A tile that is only part of a message must fill the shared bubble width."
        )
        XCTAssertEqual(
            widths[0],
            widths[1],
            accuracy: 0.5,
            "Segments of one message must not come out ragged."
        )
    }

    func testTrailingLiveScrollBubbleKeepsTheHuggedWidth() throws {
        let row = MixedRow(
            id: "trailing-bubble",
            contentRevision: 1,
            text: "Short user message",
            usesNativeText: true,
            maximumContentWidth: 760,
            maximumTextWidth: 640,
            hugsTextWidth: true,
            horizontalAlignment: .trailing,
            backgroundCornerRadius: 16
        )
        let mounted = mountMixed(rows: [row], windowWidth: 1_200)
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: mounted.table.enclosingScrollView!
        )
        mounted.hosting.rootView = mixedTable(rows: [
            MixedRow(
                id: "trailing-bubble",
                contentRevision: 2,
                text: "Short user message",
                usesNativeText: true,
                maximumContentWidth: 760,
                maximumTextWidth: 640,
                hugsTextWidth: true,
                horizontalAlignment: .trailing,
                backgroundCornerRadius: 16
            )
        ])
        mounted.hosting.needsLayout = true
        mounted.hosting.layoutSubtreeIfNeeded()
        let cell = mounted.table.view(
            atColumn: 0,
            row: 0,
            makeIfNecessary: true
        )!
        let scrollTextView = try XCTUnwrap(
            descendant(of: cell, type: MacConversationScrollTextView.self)
        )
        let bubble = try XCTUnwrap(scrollTextView.superview)

        XCTAssertLessThan(
            bubble.frame.width,
            240,
            "The live-scroll bubble must hug its text, not widen to 640 mid-gesture."
        )
        XCTAssertEqual(
            bubble.convert(bubble.bounds, to: cell).maxX,
            cell.bounds.midX + 380,
            accuracy: 1,
            "The live-scroll bubble must trail the centered 760-point transcript."
        )
    }

    func testNativeGlobalEdgeAdjustmentsApplyOnlyAtTranscriptEdges() {
        let text = (0..<10).map { "Line \($0)" }.joined(separator: "\n")
        let plain = mountMixed(rows: [
            MixedRow(
                id: "plain-edge",
                contentRevision: 1,
                text: text,
                usesNativeText: true
            )
        ])
        let adjusted = mountMixed(rows: [
            MixedRow(
                id: "adjusted-edge",
                contentRevision: 1,
                text: text,
                usesNativeText: true,
                firstRowTopInsetAdjustment: 15,
                lastRowBottomInsetAdjustment: 9
            )
        ])

        XCTAssertEqual(
            adjusted.table.rect(ofRow: 0).height
                - plain.table.rect(ofRow: 0).height,
            24,
            accuracy: 1
        )
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

    func testViewportPrefetchIsBoundedAndSmallScrollsStayInsideWarmBand() {
        let rows = makeRows(count: 300)
        var prefetchedBatches: [[String]] = []
        let mounted = mount(
            rows: rows,
            prefetchRows: { prefetchedBatches.append($0.map(\.id)) }
        )
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }

        // Move away from either transcript boundary so the full explicit
        // overscan is available on both sides of the viewport. This models
        // user scrolling, so declare it through the input funnel.
        markUserScrollInput(in: mounted.table)
        prefetchedBatches.removeAll()
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = mounted.table.rect(ofRow: 100).minY
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(visible.location, NSNotFound)
        let visibleLower = visible.location
        let visibleUpper = NSMaxRange(visible)
        let overscan = 24
        let expectedRange = (visibleLower - overscan)..<(visibleUpper + overscan)
        let expectedIDs = Set(rows[expectedRange].map(\.id))
        let prefetchedIDs = prefetchedBatches.last ?? []

        XCTAssertEqual(prefetchedBatches.count, 1)
        XCTAssertEqual(prefetchedIDs.count, visible.length + (overscan * 2))
        XCTAssertEqual(Set(prefetchedIDs), expectedIDs)
        XCTAssertEqual(
            Array(prefetchedIDs.prefix(visible.length)),
            rows[visibleLower..<visibleUpper].map(\.id),
            "Visible rows should be prioritized before their bounded overscan"
        )

        let batchCount = prefetchedBatches.count
        proposed = scrollView.contentView.bounds
        proposed.origin.y = mounted.table.rect(ofRow: visibleLower - 1).minY
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let shiftedVisible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertEqual(shiftedVisible.location, visibleLower - 1)
        XCTAssertEqual(
            prefetchedBatches.count,
            batchCount,
            "A same-direction one-row scroll inside the warmed band must not enqueue another batch"
        )

        // Reverse while the visible rows are still well inside the existing
        // 24-row band. The stale task must be cancelled and reordered even
        // though the set of warm candidates is already covered.
        proposed = scrollView.contentView.bounds
        proposed.origin.y = mounted.table.rect(ofRow: visibleLower + 1).minY
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let reversedVisible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertEqual(reversedVisible.location, visibleLower + 1)
        XCTAssertEqual(prefetchedBatches.count, batchCount + 1)
        let reversedIDs = prefetchedBatches.last ?? []
        XCTAssertEqual(
            reversedIDs.dropFirst(reversedVisible.length).first,
            rows[NSMaxRange(reversedVisible)].id,
            "An in-band reversal must immediately prioritize the row now ahead of the gesture"
        )

        proposed = scrollView.contentView.bounds
        proposed.origin.y = mounted.table.rect(ofRow: visibleLower + 40).minY
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let laterVisible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(laterVisible.location, NSNotFound)
        let laterVisibleUpper = NSMaxRange(laterVisible)
        let laterIDs = prefetchedBatches.last ?? []
        XCTAssertEqual(
            Array(laterIDs.prefix(laterVisible.length)),
            rows[laterVisible.location..<laterVisibleUpper].map(\.id)
        )
        XCTAssertEqual(
            laterIDs.dropFirst(laterVisible.length).first,
            rows[laterVisibleUpper].id,
            "A direction reversal must warm the next newer row before rows behind the gesture"
        )
    }

    func testScrollActivityWaitersResumeOnlyAfterLiveScrollEnds() async {
        let activity = MacTranscriptScrollActivity()
        var heightChangePreparations = 0
        activity.setHeightChangeHandler {
            heightChangePreparations += 1
        }
        activity.setLiveScrolling(true)
        var startedWaiters: Set<Int> = []
        var resumedWaiters: Set<Int> = []

        let first = Task { @MainActor in
            startedWaiters.insert(1)
            await activity.adoptHeightChangingContentWhenIdle {
                resumedWaiters.insert(1)
            }
        }
        let second = Task { @MainActor in
            startedWaiters.insert(2)
            await activity.adoptHeightChangingContentWhenIdle {
                resumedWaiters.insert(2)
            }
        }

        while startedWaiters.count < 2 {
            await Task.yield()
        }
        // Give both same-actor calls a chance to reach their continuations;
        // this is an executor turn, not a wall-clock timing assertion.
        await Task.yield()
        XCTAssertTrue(resumedWaiters.isEmpty)
        XCTAssertEqual(heightChangePreparations, 0)

        activity.setLiveScrolling(false)
        await first.value
        await second.value

        XCTAssertEqual(resumedWaiters, [1, 2])
        XCTAssertEqual(
            heightChangePreparations,
            1,
            """
            Ready adoptions land in one batch under a single viewport anchor \
            capture, matching the batched live-scroll restoration pass; a \
            per-row capture went with the per-row ripple this replaced.
            """
        )
    }

    func testDeferredNativeArtifactResolvesOnlyAfterLiveScrollEnds() async {
        let activity = MacTranscriptScrollActivity()
        activity.setLiveScrolling(true)
        var resolveCount = 0
        let artifact = MacConversationNativeTextPresentation.DeferredArtifact {
            resolveCount += 1
            return NSAttributedString(string: "prepared")
        }

        let adoption = Task { @MainActor in
            await activity.adoptHeightChangingContentWhenIdle {
                _ = artifact.resolve()
            }
        }
        await Task.yield()
        XCTAssertEqual(
            resolveCount,
            0,
            "Main-actor attributed-string construction must not run during a live gesture."
        )

        activity.setLiveScrolling(false)
        await adoption.value
        XCTAssertEqual(resolveCount, 1)
    }

    func testCancelledScrollActivityAdoptionIsRemovedBeforeIdle() async {
        let activity = MacTranscriptScrollActivity()
        activity.setLiveScrolling(true)
        var didAdopt = false
        let task = Task { @MainActor in
            await activity.adoptHeightChangingContentWhenIdle {
                didAdopt = true
            }
        }

        await Task.yield()
        task.cancel()
        await task.value
        activity.setLiveScrolling(false)
        await Task.yield()

        XCTAssertFalse(didAdopt)
    }

    func testCancelledAdoptionCannotRaceImmediateEndOfScroll() async {
        let activity = MacTranscriptScrollActivity()
        activity.setLiveScrolling(true)
        var didStart = false
        var didAdopt = false
        var heightChangePreparations = 0
        activity.setHeightChangeHandler {
            heightChangePreparations += 1
        }
        let task = Task { @MainActor in
            didStart = true
            await activity.adoptHeightChangingContentWhenIdle {
                didAdopt = true
            }
        }

        while !didStart {
            await Task.yield()
        }
        await Task.yield()
        task.cancel()
        // Do not yield to the main-actor removal task. This is the ordering a
        // recycled cell can hit when momentum ends in the same run-loop turn.
        activity.setLiveScrolling(false)
        await task.value

        XCTAssertFalse(didAdopt)
        XCTAssertEqual(heightChangePreparations, 0)
    }

    func testTearingDownScrollActivityDropsEveryPendingAdoption() async {
        let activity = MacTranscriptScrollActivity()
        activity.setLiveScrolling(true)
        var startedRows: Set<Int> = []
        var adoptedRows: [Int] = []
        let first = Task { @MainActor in
            startedRows.insert(1)
            await activity.adoptHeightChangingContentWhenIdle {
                adoptedRows.append(1)
            }
        }
        let second = Task { @MainActor in
            startedRows.insert(2)
            await activity.adoptHeightChangingContentWhenIdle {
                adoptedRows.append(2)
            }
        }

        while startedRows.count < 2 {
            await Task.yield()
        }
        await Task.yield()
        activity.cancelPendingAdoptions()
        activity.setLiveScrolling(false)
        await first.value
        await second.value

        XCTAssertTrue(adoptedRows.isEmpty)
    }

    func testNewLiveScrollKeepsRemainingAdoptionsQueued() async {
        let activity = MacTranscriptScrollActivity()
        activity.setLiveScrolling(true)
        var adoptions: [Int] = []
        let first = Task { @MainActor in
            await activity.adoptHeightChangingContentWhenIdle {
                adoptions.append(1)
                activity.setLiveScrolling(true)
            }
        }
        let second = Task { @MainActor in
            await activity.adoptHeightChangingContentWhenIdle {
                adoptions.append(2)
            }
        }

        await Task.yield()
        activity.setLiveScrolling(false)
        await first.value
        await Task.yield()
        XCTAssertEqual(adoptions, [1])

        activity.setLiveScrolling(false)
        await second.value
        XCTAssertEqual(adoptions, [1, 2])
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
        markUserScrollInput(in: mounted.table)
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

    func testDeferredPrependOwnsAnchorBeforeLiveScrollRestoration() throws {
        let original = (0..<200).map { index in
            MixedRow(
                id: "deferred-row-\(index)",
                contentRevision: 1,
                text: "Row \(index)",
                usesNativeText: false,
                usesLiveScrollText: true
            )
        }
        let mounted = mountMixed(rows: original)
        let scrollView = try XCTUnwrap(mounted.table.enclosingScrollView)
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        var proposed = scrollView.contentView.bounds
        proposed.origin.y = max(0, proposed.origin.y - 1_200)
        scrollView.contentView.setBoundsOrigin(
            scrollView.contentView.constrainBoundsRect(proposed).origin
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)

        let visible = mounted.table.rows(in: scrollView.contentView.bounds)
        XCTAssertNotEqual(visible.location, NSNotFound)
        let anchoredID = original[visible.location].id
        let anchoredOffset = mounted.table.rect(ofRow: visible.location).minY
            - scrollView.contentView.bounds.minY
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )

        let prepended = (0..<50).map { index in
            MixedRow(
                id: "deferred-older-\(index)",
                contentRevision: 1,
                text: "Older \(index)",
                usesNativeText: false,
                usesLiveScrollText: true
            )
        } + original
        mounted.hosting.rootView = mixedTable(rows: prepended)
        settle(mounted.hosting)
        waitForLiveScrollRestoration(
            in: mounted.table,
            hosting: mounted.hosting
        )

        let newIndex = try XCTUnwrap(
            prepended.firstIndex { $0.id == anchoredID }
        )
        let restoredOffset = mounted.table.rect(ofRow: newIndex).minY
            - scrollView.contentView.bounds.minY
        XCTAssertEqual(restoredOffset, anchoredOffset, accuracy: 1)
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

    func testAppendReconfiguresFormerAndNewGlobalLastRows() {
        var edgeStates: [String: String] = [:]
        var rows = makeRows(count: 20)
        let mounted = mount(rows: rows, onMakeRow: { row, isFirst, isLast in
            edgeStates[row.id] = "\(isFirst):\(isLast)"
        })
        let formerLastID = rows.last!.id
        XCTAssertEqual(edgeStates[formerLastID], "false:true")

        edgeStates.removeAll()
        let newLast = Row(id: "new-last", contentRevision: 1)
        rows.append(newLast)
        mounted.hosting.rootView = table(
            rows: rows,
            onMakeRow: { row, isFirst, isLast in
            edgeStates[row.id] = "\(isFirst):\(isLast)"
            }
        )
        settle(mounted.hosting)

        XCTAssertEqual(edgeStates[formerLastID], "false:false")
        XCTAssertEqual(edgeStates[newLast.id], "false:true")
    }

    func testPrependReconfiguresFormerAndNewGlobalFirstRows() {
        var edgeStates: [String: String] = [:]
        let original = makeRows(count: 20)
        let mounted = mount(rows: original, onMakeRow: { row, isFirst, isLast in
            edgeStates[row.id] = "\(isFirst):\(isLast)"
        })
        guard let scrollView = mounted.table.enclosingScrollView else {
            return XCTFail("Expected enclosing scroll view")
        }
        scrollView.contentView.setBoundsOrigin(.zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(mounted.hosting)
        let formerFirstID = original.first!.id
        XCTAssertEqual(edgeStates[formerFirstID], "true:false")

        edgeStates.removeAll()
        let newFirst = Row(id: "new-first", contentRevision: 1)
        let rows = [newFirst] + original
        mounted.hosting.rootView = table(
            rows: rows,
            onMakeRow: { row, isFirst, isLast in
            edgeStates[row.id] = "\(isFirst):\(isLast)"
            }
        )
        settle(mounted.hosting)

        XCTAssertEqual(edgeStates[formerFirstID], "false:false")
        XCTAssertEqual(edgeStates[newFirst.id], "true:false")
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

        markUserScrollInput(in: mounted.table)
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

    func testReleaseMixedConversationContinuousScrollPerformance() async throws {
        #if DEBUG
        throw XCTSkip("The fixed-machine timing gate runs only in an optimized build.")
        #else

        let items = await Task.detached(priority: .userInitiated) {
            TranscriptPerformanceFixtures.mixedMaximumTranscript
        }.value
        let prepared = await ConversationStore.prepareTranscriptProjections(
            for: items
        )
        let store = ConversationStore()
        store.hydrateFromCache(
            ConversationState(
                snapshotGeneration: ChatTestFixtures.generation,
                lastAppliedSequence: 1,
                items: items,
                connectionState: .streaming
            ),
            preparedProjections: prepared
        )
        for item in items {
            if case .tool = item {
                store.toggleExpanded(itemID: item.id)
            } else if case .diff = item {
                store.toggleExpanded(itemID: item.id)
            }
        }
        store.setConnectionState(.streaming)
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        settle(hosting)

        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        let scrollView = try XCTUnwrap(table.enclosingScrollView)
        let maximumOrigin = max(
            0,
            table.bounds.height - scrollView.contentView.bounds.height
        )
        XCTAssertGreaterThan(table.numberOfRows, 4_000)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maximumOrigin))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        settle(hosting)

        MacConversationTableDiagnostics.reset()
        MacConversationTableDiagnostics.watchConfigurations(
            for: "fixture-large-message"
        )
        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        let completed = expectation(description: "continuous mixed transcript pass")
        var result: TranscriptDisplayLinkDriver.Result?
        let driver = TranscriptDisplayLinkDriver(
            scrollView: scrollView,
            destinationY: 0,
            pointsPerFrame: 360
        ) { measured in
            result = measured
            completed.fulfill()
        }
        driver.start(in: window)
        await fulfillment(of: [completed], timeout: 120)
        let diagnostics = MacConversationTableDiagnostics.snapshot()
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        let endDiagnostics = MacConversationTableDiagnostics.snapshot()
        XCTAssertEqual(
            endDiagnostics.targetedRowReloads,
            diagnostics.targetedRowReloads,
            "didEndLiveScroll must not synchronously rebuild the mounted page."
        )
        waitForLiveScrollRestoration(in: table, hosting: hosting)
        let restoredDiagnostics = MacConversationTableDiagnostics.snapshot()

        let measured = try XCTUnwrap(result)
        let visible = visibleRowCount(in: table)
        let mounted = mountedRowCount(in: table)
        let rowAtMaximum = table.row(at: NSPoint(
            x: table.bounds.midX,
            y: measured.originAtMaximumCallback + 1
        ))
        let diagnosticRows = items.flatMap { item -> [MacTranscriptRow] in
            let rows = makeMacTranscriptRows(
                item: item,
                projections: prepared[item.id]?.rows
                    ?? TranscriptRowProjection.makeRows(item: item),
                isExpanded: {
                    switch item {
                    case .tool, .diff: true
                    default: false
                    }
                }(),
                copiedItemID: nil,
                sectionRevision: 1
            )
            return rows
        }
        let sourceIDsByRow = diagnosticRows.map(\.mutationSourceID)
        let sourceAtMaximum = sourceIDsByRow.indices.contains(rowAtMaximum)
            ? sourceIDsByRow[rowAtMaximum]
            : "unknown"
        print(
            "TranscriptMixedRelease samples=\(measured.callbackMilliseconds.count) "
                + "p95_ms=\(measured.p95Milliseconds) "
                + "p99_ms=\(measured.p99Milliseconds) "
                + "max_ms=\(measured.maximumMilliseconds) "
                + "hitch_ratio=\(measured.hitchRatio) "
                + "driver=\(measured.driverKind.rawValue) "
                + "max_mount_ms=\(measured.maximumMountCallbackMilliseconds) "
                + "max_no_mount_ms=\(measured.maximumNoMountCallbackMilliseconds) "
                + "max_mounts_per_tick=\(measured.maximumConfigurationsPerCallback) "
                + "max_index=\(measured.maximumCallbackIndex) "
                + "mounts_at_max=\(measured.configurationsAtMaximumCallback) "
                + "origin_at_max=\(measured.originAtMaximumCallback) "
                + "row_at_max=\(rowAtMaximum) "
                + "source_at_max=\(sourceAtMaximum) "
                + "estimated_row_height=\(table.rowHeight) "
                + "table_rows=\(table.numberOfRows) "
                + "source_rows=\(sourceIDsByRow.count) "
                + "document_height=\(table.bounds.height) "
                + "mounted=\(mounted) visible=\(visible) "
                + "end_ms=\(restoredDiagnostics.maximumLiveScrollEndMilliseconds) "
                + "restore_max_ms=\(restoredDiagnostics.maximumLiveScrollRestorationMilliseconds) "
                + "restore_max_rows=\(restoredDiagnostics.maximumLiveScrollRestorationsPerPass)"
        )
        let performanceSummary = "p95=\(measured.p95Milliseconds) "
            + "p99=\(measured.p99Milliseconds) max=\(measured.maximumMilliseconds) "
            + "hitch=\(measured.hitchRatio) "
            + "driver=\(measured.driverKind.rawValue) "
            + "maxMount=\(measured.maximumMountCallbackMilliseconds) "
            + "maxNoMount=\(measured.maximumNoMountCallbackMilliseconds) "
            + "mountsAtMax=\(measured.configurationsAtMaximumCallback) "
            + "rowAtMax=\(rowAtMaximum) sourceAtMax=\(sourceAtMaximum) "
            + "endMs=\(restoredDiagnostics.maximumLiveScrollEndMilliseconds) "
            + "restoreMaxMs=\(restoredDiagnostics.maximumLiveScrollRestorationMilliseconds) "
            + "restoreMaxRows=\(restoredDiagnostics.maximumLiveScrollRestorationsPerPass)"
        XCTContext.runActivity(
            named: "TranscriptMixedRelease \(performanceSummary)"
        ) { _ in }
        XCTAssertGreaterThan(measured.callbackMilliseconds.count, 120)
        XCTAssertLessThan(measured.p95Milliseconds, 4, performanceSummary)
        XCTAssertLessThan(measured.p99Milliseconds, 8.3, performanceSummary)
        XCTAssertLessThan(measured.hitchRatio, 0.01, performanceSummary)
        XCTAssertLessThan(
            measured.maximumMilliseconds,
            16.7,
            "No scroll callback may consume an entire 60 Hz frame. "
                + performanceSummary
        )
        XCTAssertEqual(diagnostics.reloadDataCalls, 0)
        XCTAssertEqual(diagnostics.explicitReconfigurations, 0)
        XCTAssertEqual(diagnostics.heightInvalidationPasses, 0)
        XCTAssertEqual(diagnostics.scrollOriginCorrections, 0)
        XCTAssertGreaterThan(
            diagnostics.watchedSourceConfigurations,
            0,
            "The timed pass must actually cross the 512 KiB logical message."
        )
        XCTAssertLessThanOrEqual(mounted, visible + 12)
        XCTAssertGreaterThan(
            restoredDiagnostics.targetedRowReloads,
            diagnostics.targetedRowReloads,
            "Rows realized through the display-only scroll cell must restore after the gesture."
        )
        XCTAssertLessThan(
            restoredDiagnostics.maximumLiveScrollEndMilliseconds,
            16.7,
            "Ending the gesture must stay within one 60 Hz frame."
        )
        // Visible rows restore in ONE batch so the viewport reaches its
        // resting rendering atomically (a row-per-frame walk read as a
        // quarter-second ripple); off-screen rows keep the incremental pace.
        // The binding budget is therefore the pass duration below, not a row
        // count — this assertion demanded one row per pass and had been
        // failing since batched restoration shipped.
        XCTAssertLessThanOrEqual(
            restoredDiagnostics.maximumLiveScrollRestorationsPerPass,
            visible + 12,
            "A restoration pass must stay bounded by the viewport."
        )
        XCTAssertLessThan(
            restoredDiagnostics.maximumLiveScrollRestorationMilliseconds,
            16.7,
            "Every incremental restoration pass must stay within one 60 Hz frame."
        )
        for index in 0..<table.numberOfRows {
            guard let cell = table.view(
                atColumn: 0,
                row: index,
                makeIfNecessary: false
            ) else { continue }
            XCTAssertFalse(
                cell.identifier?.rawValue.hasSuffix(".native-scroll") == true,
                "No mounted display-only cell may survive the end of live scrolling."
            )
        }
        #endif
    }

    /// A message that completes during a live turn swaps its row from the
    /// hosted streaming cell to a native tile. Reloading that one row leaves
    /// the row view still owning the old cell, so the replacement kept its own
    /// fitting width and painted its bubble against the transcript's leading
    /// edge while every other row stayed centered.
    func testCompletedLiveMessageKeepsTheSharedTranscriptColumn() async throws {
        let history: [ConversationItem] = [
            .message(
                ChatMessage(
                    id: "history-user",
                    turnID: "turn-0",
                    role: .user,
                    text: "hello",
                    occurredAt: 1_786_343_000_000
                )
            ),
            .message(
                ChatMessage(
                    id: "history-assistant",
                    turnID: "turn-0",
                    role: .assistant,
                    text: "Hello! What would you like to work on?",
                    occurredAt: 1_786_343_001_000
                )
            ),
        ]
        let transport = ChatFixtureTransport(initialEvents: [
            ChatTestFixtures.event(
                "session.hello",
                sequence: 1,
                payload: (try? JSONValue.encoded(
                    ChatCapabilities(features: ["streaming"])
                )) ?? .object([:])
            ),
            try ChatTestFixtures.snapshotEvent(baseSequence: 2, items: history),
        ])
        let store = ConversationStore()
        let coordinator = ConversationCoordinator(
            store: store,
            transport: transport,
            identity: ChatTestFixtures.identity,
            retryPolicy: .immediate
        )
        coordinator.start()
        await waitForItems(2, in: store)

        let hosting = NSHostingView(
            rootView: ConversationView(
                coordinator: coordinator,
                showsComposer: false,
                startsCoordinator: false
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 2_040, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        settle(hosting)

        await transport.yield(.envelope(ChatTestFixtures.event(
            "message.delta",
            sequence: 3,
            itemID: "live-assistant",
            turnID: "turn-1",
            payload: .object([
                "role": .string("assistant"),
                "text": .string("I am well too"),
            ])
        )))
        await waitForItems(3, in: store)
        settle(hosting)

        await transport.yield(.envelope(ChatTestFixtures.event(
            "message.completed",
            sequence: 4,
            itemID: "live-assistant",
            turnID: "turn-1",
            payload: .object([
                "role": .string("assistant"),
                "text": .string("I am well too — what is on your mind today?"),
            ])
        )))
        for _ in 0..<80 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        settle(hosting)

        let table = try XCTUnwrap(descendant(of: hosting, type: NSTableView.self))
        XCTAssertEqual(
            table.numberOfRows,
            6,
            "The completed live message must add its own text and footer rows."
        )
        for index in 0..<table.numberOfRows {
            let cell = try XCTUnwrap(
                table.view(atColumn: 0, row: index, makeIfNecessary: true)
            )
            XCTAssertEqual(
                cell.frame.width,
                table.bounds.width - 32,
                accuracy: 0.5,
                "Row \(index) must span the table; a cell left at its own fitting width shifts its column."
            )
            let container = try XCTUnwrap(cell.subviews.first)
            let box = container.convert(container.bounds, to: table)
            XCTAssertEqual(
                box.midX,
                table.bounds.midX,
                accuracy: 0.5,
                "Row \(index) must center on the same transcript column as every other row."
            )
        }
        await coordinator.detach()
    }

    private func waitForItems(_ count: Int, in store: ConversationStore) async {
        for _ in 0..<200 where store.state.items.count < count {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(store.state.items.count, count)
    }

    private func makeRows(count: Int) -> [Row] {
        (0..<count).map {
            Row(id: "row-\($0)", contentRevision: 1)
        }
    }

    private func makeMixedRows(count: Int) -> [MixedRow] {
        (0..<count).map {
            MixedRow(
                id: "native-row-\($0)",
                contentRevision: 1,
                text: "Native transcript row \($0)",
                usesNativeText: true
            )
        }
    }

    private func table(
        rows: [Row],
        styleRevision: Int = 0,
        onNearBottomChange: @escaping (Bool) -> Void = { _ in },
        onLiveScrollingChange: @escaping (Bool) -> Void = { _ in },
        prefetchRows: @escaping ([Row]) -> Void = { _ in },
        onMakeRow: @escaping (Row, Bool, Bool) -> Void = { _, _, _ in }
    ) -> MacConversationTableView<Row> {
        MacConversationTableView(
            sections: sections(rows),
            snapshotGeneration: "generation",
            styleRevision: styleRevision,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: onNearBottomChange,
            onLiveScrollingChange: onLiveScrollingChange,
            onAnchoredChange: { _ in },
            prefetchRows: prefetchRows,
            makeRow: { row, isFirst, isLast in
                onMakeRow(row, isFirst, isLast)
                return AnyView(
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
            sections: projectedSections(rows),
            snapshotGeneration: "generation",
            transcriptMutation: transcriptMutation,
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
            makeRow: { row, _, _ in
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

    private func mixedTable(
        rows: [MixedRow],
        onMakeHostedRow: @escaping (MixedRow) -> Void = { _ in },
        onNativeLink: @escaping @MainActor (URL) -> Bool = { _ in true }
    ) -> MacConversationTableView<MixedRow> {
        MacConversationTableView(
            sections: mixedSections(rows),
            snapshotGeneration: "generation",
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
            onNativeLink: onNativeLink,
            makeRow: { row, _, _ in
                onMakeHostedRow(row)
                return AnyView(
                    Text(row.text)
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
        onMakeRow: @escaping (Row, Bool, Bool) -> Void = { _, _, _ in },
        onNearBottomChange: @escaping (Bool) -> Void = { _ in },
        onLiveScrollingChange: @escaping (Bool) -> Void = { _ in },
        prefetchRows: @escaping ([Row]) -> Void = { _ in }
    ) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<Row>>,
        table: NSTableView
    ) {
        let hosting = NSHostingView(
            rootView: table(
                rows: rows,
                onNearBottomChange: onNearBottomChange,
                onLiveScrollingChange: onLiveScrollingChange,
                prefetchRows: prefetchRows,
                onMakeRow: onMakeRow
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

    private func mountMixed(
        rows: [MixedRow],
        onMakeHostedRow: @escaping (MixedRow) -> Void = { _ in },
        onNativeLink: @escaping @MainActor (URL) -> Bool = { _ in true },
        windowWidth: CGFloat = 800
    ) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<MixedRow>>,
        table: NSTableView
    ) {
        let hosting = NSHostingView(
            rootView: mixedTable(
                rows: rows,
                onMakeHostedRow: onMakeHostedRow,
                onNativeLink: onNativeLink
            )
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 600),
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

    private func measuredTextHeight(
        _ presentation: MacConversationNativeTextPresentation,
        width: CGFloat = 320
    ) -> CGFloat {
        let attributed = presentation.attributedString ?? NSAttributedString(
            string: presentation.fallbackString,
            attributes: [
                .font: presentation.fallbackFont
                    ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: presentation.fallbackColor
                    ?? NSColor.labelColor,
                .paragraphStyle: presentation.fallbackParagraphStyle
                    ?? NSParagraphStyle.default,
            ]
        )
        return ceil(attributed.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height)
    }

    private func waitForLiveScrollRestoration(
        in table: NSTableView,
        hosting: NSView,
        timeout: TimeInterval = 3
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let hasLiveCell = (0..<table.numberOfRows).contains { row in
                table.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                )?.identifier?.rawValue.hasSuffix(".native-scroll") == true
            }
            if !hasLiveCell {
                RunLoop.main.run(
                    until: Date().addingTimeInterval(1.0 / 60.0)
                )
                hosting.layoutSubtreeIfNeeded()
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(1.0 / 60.0))
            hosting.layoutSubtreeIfNeeded()
        }
        XCTFail("Timed out waiting for incremental live-scroll restoration.")
    }

    private func sections(_ rows: [Row]) -> [MacConversationTableSection<Row>] {
        rows.map {
            MacConversationTableSection(
                id: $0.id,
                revision: $0.contentRevision,
                rows: [$0]
            )
        }
    }

    private func projectedSections(
        _ rows: [ProjectedRow]
    ) -> [MacConversationTableSection<ProjectedRow>] {
        var sections: [MacConversationTableSection<ProjectedRow>] = []
        for row in rows {
            if let last = sections.last, last.id == row.mutationSourceID {
                var groupedRows = last.rows
                groupedRows.append(row)
                var hasher = Hasher()
                groupedRows.forEach {
                    hasher.combine($0.id)
                    hasher.combine($0.contentRevision)
                }
                sections[sections.count - 1] = MacConversationTableSection(
                    id: last.id,
                    revision: UInt64(truncatingIfNeeded: hasher.finalize()),
                    rows: groupedRows
                )
            } else {
                var hasher = Hasher()
                hasher.combine(row.id)
                hasher.combine(row.contentRevision)
                sections.append(MacConversationTableSection(
                    id: row.mutationSourceID,
                    revision: UInt64(truncatingIfNeeded: hasher.finalize()),
                    rows: [row]
                ))
            }
        }
        return sections
    }

    private func mixedSections(
        _ rows: [MixedRow]
    ) -> [MacConversationTableSection<MixedRow>] {
        rows.map {
            MacConversationTableSection(
                id: $0.id,
                revision: $0.contentRevision,
                rows: [$0]
            )
        }
    }
}

@MainActor
private final class TranscriptDisplayLinkDriver: NSObject {
    enum DriverKind: String {
        case displayLink
        case timerFallback
    }

    struct Result {
        let callbackMilliseconds: [Double]
        let p95Milliseconds: Double
        let p99Milliseconds: Double
        let maximumMilliseconds: Double
        let hitchRatio: Double
        let driverKind: DriverKind
        let maximumMountCallbackMilliseconds: Double
        let maximumNoMountCallbackMilliseconds: Double
        let maximumConfigurationsPerCallback: Int
        let maximumCallbackIndex: Int
        let configurationsAtMaximumCallback: Int
        let originAtMaximumCallback: CGFloat
    }

    private weak var scrollView: NSScrollView?
    private let destinationY: CGFloat
    private let pointsPerFrame: CGFloat
    private let completion: (Result) -> Void
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?
    private var callbackMilliseconds: [Double] = []
    private var configurationCounts: [Int] = []
    private var callbackOrigins: [CGFloat] = []
    private var lastTimestamp: CFTimeInterval?
    private var lastNominalDuration: CFTimeInterval?
    private var deliveredFrameIntervals = 0
    private var missedFrames = 0
    private var awaitsFinalDisplayTick = false
    private var didFinish = false
    private var driverKind = DriverKind.displayLink

    init(
        scrollView: NSScrollView,
        destinationY: CGFloat,
        pointsPerFrame: CGFloat,
        completion: @escaping (Result) -> Void
    ) {
        self.scrollView = scrollView
        self.destinationY = destinationY
        self.pointsPerFrame = pointsPerFrame
        self.completion = completion
    }

    func start(in window: NSWindow) {
        let link = window.displayLink(
            target: self,
            selector: #selector(tick(_:))
        )
        displayLink = link
        link.add(to: .main, forMode: .common)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startFallbackTimerIfDisplayLinkDidNotFire()
            }
        }
    }

    private func startFallbackTimerIfDisplayLinkDidNotFire() {
        guard !didFinish, callbackMilliseconds.isEmpty, fallbackTimer == nil else { return }
        displayLink?.invalidate()
        displayLink = nil
        driverKind = .timerFallback
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickFrame(
                    timestamp: CACurrentMediaTime(),
                    duration: 1.0 / 120.0
                )
            }
        }
        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc
    private func tick(_ link: CADisplayLink) {
        tickFrame(timestamp: link.timestamp, duration: link.duration)
    }

    private func tickFrame(timestamp: CFTimeInterval, duration: CFTimeInterval) {
        guard !didFinish, let scrollView else {
            finish()
            return
        }
        if let lastTimestamp {
            let interval = timestamp - lastTimestamp
            let nominal = max(lastNominalDuration ?? duration, 1.0 / 120.0)
            deliveredFrameIntervals += 1
            if interval > nominal * 1.5 {
                missedFrames += max(1, Int((interval / nominal).rounded()) - 1)
            }
        }
        lastTimestamp = timestamp
        lastNominalDuration = duration

        // Observe one additional display interval after the final scroll. Row
        // layout and drawing can be scheduled after scroll/reflect returns;
        // stopping immediately would omit a hitch caused by the last mount.
        if awaitsFinalDisplayTick {
            finish()
            return
        }

        let clipView = scrollView.contentView
        let currentY = clipView.bounds.origin.y
        let nextY = max(destinationY, currentY - pointsPerFrame)
        let diagnosticsBefore = MacConversationTableDiagnostics.snapshot()
        let started = CACurrentMediaTime()
        var proposed = clipView.bounds
        proposed.origin.y = nextY
        clipView.scroll(to: clipView.constrainBoundsRect(proposed).origin)
        scrollView.reflectScrolledClipView(clipView)
        callbackMilliseconds.append((CACurrentMediaTime() - started) * 1_000)
        let diagnosticsAfter = MacConversationTableDiagnostics.snapshot()
        configurationCounts.append(
            diagnosticsAfter.rowConfigurations
                - diagnosticsBefore.rowConfigurations
        )
        callbackOrigins.append(currentY)

        if nextY <= destinationY + 0.5 {
            awaitsFinalDisplayTick = true
        }
    }

    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        let sorted = callbackMilliseconds.sorted()
        var mountCallbacks: [Double] = []
        var noMountCallbacks: [Double] = []
        for (index, milliseconds) in callbackMilliseconds.enumerated() {
            if configurationCounts[index] > 0 {
                mountCallbacks.append(milliseconds)
            } else {
                noMountCallbacks.append(milliseconds)
            }
        }
        let maximumCallbackIndex = callbackMilliseconds.indices.max {
            callbackMilliseconds[$0] < callbackMilliseconds[$1]
        } ?? 0
        completion(
            Result(
                callbackMilliseconds: callbackMilliseconds,
                p95Milliseconds: percentile(0.95, in: sorted),
                p99Milliseconds: percentile(0.99, in: sorted),
                maximumMilliseconds: sorted.last ?? 0,
                hitchRatio: deliveredFrameIntervals + missedFrames > 0
                    ? Double(missedFrames)
                        / Double(deliveredFrameIntervals + missedFrames)
                    : 0,
                driverKind: driverKind,
                maximumMountCallbackMilliseconds: mountCallbacks.max() ?? 0,
                maximumNoMountCallbackMilliseconds: noMountCallbacks.max() ?? 0,
                maximumConfigurationsPerCallback: configurationCounts.max() ?? 0,
                maximumCallbackIndex: maximumCallbackIndex,
                configurationsAtMaximumCallback:
                    configurationCounts.indices.contains(maximumCallbackIndex)
                        ? configurationCounts[maximumCallbackIndex]
                        : 0,
                originAtMaximumCallback:
                    callbackOrigins.indices.contains(maximumCallbackIndex)
                        ? callbackOrigins[maximumCallbackIndex]
                        : 0
            )
        )
    }

    private func percentile(_ percentile: Double, in sorted: [Double]) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = max(
            0,
            min(
                sorted.count - 1,
                Int(ceil(percentile * Double(sorted.count))) - 1
            )
        )
        return sorted[index]
    }
}
