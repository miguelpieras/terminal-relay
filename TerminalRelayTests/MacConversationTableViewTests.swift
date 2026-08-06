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

    private struct MixedRow: MacConversationTableRow {
        let id: String
        let contentRevision: UInt64
        let text: String
        let usesNativeText: Bool
        var nativeAccessibilityIdentifier: String? = nil
        var firstRowTopInsetAdjustment: CGFloat = 0
        var lastRowBottomInsetAdjustment: CGFloat = 0

        var reuseIdentifier: String { "test.mixed-row" }

        func nativeTextPresentation(
            dynamicTypeSize: DynamicTypeSize
        ) -> MacConversationNativeTextPresentation? {
            guard usesNativeText else { return nil }
            return MacConversationNativeTextPresentation(
                attributedString: NSAttributedString(
                    string: text,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 14),
                        .foregroundColor: NSColor.labelColor,
                    ]
                ),
                fallbackString: text,
                contentInsets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12),
                firstRowTopInsetAdjustment: firstRowTopInsetAdjustment,
                lastRowBottomInsetAdjustment: lastRowBottomInsetAdjustment,
                textContainerInset: NSSize(width: 2, height: 2),
                maximumContentWidth: 320,
                backgroundColor: NSColor.controlBackgroundColor,
                accessibilityLabel: "Native transcript text",
                accessibilityIdentifier: nativeAccessibilityIdentifier
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
        XCTAssertEqual(nativeTextView?.isSelectable, true)
        XCTAssertEqual(nativeTextView?.isEditable, false)
        XCTAssertEqual(nativeTextView?.textContainer?.widthTracksTextView, true)
        XCTAssertGreaterThan(nativeTextView?.intrinsicContentSize.height ?? 0, 0)
        XCTAssertLessThanOrEqual(nativeTextView?.frame.width ?? .infinity, 320.5)
        XCTAssertEqual(
            nativeTextView?.frame.midX ?? 0,
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

    func testCompletedAssistantUsesNativeTextForEveryTileAndASeparateHostedFooter() {
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
                row.nativeTextPresentation(dynamicTypeSize: .large),
                "Completed assistant text must bypass NSHostingView, including its final tile."
            )
        }
        guard case .messageFooter(let footer, let revision) = rows.last else {
            return XCTFail("Expected a separate small assistant action footer.")
        }
        XCTAssertEqual(footer.itemID, "assistant")
        XCTAssertEqual(revision, 7)
        XCTAssertEqual(
            projections.map(\.sourceText).joined(),
            source,
            "Separating the footer must not hide or duplicate message text."
        )
    }

    func testStreamingAndUserMessageTilesRemainHosted() {
        let streaming = ConversationItem.message(
            ChatMessage(
                id: "streaming",
                role: .assistant,
                text: "still changing",
                isStreaming: true
            )
        )
        let user = ConversationItem.message(
            ChatMessage(id: "user", role: .user, text: "user bubble")
        )

        for item in [streaming, user] {
            let rows = makeMacTranscriptRows(
                item: item,
                projections: TranscriptRowProjection.makeRows(item: item),
                isExpanded: false,
                copiedItemID: nil,
                sectionRevision: 1
            )
            XCTAssertTrue(rows.allSatisfy { row in
                if case .item = row {
                    return row.nativeTextPresentation(
                        dynamicTypeSize: .large
                    ) == nil
                }
                return false
            })
        }
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
        let regular = row.nativeTextPresentation(dynamicTypeSize: .large),
        let accessibility = row.nativeTextPresentation(
            dynamicTypeSize: .accessibility1
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
        // overscan is available on both sides of the viewport.
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
        XCTAssertEqual(heightChangePreparations, 2)
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
        onMakeHostedRow: @escaping (MixedRow) -> Void = { _ in }
    ) -> MacConversationTableView<MixedRow> {
        MacConversationTableView(
            sections: mixedSections(rows),
            snapshotGeneration: "generation",
            reduceMotion: true,
            commandHandle: MacConversationTableCommandHandle(),
            onNearBottomChange: { _ in },
            onAnchoredChange: { _ in },
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
        onMakeHostedRow: @escaping (MixedRow) -> Void = { _ in }
    ) -> (
        window: NSWindow,
        hosting: NSHostingView<MacConversationTableView<MixedRow>>,
        table: NSTableView
    ) {
        let hosting = NSHostingView(
            rootView: mixedTable(
                rows: rows,
                onMakeHostedRow: onMakeHostedRow
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
