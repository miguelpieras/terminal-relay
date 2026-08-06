import AppKit
import SwiftUI

@MainActor
private final class MacConversationTranscriptScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class MacConversationTableCommandHandle {
    var performJump: (() -> Void)?
}

protocol MacConversationTableRow: Equatable, Identifiable where ID == String {
    var contentRevision: UInt64 { get }
    var reuseIdentifier: String { get }
    /// The logical transcript record that owns this rendered row. A single
    /// record can project into many reusable table rows, so mutation IDs from
    /// the store do not necessarily match `id`.
    var mutationSourceID: String { get }
}

extension MacConversationTableRow {
    var mutationSourceID: String { id }
}

@MainActor
enum MacConversationTableDiagnostics {
    struct Snapshot: Equatable {
        let reloadDataCalls: Int
        let preciseMutationPasses: Int
        let rowConfigurations: Int
        let ordinaryMountConfigurations: Int
        let explicitReconfigurations: Int
        let measuredRows: Int
        let maximumMountedRows: Int
        let heightInvalidationPasses: Int
        let scrollOriginCorrections: Int
    }

    private(set) static var reloadDataCalls = 0
    private(set) static var preciseMutationPasses = 0
    private(set) static var rowConfigurations = 0
    private(set) static var ordinaryMountConfigurations = 0
    private(set) static var explicitReconfigurations = 0
    private(set) static var measuredRows = 0
    private(set) static var maximumMountedRows = 0
    private(set) static var heightInvalidationPasses = 0
    private(set) static var scrollOriginCorrections = 0

    static func reset() {
        reloadDataCalls = 0
        preciseMutationPasses = 0
        rowConfigurations = 0
        ordinaryMountConfigurations = 0
        explicitReconfigurations = 0
        measuredRows = 0
        maximumMountedRows = 0
        heightInvalidationPasses = 0
        scrollOriginCorrections = 0
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            reloadDataCalls: reloadDataCalls,
            preciseMutationPasses: preciseMutationPasses,
            rowConfigurations: rowConfigurations,
            ordinaryMountConfigurations: ordinaryMountConfigurations,
            explicitReconfigurations: explicitReconfigurations,
            measuredRows: measuredRows,
            maximumMountedRows: maximumMountedRows,
            heightInvalidationPasses: heightInvalidationPasses,
            scrollOriginCorrections: scrollOriginCorrections
        )
    }

    static func recordedReload() { reloadDataCalls += 1 }
    static func recordedPreciseMutation() { preciseMutationPasses += 1 }
    static func recordedConfiguration(mountedRows: Int, isExplicit: Bool) {
        rowConfigurations += 1
        if isExplicit {
            explicitReconfigurations += 1
        } else {
            ordinaryMountConfigurations += 1
        }
        measuredRows += 1
        maximumMountedRows = max(maximumMountedRows, mountedRows)
    }
    static func recordedHeightInvalidation() { heightInvalidationPasses += 1 }
    static func recordedScrollOriginCorrection() { scrollOriginCorrections += 1 }
}

