import AppKit
import SwiftUI

@MainActor
final class MacConversationTableCommandHandle {
    var performJump: (() -> Void)?
}

protocol MacConversationTableRow: Equatable, Identifiable where ID == String {
    var contentRevision: UInt64 { get }
    var reuseIdentifier: String { get }
}

@MainActor
enum MacConversationTableDiagnostics {
    struct Snapshot: Equatable {
        let reloadDataCalls: Int
        let preciseMutationPasses: Int
        let rowConfigurations: Int
        let measuredRows: Int
        let maximumMountedRows: Int
    }

    private(set) static var reloadDataCalls = 0
    private(set) static var preciseMutationPasses = 0
    private(set) static var rowConfigurations = 0
    private(set) static var measuredRows = 0
    private(set) static var maximumMountedRows = 0

    static func reset() {
        reloadDataCalls = 0
        preciseMutationPasses = 0
        rowConfigurations = 0
        measuredRows = 0
        maximumMountedRows = 0
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            reloadDataCalls: reloadDataCalls,
            preciseMutationPasses: preciseMutationPasses,
            rowConfigurations: rowConfigurations,
            measuredRows: measuredRows,
            maximumMountedRows: maximumMountedRows
        )
    }

    static func recordedReload() { reloadDataCalls += 1 }
    static func recordedPreciseMutation() { preciseMutationPasses += 1 }
    static func recordedConfiguration(mountedRows: Int) {
        rowConfigurations += 1
        measuredRows += 1
        maximumMountedRows = max(maximumMountedRows, mountedRows)
    }
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
        table.intercellSpacing = NSSize(width: 0, height: 14)
        table.selectionHighlightStyle = .none
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = true
        table.rowHeight = 56
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("transcript"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        let scrollView = NSScrollView()
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
        private var snapshotGeneration: String?
        private var lastTranscriptMutationRevision: UInt64 = 0
        private var dataRevision: Int?
        private var styleRevision = 0
        private var environment = EnvironmentValues()
        private var makeRow: (Row) -> AnyView = { _ in AnyView(EmptyView()) }
        private var onNearBottomChange: (Bool) -> Void = { _ in }
        private var onAnchoredChange: (Bool) -> Void = { _ in }
        private var reduceMotion = false
        private var didInitialAnchor = false
        private var lastNearBottom = true
        private var observers: [NSObjectProtocol] = []
        private var pendingMutationAnchor: Anchor?
        private var pendingMutationFollowsBottom = false
        private var stabilizationGeneration: UInt64 = 0

        private struct Anchor {
            let rowID: String
            let offset: CGFloat
        }

        func attach(scrollView: NSScrollView, tableView: NSTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            tableView.dataSource = self
            tableView.delegate = self

            let clip = scrollView.contentView
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
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
            ]
        }

        func detach() {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers.removeAll()
            tableView?.dataSource = nil
            tableView?.delegate = nil
            scrollView = nil
            tableView = nil
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
            onAnchoredChange: @escaping (Bool) -> Void,
            makeRow: @escaping (Row) -> AnyView
        ) {
            self.reduceMotion = reduceMotion
            self.environment = environment
            self.onNearBottomChange = onNearBottomChange
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
            let isInitialPopulation = rows.isEmpty && !newRows.isEmpty
            let wasPinned = isAtBottom
            let anchor = wasPinned ? nil : captureAnchor()
            pendingMutationAnchor = anchor
            pendingMutationFollowsBottom = wasPinned

            TranscriptPerformance.measureTableMutation {
                if generationChanged || hasNewAuthoritativeReset
                    || rows.isEmpty || newRows.isEmpty {
                    rows = newRows
                    rebuildIndex()
                    snapshotGeneration = newSnapshotGeneration
                    tableView.reloadData()
                    MacConversationTableDiagnostics.recordedReload()
                } else {
                    let newMutation = transcriptMutation.flatMap {
                        $0.revision == lastTranscriptMutationRevision ? nil : $0
                    }
                    applyPreciseChanges(
                        from: rows,
                        to: newRows,
                        mutation: newMutation,
                        configureChangedRows: !styleChanged,
                        tableView: tableView
                    )
                    MacConversationTableDiagnostics.recordedPreciseMutation()
                    snapshotGeneration = newSnapshotGeneration
                }
            }
            if let transcriptMutation {
                lastTranscriptMutationRevision = transcriptMutation.revision
            }
            styleRevision = newStyleRevision
            if styleChanged && !generationChanged && !hasNewAuthoritativeReset {
                reconfigureVisibleRows(in: tableView)
            }

            if isInitialPopulation || (!didInitialAnchor && !newRows.isEmpty) {
                didInitialAnchor = true
                pinToBottom()
                DispatchQueue.main.async { [onAnchoredChange] in
                    onAnchoredChange(true)
                }
            } else if newRows.isEmpty {
                didInitialAnchor = false
                DispatchQueue.main.async { [onAnchoredChange] in
                    onAnchoredChange(false)
                }
            } else if wasPinned {
                pinToBottom()
            } else if let anchor {
                restore(anchor)
            }
            scheduleMutationStabilization()
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
            configure(cell, with: row, at: index)
            return cell
        }

        private func applyPreciseChanges(
            from oldRows: [Row],
            to newRows: [Row],
            mutation: TranscriptMutation?,
            configureChangedRows: Bool,
            tableView: NSTableView
        ) {
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
                return
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
            let changedIDs: [String]
            if canUseMutation, let mutation {
                changedIDs = mutation.changedIDs.filter { newIndex[$0] != nil }
            } else {
                changedIDs = newRows.compactMap { row -> String? in
                    guard let old = oldIndex[row.id].map({ oldRows[$0] }), old != row else {
                        return nil
                    }
                    return row.id
                }
            }

            rows = newRows
            rebuildIndex()
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

            guard configureChangedRows else { return }
            for id in changedIDs {
                guard let index = indexByID[id],
                      let cell = tableView.view(
                        atColumn: 0,
                        row: index,
                        makeIfNecessary: false
                      ) as? MacConversationHostedCell else {
                    continue
                }
                configure(cell, with: rows[index], at: index)
            }
        }

        private func reconfigureVisibleRows(in tableView: NSTableView) {
            guard let scrollView else { return }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound else { return }
            for index in visible.location..<NSMaxRange(visible) {
                guard rows.indices.contains(index),
                      let cell = tableView.view(
                        atColumn: 0,
                        row: index,
                        makeIfNecessary: false
                      ) as? MacConversationHostedCell else {
                    continue
                }
                configure(cell, with: rows[index], at: index, force: true)
            }
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(
                    integersIn: visible.location..<NSMaxRange(visible)
                )
            )
        }

        private func configure(
            _ cell: MacConversationHostedCell,
            with row: Row,
            at index: Int,
            force: Bool = false
        ) {
            guard force || cell.representedRowID != row.id
                    || cell.contentRevision != row.contentRevision else {
                return
            }
            let followsBottom = pendingMutationFollowsBottom || isAtBottom
            let anchor = pendingMutationAnchor
                ?? (followsBottom ? nil : captureAnchor())
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
                mountedRows: visibleMountedRowCount
            )
            DispatchQueue.main.async { [weak self, weak cell] in
                guard let self, let tableView = self.tableView,
                      let cell, cell.representedRowID == row.id,
                      self.rows.indices.contains(index), self.rows[index].id == row.id else {
                    return
                }
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
                if self.pendingMutationFollowsBottom || followsBottom {
                    self.pinToBottom()
                } else if let anchor {
                    self.restore(anchor)
                }
                self.sampleNearBottom()
            }
        }

        private func rebuildIndex() {
            indexByID = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
                ($0.element.id, $0.offset)
            })
        }

        private func scheduleMutationStabilization() {
            stabilizationGeneration &+= 1
            let generation = stabilizationGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.tableView?.layoutSubtreeIfNeeded()
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.stabilizationGeneration == generation else {
                        return
                    }
                    self.tableView?.layoutSubtreeIfNeeded()
                    if self.pendingMutationFollowsBottom {
                        self.pinToBottom()
                    } else if let anchor = self.pendingMutationAnchor {
                        self.restore(anchor)
                    }
                    self.pendingMutationAnchor = nil
                    self.pendingMutationFollowsBottom = false
                    self.sampleNearBottom()
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
            let nearBottom = distanceFromBottom <= 180
            guard nearBottom != lastNearBottom else { return }
            lastNearBottom = nearBottom
            onNearBottomChange(nearBottom)
        }

        private func pinToBottom() {
            guard let scrollView else { return }
            var origin = scrollView.contentView.bounds.origin
            origin.y = maximumScrollOriginY
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
            let anchor = isAtBottom ? nil : captureAnchor()
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound else { return }
            tableView.noteHeightOfRows(
                withIndexesChanged: IndexSet(integersIn: visible.location..<NSMaxRange(visible))
            )
            if let anchor {
                restore(anchor)
            } else {
                pinToBottom()
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

struct TranscriptFullContentSheet: View {
    let content: TranscriptFullContent
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.handle.title)
                        .font(.headline)
                    Text(metadata)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    ChatClipboard.copy(content.text)
                }
                Button("Done", action: dismiss)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            TextKitFullContentView(text: content.text)
        }
        .frame(minWidth: 680, minHeight: 500)
        .accessibilityElement(children: .contain)
    }

    private var metadata: String {
        var values = [
            content.handle.contentType,
            ByteCountFormatter.string(
                fromByteCount: Int64(content.retainedByteCount),
                countStyle: .file
            ),
            "\(content.retainedLineCount) lines",
        ]
        if content.handle.isTruncatedAtSource {
            if let original = content.handle.originalByteCount {
                values.append(
                    "retained from \(ByteCountFormatter.string(fromByteCount: Int64(original), countStyle: .file))"
                )
            } else {
                values.append("source truncated")
            }
        }
        return values.joined(separator: " · ")
    }
}

private struct TextKitFullContentView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView(usingTextLayoutManager: true)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }
}