/// A view-based AppKit transcript. The table owns scrolling and row geometry;
/// SwiftUI owns only the bounded content mounted in visible reusable cells.
struct MacConversationTableView<Row: MacConversationTableRow>: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    let rows: [Row]
    let snapshotGeneration: String?
    var transcriptMutation: TranscriptMutation? = nil
    var dataRevision: Int? = nil
    var styleRevision: Int = 0
    let reduceMotion: Bool
    let commandHandle: MacConversationTableCommandHandle
    let onNearBottomChange: (Bool) -> Void
    var onLiveScrollingChange: (Bool) -> Void = { _ in }
    let onAnchoredChange: (Bool) -> Void
    let makeRow: (Row) -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.gridStyleMask = []
        // Consecutive transcript segments must meet with no table-owned gap
        // so one logical message still reads as one message. Group spacing is
        // applied by ConversationView only at item boundaries.
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = true
        table.rowHeight = 56
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = MacConversationTranscriptScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none

        context.coordinator.attach(scrollView: scrollView, tableView: table)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            rows: rows,
            snapshotGeneration: snapshotGeneration,
            transcriptMutation: transcriptMutation,
            dataRevision: dataRevision,
            styleRevision: styleRevision,
            reduceMotion: reduceMotion,
            commandHandle: commandHandle,
            environment: context.environment,
            onNearBottomChange: onNearBottomChange,
            onLiveScrollingChange: onLiveScrollingChange,
            onAnchoredChange: onAnchoredChange,
            makeRow: makeRow
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private weak var scrollView: NSScrollView?
        private weak var tableView: NSTableView?
        private var rows: [Row] = []
        private var indexByID: [String: Int] = [:]
        private var indicesByMutationSourceID: [String: [Int]] = [:]
        private var snapshotGeneration: String?
        private var lastTranscriptMutationRevision: UInt64 = 0
        private var dataRevision: Int?
        private var styleRevision = 0
        private var environment = EnvironmentValues()
        private var makeRow: (Row) -> AnyView = { _ in AnyView(EmptyView()) }
        private var onNearBottomChange: (Bool) -> Void = { _ in }
        private var onLiveScrollingChange: (Bool) -> Void = { _ in }
        private var onAnchoredChange: (Bool) -> Void = { _ in }
        private var reduceMotion = false
        private var didInitialAnchor = false
        private var lastNearBottom = true
        private var observers: [NSObjectProtocol] = []
        private var pendingMutationAnchor: Anchor?
        private var pendingMutationFollowsBottom = false
        private var pendingExpectedClipOriginY: CGFloat?
        private var stabilizationScheduled = false
        private var stabilizationGeneration: UInt64 = 0
        private var isLiveScrolling = false
        private var pendingLiveScrollHeightInvalidations = IndexSet()
        private var lastViewportWidth: CGFloat?

        private struct Anchor {
            let rowID: String
            let offset: CGFloat
        }

        func attach(scrollView: NSScrollView, tableView: NSTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            (scrollView as? MacConversationTranscriptScrollView)?.onLayout = { [weak self] in
                _ = self?.applyPendingScrollCorrectionIfReady()
            }
            lastViewportWidth = scrollView.contentView.bounds.width
            tableView.dataSource = self
            tableView.delegate = self

            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            tableView.postsFrameChangedNotifications = true
            let center = NotificationCenter.default
            observers = [
                center.addObserver(
                    forName: NSView.boundsDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sampleNearBottom() }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: clip,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.viewportWidthChanged() }
                },
                center.addObserver(
                    forName: NSView.frameDidChangeNotification,
                    object: tableView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tableGeometryDidChange() }
                },
                center.addObserver(
                    forName: NSScrollView.willStartLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveScrollDidBegin() }
                },
                center.addObserver(
                    forName: NSScrollView.didEndLiveScrollNotification,
                    object: scrollView,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.liveScrollDidEnd() }
                },
            ]
        }

        func detach() {
            if isLiveScrolling {
                onLiveScrollingChange(false)
            }
            (scrollView as? MacConversationTranscriptScrollView)?.onLayout = nil
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            tableView?.dataSource = nil
            tableView?.delegate = nil
            scrollView = nil
            tableView = nil
            pendingMutationAnchor = nil
            pendingMutationFollowsBottom = false
            pendingExpectedClipOriginY = nil
            stabilizationGeneration &+= 1
            stabilizationScheduled = false
            isLiveScrolling = false
            pendingLiveScrollHeightInvalidations.removeAll()
            lastViewportWidth = nil
        }

        func update(
            rows newRows: [Row],
            snapshotGeneration newSnapshotGeneration: String?,
            transcriptMutation: TranscriptMutation?,
            dataRevision newDataRevision: Int?,
            styleRevision newStyleRevision: Int,
            reduceMotion: Bool,
            commandHandle: MacConversationTableCommandHandle,
            environment: EnvironmentValues,
            onNearBottomChange: @escaping (Bool) -> Void,
            onLiveScrollingChange: @escaping (Bool) -> Void,
            onAnchoredChange: @escaping (Bool) -> Void,
            makeRow: @escaping (Row) -> AnyView
        ) {
            self.reduceMotion = reduceMotion
            self.environment = environment
            self.onNearBottomChange = onNearBottomChange
            self.onLiveScrollingChange = onLiveScrollingChange
            self.onAnchoredChange = onAnchoredChange
            self.makeRow = makeRow
            commandHandle.performJump = { [weak self] in self?.jumpToLatest() }

            guard let tableView else { return }
            let styleChanged = styleRevision != newStyleRevision
            let dataRevisionUnchanged = newDataRevision != nil
                && dataRevision == newDataRevision
            let mutationRevision = transcriptMutation?.revision ?? 0
            if dataRevisionUnchanged,
               !styleChanged,
               snapshotGeneration == newSnapshotGeneration,
               mutationRevision == lastTranscriptMutationRevision {
                return
            }
            dataRevision = newDataRevision
            let generationChanged = snapshotGeneration != newSnapshotGeneration
            let hasNewAuthoritativeReset = transcriptMutation?.isAuthoritativeReset == true
                && transcriptMutation?.revision != lastTranscriptMutationRevision
            let rowsChanged = rows != newRows
            guard rowsChanged || styleChanged || generationChanged
                    || hasNewAuthoritativeReset else {
                snapshotGeneration = newSnapshotGeneration
                if let transcriptMutation {
                    lastTranscriptMutationRevision = transcriptMutation.revision
                }
                styleRevision = newStyleRevision
                return
            }
            let isInitialPopulation = rows.isEmpty && !newRows.isEmpty
            let needsInitialAnchor = isInitialPopulation
                || (!didInitialAnchor && !newRows.isEmpty)
            // A freshly populated transcript always opens at latest. Before
            // the first table layout its empty document geometry can report a
            // spurious non-bottom origin, so do not derive the initial anchor
            // from that provisional range.
            let wasPinned = !isLiveScrolling && (needsInitialAnchor || isAtBottom)
            let anchor = isLiveScrolling || wasPinned ? nil : captureAnchor()
            if !isLiveScrolling {
                prepareMutationStabilization(
                    followsBottom: wasPinned,
                    anchor: anchor
                )
            }

            var heightInvalidations = IndexSet()
            var didReload = false
            TranscriptPerformance.measureTableMutation {
                if generationChanged || hasNewAuthoritativeReset
                    || rows.isEmpty || newRows.isEmpty {
                    rows = newRows
                    rebuildIndex()
                    snapshotGeneration = newSnapshotGeneration
                    tableView.reloadData()
                    MacConversationTableDiagnostics.recordedReload()
                    didReload = true
                } else if rowsChanged {
                    let newMutation = transcriptMutation.flatMap {
                        $0.revision == lastTranscriptMutationRevision ? nil : $0
                    }
                    heightInvalidations.formUnion(applyPreciseChanges(
                        from: rows,
                        to: newRows,
                        mutation: newMutation,
                        configureChangedRows: !styleChanged,
                        tableView: tableView
                    ))
                    MacConversationTableDiagnostics.recordedPreciseMutation()
                    snapshotGeneration = newSnapshotGeneration
                }
            }
            if let transcriptMutation {
                lastTranscriptMutationRevision = transcriptMutation.revision
            }
            styleRevision = newStyleRevision
            if styleChanged && !didReload {
                heightInvalidations.formUnion(
                    reconfigureVisibleRows(in: tableView)
                )
            }
            if !heightInvalidations.isEmpty {
                if isLiveScrolling {
                    pendingLiveScrollHeightInvalidations.formUnion(heightInvalidations)
                } else {
                    tableView.noteHeightOfRows(withIndexesChanged: heightInvalidations)
                    MacConversationTableDiagnostics.recordedHeightInvalidation()
                }
            }
            if pendingMutationFollowsBottom, !isLiveScrolling {
                primePinnedDocumentGeometry()
            }
            if !isLiveScrolling,
               pendingMutationFollowsBottom || pendingMutationAnchor != nil {
                pendingExpectedClipOriginY = scrollView?.contentView.bounds.origin.y
            }

            if needsInitialAnchor {
                didInitialAnchor = true
            } else if newRows.isEmpty {
                didInitialAnchor = false
                pendingMutationAnchor = nil
                pendingMutationFollowsBottom = false
                pendingExpectedClipOriginY = nil
                DispatchQueue.main.async { [onAnchoredChange] in
                    onAnchoredChange(false)
                }
            }
            if !newRows.isEmpty, !isLiveScrolling {
                scheduleMutationStabilization()
                if needsInitialAnchor {
                    DispatchQueue.main.async { [onAnchoredChange] in
                        onAnchoredChange(true)
                    }
                }
            }
            sampleNearBottom()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row index: Int
        ) -> NSView? {
            guard rows.indices.contains(index) else { return nil }
            let row = rows[index]
            let identifier = NSUserInterfaceItemIdentifier(row.reuseIdentifier)
            let cell: MacConversationHostedCell
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? MacConversationHostedCell {
                cell = reused
            } else {
                cell = MacConversationHostedCell()
                cell.identifier = identifier
            }
            configure(cell, with: row, isExplicit: false)
            return cell
        }

        private func applyPreciseChanges(
            from oldRows: [Row],
            to newRows: [Row],
            mutation: TranscriptMutation?,
            configureChangedRows: Bool,
            tableView: NSTableView
        ) -> IndexSet {
            let oldIndex = Dictionary(uniqueKeysWithValues: oldRows.enumerated().map {
                ($0.element.id, $0.offset)
            })
            let newIndex = Dictionary(uniqueKeysWithValues: newRows.enumerated().map {
                ($0.element.id, $0.offset)
            })
            let oldCommonOrder = oldRows.compactMap { newIndex[$0.id] == nil ? nil : $0.id }
            let newCommonOrder = newRows.compactMap { oldIndex[$0.id] == nil ? nil : $0.id }

            guard oldCommonOrder == newCommonOrder else {
                rows = newRows
                rebuildIndex()
                tableView.reloadData()
                MacConversationTableDiagnostics.recordedReload()
                return []
            }

            let actualRemovedIDs = Set(oldRows.compactMap {
                newIndex[$0.id] == nil ? $0.id : nil
            })
            let actualInsertedIDs = Set(newRows.compactMap {
                oldIndex[$0.id] == nil ? $0.id : nil
            })
            let canUseMutation = mutation.map {
                Set($0.removedIDs) == actualRemovedIDs
                    && Set($0.insertions.map(\.id)) == actualInsertedIDs
            } ?? false
            let removedIDs = canUseMutation
                ? Set(mutation?.removedIDs ?? [])
                : actualRemovedIDs
            let insertedIDs = canUseMutation
                ? Set(mutation?.insertions.map(\.id) ?? [])
                : actualInsertedIDs
            let removals = IndexSet(oldRows.indices.filter {
                removedIDs.contains(oldRows[$0].id)
            })
            let insertions = IndexSet(newRows.indices.filter {
                insertedIDs.contains(newRows[$0].id)
            })
            var changedRowIDs = Set(newRows.compactMap { row -> String? in
                guard let old = oldIndex[row.id].map({ oldRows[$0] }), old != row else {
                    return nil
                }
                return row.id
            })

            rows = newRows
            rebuildIndex()
            // Store mutations identify logical transcript items. One logical
            // item can own many projected table rows, so expand the mutation
            // hint only after rebuilding the source-to-row index.
            if let mutation {
                for sourceID in mutation.changedIDs {
                    for index in indicesByMutationSourceID[sourceID] ?? [] {
                        let row = rows[index]
                        guard let oldIndex = oldIndex[row.id],
                              oldRows[oldIndex] != row else { continue }
                        changedRowIDs.insert(row.id)
                    }
                }
            }
            if !removals.isEmpty || !insertions.isEmpty {
                tableView.beginUpdates()
                if !removals.isEmpty {
                    tableView.removeRows(at: removals, withAnimation: [])
                }
                if !insertions.isEmpty {
                    tableView.insertRows(at: insertions, withAnimation: [])
                }
                tableView.endUpdates()
            }

            guard configureChangedRows else { return [] }
            var configuredIndexes = IndexSet()
            for id in changedRowIDs {
                guard let index = indexByID[id],
                      let cell = tableView.view(
                        atColumn: 0,
                        row: index,
                        makeIfNecessary: false
                      ) as? MacConversationHostedCell else {
                    continue
                }
                configure(
                    cell,
                    with: rows[index],
                    isExplicit: true
                )
                configuredIndexes.insert(index)
            }
            return configuredIndexes
        }

        private func reconfigureVisibleRows(in tableView: NSTableView) -> IndexSet {
            guard let scrollView else { return [] }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound else { return [] }
            var configuredIndexes = IndexSet()
            for index in visible.location..<NSMaxRange(visible) {
                guard rows.indices.contains(index),
                      let cell = tableView.view(
                        atColumn: 0,
                        row: index,
                        makeIfNecessary: false
                      ) as? MacConversationHostedCell else {
                    continue
                }
                configure(
                    cell,
                    with: rows[index],
                    force: true,
                    isExplicit: true
                )
                configuredIndexes.insert(index)
            }
            return configuredIndexes
        }

        private func configure(
            _ cell: MacConversationHostedCell,
            with row: Row,
            force: Bool = false,
            isExplicit: Bool
        ) {
            guard force || cell.representedRowID != row.id
                    || cell.contentRevision != row.contentRevision else {
                return
            }
            TranscriptPerformance.measureRowConfigure {
                cell.representedRowID = row.id
                cell.contentRevision = row.contentRevision
                cell.setRootView(
                    makeRow(row).environment(\.self, environment)
                )
            }
            TranscriptPerformance.emitCounters(
                changedRows: 1,
                mountedRows: visibleMountedRowCount,
                measuredRows: 1
            )
            MacConversationTableDiagnostics.recordedConfiguration(
                mountedRows: visibleMountedRowCount,
                isExplicit: isExplicit
            )
        }

        private func rebuildIndex() {
            indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                ($0.element.id, $0.offset)
            })
            indicesByMutationSourceID = Dictionary(
                grouping: rows.indices,
                by: { rows[$0].mutationSourceID }
            )
        }

        private func prepareMutationStabilization(
            followsBottom: Bool,
            anchor: Anchor?
        ) {
            guard !isLiveScrolling else { return }
            if followsBottom {
                pendingMutationFollowsBottom = true
                pendingMutationAnchor = nil
                pendingExpectedClipOriginY = scrollView?.contentView.bounds.origin.y
            } else if !pendingMutationFollowsBottom,
                      pendingMutationAnchor == nil {
                pendingMutationAnchor = anchor
                pendingExpectedClipOriginY = scrollView?.contentView.bounds.origin.y
            }
        }

        private func liveScrollDidBegin() {
            isLiveScrolling = true
            cancelMutationStabilization()
            onLiveScrollingChange(true)
        }

        private func liveScrollDidEnd() {
            isLiveScrolling = false
            guard let tableView, let scrollView,
                  !pendingLiveScrollHeightInvalidations.isEmpty else {
                sampleNearBottom()
                onLiveScrollingChange(false)
                return
            }
            let followsBottom = isAtBottom
            prepareMutationStabilization(
                followsBottom: followsBottom,
                anchor: followsBottom ? nil : captureAnchor()
            )
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            if visible.location != NSNotFound {
                pendingLiveScrollHeightInvalidations.formUnion(
                    IndexSet(integersIn: visible.location..<NSMaxRange(visible))
                )
            }
            var validIndexes = IndexSet()
            for index in pendingLiveScrollHeightInvalidations
            where rows.indices.contains(index) {
                validIndexes.insert(index)
            }
            pendingLiveScrollHeightInvalidations.removeAll()
            if !validIndexes.isEmpty {
                tableView.noteHeightOfRows(withIndexesChanged: validIndexes)
                MacConversationTableDiagnostics.recordedHeightInvalidation()
                scheduleMutationStabilization()
            }
            sampleNearBottom()
            onLiveScrollingChange(false)
        }

        private func cancelMutationStabilization() {
            stabilizationGeneration &+= 1
            stabilizationScheduled = false
            pendingMutationAnchor = nil
            pendingMutationFollowsBottom = false
            pendingExpectedClipOriginY = nil
        }

        private func primePinnedDocumentGeometry() {
            guard let tableView, let scrollView, !rows.isEmpty else { return }
            let estimatedHeight = CGFloat(rows.count) * tableView.rowHeight
                + CGFloat(max(0, rows.count - 1)) * tableView.intercellSpacing.height
            if tableView.frame.height < estimatedHeight {
                tableView.setFrameSize(
                    NSSize(
                        width: max(tableView.frame.width, scrollView.contentView.bounds.width),
                        height: estimatedHeight
                    )
                )
                scrollView.layoutSubtreeIfNeeded()
            }
            // The viewport was confirmed pinned before the batch, so
            // establish the best currently known bottom immediately. The
            // retained geometry callback performs the final exact correction
            // after hosted row heights settle.
            var origin = scrollView.contentView.bounds.origin
            origin.y = maximumScrollOriginY
            guard abs(origin.y - scrollView.contentView.bounds.origin.y) > 0.5 else {
                return
            }
            MacConversationTableDiagnostics.recordedScrollOriginCorrection()
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func tableGeometryDidChange() {
            guard !isLiveScrolling,
                  pendingMutationFollowsBottom || pendingMutationAnchor != nil else {
                return
            }
            let generation = stabilizationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.isLiveScrolling,
                      self.stabilizationGeneration == generation else { return }
                _ = self.applyPendingScrollCorrectionIfReady()
            }
        }

        @discardableResult
        private func applyPendingScrollCorrectionIfReady() -> Bool {
            guard pendingMutationFollowsBottom || pendingMutationAnchor != nil else {
                return false
            }
            if let scrollView, let expectedOrigin = pendingExpectedClipOriginY {
                let currentOrigin = scrollView.contentView.bounds.origin.y
                let userMovedViewport = abs(currentOrigin - expectedOrigin) > 0.5
                if userMovedViewport && (!pendingMutationFollowsBottom || !isAtBottom) {
                    // A keyboard, scrollbar, programmatic, or late momentum
                    // move happened after the mutation captured ownership.
                    // Never overwrite that newer viewport decision.
                    pendingMutationAnchor = nil
                    pendingMutationFollowsBottom = false
                    pendingExpectedClipOriginY = nil
                    return false
                }
            }
            if !rows.isEmpty {
                guard let tableView else { return false }
                let expectedContentHeight = tableView.rect(
                    ofRow: rows.count - 1
                ).maxY
                guard expectedContentHeight > 0,
                      tableView.frame.height + 0.5 >= expectedContentHeight else {
                    return false
                }
                if let scrollView,
                   expectedContentHeight > scrollView.contentView.bounds.height + 0.5,
                   maximumScrollOriginY <= 0.5 {
                    return false
                }
            }
            if pendingMutationFollowsBottom {
                pinToBottom()
            } else if let anchor = pendingMutationAnchor {
                restore(anchor)
            }
            pendingMutationAnchor = nil
            pendingMutationFollowsBottom = false
            pendingExpectedClipOriginY = nil
            sampleNearBottom()
            return true
        }

        private func scheduleMutationStabilization() {
            guard !isLiveScrolling, !stabilizationScheduled else { return }
            stabilizationScheduled = true
            let generation = stabilizationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      !self.isLiveScrolling,
                      self.stabilizationGeneration == generation else { return }
                self.scrollView?.layoutSubtreeIfNeeded()
                self.tableView?.layoutSubtreeIfNeeded()
                // Hosted SwiftUI content publishes its intrinsic height after
                // the AppKit row pass. One more run-loop turn lets those
                // bounded visible-row measurements settle before the single
                // anchor correction for the whole mutation batch.
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          !self.isLiveScrolling,
                          self.stabilizationGeneration == generation else { return }
                    self.scrollView?.layoutSubtreeIfNeeded()
                    self.tableView?.layoutSubtreeIfNeeded()
                    self.stabilizationScheduled = false
                    _ = self.applyPendingScrollCorrectionIfReady()
                }
            }
        }

        private var visibleMountedRowCount: Int {
            guard let tableView, let scrollView else { return 0 }
            let range = tableView.rows(in: scrollView.contentView.bounds)
            return range.location == NSNotFound ? 0 : range.length
        }

        private func captureAnchor() -> Anchor? {
            guard let tableView, let scrollView, !rows.isEmpty else { return nil }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound,
                  rows.indices.contains(visible.location) else { return nil }
            let rect = tableView.rect(ofRow: visible.location)
            return Anchor(
                rowID: rows[visible.location].id,
                offset: rect.minY - scrollView.contentView.bounds.minY
            )
        }

        private func restore(_ anchor: Anchor) {
            guard let tableView, let scrollView,
                  let index = indexByID[anchor.rowID] else { return }
            let rowOrigin = tableView.rect(ofRow: index).minY
            var proposed = scrollView.contentView.bounds
            proposed.origin.y = rowOrigin - anchor.offset
            MacConversationTableDiagnostics.recordedScrollOriginCorrection()
            scrollView.contentView.setBoundsOrigin(
                scrollView.contentView.constrainBoundsRect(proposed).origin
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private var maximumScrollOriginY: CGFloat {
            guard let scrollView, let tableView else { return 0 }
            let clip = scrollView.contentView
            let proposed = NSRect(
                x: clip.bounds.origin.x,
                y: tableView.frame.height,
                width: clip.bounds.width,
                height: clip.bounds.height
            )
            return clip.constrainBoundsRect(proposed).origin.y
        }

        private var distanceFromBottom: CGFloat {
            guard let scrollView else { return 0 }
            return maximumScrollOriginY - scrollView.contentView.bounds.origin.y
        }

        private var isAtBottom: Bool {
            distanceFromBottom <= ConversationScrollController.atBottomTolerance
        }

        private func sampleNearBottom() {
            // Crossing the near-bottom threshold must not invalidate the
            // transcript's SwiftUI owner in the middle of a live gesture.
            // Report only the final sampled value from liveScrollDidEnd().
            guard !isLiveScrolling else { return }
            let nearBottom = distanceFromBottom <= 180
            guard nearBottom != lastNearBottom else { return }
            lastNearBottom = nearBottom
            onNearBottomChange(nearBottom)
        }

        private func pinToBottom() {
            guard let scrollView else { return }
            var origin = scrollView.contentView.bounds.origin
            origin.y = maximumScrollOriginY
            guard abs(origin.y - scrollView.contentView.bounds.origin.y) > 0.5 else {
                return
            }
            MacConversationTableDiagnostics.recordedScrollOriginCorrection()
            scrollView.contentView.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func jumpToLatest() {
            guard let scrollView else { return }
            if reduceMotion {
                pinToBottom()
                sampleNearBottom()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                var origin = scrollView.contentView.bounds.origin
                origin.y = maximumScrollOriginY
                MacConversationTableDiagnostics.recordedScrollOriginCorrection()
                scrollView.contentView.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.pinToBottom()
                    self?.sampleNearBottom()
                }
            }
        }

        private func viewportWidthChanged() {
            guard let tableView, let scrollView else { return }
            let width = scrollView.contentView.bounds.width
            guard width > 0,
                  lastViewportWidth.map({ abs($0 - width) > 0.5 }) ?? true else {
                return
            }
            lastViewportWidth = width
            guard !rows.isEmpty else { return }
            let followsBottom = isAtBottom
            prepareMutationStabilization(
                followsBottom: followsBottom,
                anchor: followsBottom ? nil : captureAnchor()
            )
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound else { return }
            let indexes = IndexSet(
                integersIn: visible.location..<NSMaxRange(visible)
            )
            if isLiveScrolling {
                pendingLiveScrollHeightInvalidations.formUnion(indexes)
            } else {
                tableView.noteHeightOfRows(withIndexesChanged: indexes)
                MacConversationTableDiagnostics.recordedHeightInvalidation()
                scheduleMutationStabilization()
            }
        }
    }
}

@MainActor
private final class MacConversationHostedCell: NSTableCellView {
    var representedRowID: String?
    var contentRevision: UInt64 = 0
    private var hosting: NSHostingView<AnyView>?

    func setRootView(_ rootView: some View) {
        if let hosting {
            hosting.rootView = AnyView(rootView)
            return
        }
        let hosting = NSHostingView(rootView: AnyView(rootView))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        self.hosting = hosting
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedRowID = nil
        contentRevision = 0
        hosting?.rootView = AnyView(EmptyView())
    }
}
