import AppKit
import CoreText
import QuartzCore
import SwiftUI

@MainActor
private final class MacConversationTranscriptScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onWheelEvent: ((NSEvent) -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func scrollWheel(with event: NSEvent) {
        onWheelEvent?(event)
        super.scrollWheel(with: event)
    }
}

/// Shared by the reusable row hosts without publishing SwiftUI state. Async
/// text preparation waits here while the user or scroll momentum owns the
/// viewport, so a completed artifact cannot trigger an intrinsic-height pass
/// in the middle of a gesture.
final class MacTranscriptScrollActivity: @unchecked Sendable {
    private final class CancellationToken: @unchecked Sendable {
        private enum State {
            case pending
            case cancelled
            case claimed
        }

        private let lock = NSLock()
        private var state = State.pending

        func cancel() {
            lock.lock()
            if state == .pending {
                state = .cancelled
            }
            lock.unlock()
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return state == .cancelled
        }

        /// Establishes one cancellation/adoption linearization point. A
        /// cancellation that wins first prevents the action; after a claim,
        /// adoption has already begun and cancellation only ends the waiter.
        func claim() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard state == .pending else { return false }
            state = .claimed
            return true
        }
    }

    @MainActor
    private struct IdleAdoption {
        let id: UUID
        let cancellationToken: CancellationToken
        let action: @MainActor () -> Void
        let continuation: CheckedContinuation<Void, Never>
    }

    @MainActor private var isLiveScrolling = false
    @MainActor private var isIncrementalRestorationActive = false
    @MainActor private var idleAdoptions: [IdleAdoption] = []
    @MainActor private var isIdleAdoptionScheduled = false
    @MainActor private var idleAdoptionTimer: Timer?
    @MainActor private var onHeightChangingContentWillAdopt: (() -> Void)?

    @MainActor
    func setHeightChangeHandler(_ handler: (() -> Void)?) {
        onHeightChangingContentWillAdopt = handler
    }

    @MainActor
    func setLiveScrolling(_ value: Bool) {
        guard isLiveScrolling != value else { return }
        isLiveScrolling = value
        if value {
            idleAdoptionTimer?.invalidate()
            idleAdoptionTimer = nil
            isIdleAdoptionScheduled = false
            return
        }
        scheduleNextIdleAdoption()
    }

    @MainActor
    func setIncrementalRestorationActive(_ value: Bool) {
        guard isIncrementalRestorationActive != value else { return }
        isIncrementalRestorationActive = value
        guard !value else { return }
        scheduleNextIdleAdoption()
    }

    @MainActor
    var isLiveScrollActive: Bool { isLiveScrolling }

    /// Runs a row-local content swap atomically while the viewport is idle.
    /// Cancellation removes recycled rows from the queue, and a new gesture
    /// cannot begin between the idle check and the state mutation because the
    /// handler and action execute in one main-actor operation.
    @MainActor
    func adoptHeightChangingContentWhenIdle(
        _ action: @escaping @MainActor () -> Void
    ) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        let cancellationToken = CancellationToken()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                idleAdoptions.append(
                    IdleAdoption(
                        id: id,
                        cancellationToken: cancellationToken,
                        action: action,
                        continuation: continuation
                    )
                )
                scheduleNextIdleAdoption()
            }
        } onCancel: {
            // Main-actor removal is asynchronous. Mark synchronously so an
            // immediate end-of-scroll on the main actor cannot adopt a stale
            // recycled row before that removal task runs.
            cancellationToken.cancel()
            Task { @MainActor [weak self] in
                self?.cancelIdleAdoption(id: id)
            }
        }
    }

    @MainActor
    private func cancelIdleAdoption(id: UUID) {
        guard let index = idleAdoptions.firstIndex(where: { $0.id == id }) else {
            return
        }
        idleAdoptions.remove(at: index).continuation.resume()
    }

    @MainActor
    func cancelPendingAdoptions() {
        idleAdoptionTimer?.invalidate()
        idleAdoptionTimer = nil
        isIdleAdoptionScheduled = false
        let pending = idleAdoptions
        idleAdoptions.removeAll(keepingCapacity: true)
        for adoption in pending {
            adoption.continuation.resume()
        }
    }

    @MainActor
    private func performNextIdleAdoption() {
        idleAdoptionTimer = nil
        isIdleAdoptionScheduled = false
        guard !isLiveScrolling, !isIncrementalRestorationActive else { return }
        while !idleAdoptions.isEmpty,
              idleAdoptions[0].cancellationToken.isCancelled {
            idleAdoptions.removeFirst().continuation.resume()
        }
        guard !idleAdoptions.isEmpty else { return }
        let adoption = idleAdoptions.removeFirst()
        guard adoption.cancellationToken.claim() else {
            adoption.continuation.resume()
            performNextIdleAdoption()
            return
        }
        onHeightChangingContentWillAdopt?()
        adoption.action()
        adoption.continuation.resume()
        scheduleNextIdleAdoption()
    }

    @MainActor
    private func scheduleNextIdleAdoption() {
        guard !isLiveScrolling,
              !isIncrementalRestorationActive,
              !idleAdoptions.isEmpty,
              !isIdleAdoptionScheduled else { return }
        isIdleAdoptionScheduled = true
        // Plain content is already visible. Pace selectable/rich promotion to
        // one bounded row per 60 Hz interval so a warm viewport cannot drain
        // several TextKit height changes before the next display frame.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.performNextIdleAdoption()
            }
        }
        idleAdoptionTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

private struct MacTranscriptScrollActivityKey: EnvironmentKey {
    static let defaultValue = MacTranscriptScrollActivity()
}

extension EnvironmentValues {
    var macTranscriptScrollActivity: MacTranscriptScrollActivity {
        get { self[MacTranscriptScrollActivityKey.self] }
        set { self[MacTranscriptScrollActivityKey.self] = newValue }
    }
}

@MainActor
final class MacConversationTableCommandHandle {
    var performJump: (() -> Void)?
}

/// Complete, bounded native text content for one reusable transcript tile.
/// Callers retain control of link routing and may provide a deferred artifact;
/// the table adopts that artifact only after live scrolling has ended.
struct MacConversationNativeTextPresentation {
    enum HorizontalAlignment: Equatable {
        case fill
        case leading
        case center
        case trailing
    }

    struct RoundedCorners: OptionSet {
        let rawValue: UInt8

        static let topLeading = Self(rawValue: 1 << 0)
        static let topTrailing = Self(rawValue: 1 << 1)
        static let bottomLeading = Self(rawValue: 1 << 2)
        static let bottomTrailing = Self(rawValue: 1 << 3)
        static let all: Self = [
            .topLeading,
            .topTrailing,
            .bottomLeading,
            .bottomTrailing,
        ]
    }

    struct DeferredArtifact: @unchecked Sendable {
        private let resolver: @MainActor () -> NSAttributedString?

        init(resolver: @escaping @MainActor () -> NSAttributedString?) {
            self.resolver = resolver
        }

        @MainActor
        func resolve() -> NSAttributedString? {
            resolver()
        }
    }

    typealias DeferredAttributedString = @Sendable () async -> DeferredArtifact?
    typealias LinkHandler = @MainActor (URL) -> Bool

    let attributedString: NSAttributedString?
    let fallbackString: String
    let contentInsets: NSEdgeInsets
    let firstRowTopInsetAdjustment: CGFloat
    let lastRowBottomInsetAdjustment: CGFloat
    let textContainerInset: NSSize
    let textEdgeInsets: NSEdgeInsets
    let minimumTextContainerHeight: CGFloat
    let maximumContentWidth: CGFloat?
    let maximumTextWidth: CGFloat?
    let backgroundColor: NSColor?
    let backgroundCornerRadius: CGFloat
    let roundedCorners: RoundedCorners
    let horizontalAlignment: HorizontalAlignment
    let fallbackFont: NSFont?
    let fallbackColor: NSColor?
    let fallbackParagraphStyle: NSParagraphStyle?
    let accessibilityLabel: String?
    let accessibilityIdentifier: String?
    let linkHandler: LinkHandler?
    let deferredAttributedString: DeferredAttributedString?
    let usesFastPlainTextRenderer: Bool
    let promotesFastRendererWhenIdle: Bool

    init(
        attributedString: NSAttributedString? = nil,
        fallbackString: String,
        contentInsets: NSEdgeInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: 0
        ),
        firstRowTopInsetAdjustment: CGFloat = 0,
        lastRowBottomInsetAdjustment: CGFloat = 0,
        textContainerInset: NSSize = .zero,
        textEdgeInsets: NSEdgeInsets = NSEdgeInsets(
            top: 0,
            left: 0,
            bottom: 0,
            right: 0
        ),
        minimumTextContainerHeight: CGFloat = 0,
        maximumContentWidth: CGFloat? = nil,
        maximumTextWidth: CGFloat? = nil,
        backgroundColor: NSColor? = nil,
        backgroundCornerRadius: CGFloat = 0,
        roundedCorners: RoundedCorners = [],
        horizontalAlignment: HorizontalAlignment = .fill,
        fallbackFont: NSFont? = nil,
        fallbackColor: NSColor? = nil,
        fallbackParagraphStyle: NSParagraphStyle? = nil,
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        linkHandler: LinkHandler? = nil,
        deferredAttributedString: DeferredAttributedString? = nil,
        usesFastPlainTextRenderer: Bool = false,
        promotesFastRendererWhenIdle: Bool = false
    ) {
        // Prepared transcript artifacts are immutable and cache-owned. Keep
        // their identity so mounting a native cell does not allocate/copy the
        // full attributed tile on the main actor.
        self.attributedString = attributedString
        self.fallbackString = fallbackString
        self.contentInsets = contentInsets
        self.firstRowTopInsetAdjustment = firstRowTopInsetAdjustment.isFinite
            ? firstRowTopInsetAdjustment
            : 0
        self.lastRowBottomInsetAdjustment = lastRowBottomInsetAdjustment.isFinite
            ? lastRowBottomInsetAdjustment
            : 0
        self.textContainerInset = textContainerInset
        self.textEdgeInsets = textEdgeInsets
        self.minimumTextContainerHeight = minimumTextContainerHeight.isFinite
            ? max(0, minimumTextContainerHeight)
            : 0
        self.maximumContentWidth = maximumContentWidth.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.maximumTextWidth = maximumTextWidth.flatMap {
            $0.isFinite && $0 > 0 ? $0 : nil
        }
        self.backgroundColor = backgroundColor
        self.backgroundCornerRadius = backgroundCornerRadius.isFinite
            ? max(0, backgroundCornerRadius)
            : 0
        self.roundedCorners = roundedCorners
        self.horizontalAlignment = horizontalAlignment
        self.fallbackFont = fallbackFont
        self.fallbackColor = fallbackColor
        self.fallbackParagraphStyle = fallbackParagraphStyle?.copy()
            as? NSParagraphStyle
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.linkHandler = linkHandler
        self.deferredAttributedString = deferredAttributedString
        self.usesFastPlainTextRenderer = usesFastPlainTextRenderer
        self.promotesFastRendererWhenIdle = promotesFastRendererWhenIdle
    }

    /// Copies only layout and plain styling into the frame-critical scroll
    /// presentation. Rich artifacts, links, and deferred work deliberately do
    /// not cross this boundary; the exact source is restored to the ordinary
    /// selectable presentation when the gesture ends.
    @MainActor
    func liveScrollCopy(
        fallbackString: String,
        accessibilityLabel: String?,
        minimumTextContainerHeight: CGFloat? = nil
    ) -> Self {
        Self(
            fallbackString: fallbackString,
            contentInsets: contentInsets,
            firstRowTopInsetAdjustment: firstRowTopInsetAdjustment,
            lastRowBottomInsetAdjustment: lastRowBottomInsetAdjustment,
            textContainerInset: textContainerInset,
            textEdgeInsets: textEdgeInsets,
            minimumTextContainerHeight: max(
                self.minimumTextContainerHeight,
                minimumTextContainerHeight ?? 0
            ),
            maximumContentWidth: maximumContentWidth,
            maximumTextWidth: maximumTextWidth,
            backgroundColor: backgroundColor,
            backgroundCornerRadius: backgroundCornerRadius,
            roundedCorners: roundedCorners,
            horizontalAlignment: horizontalAlignment,
            fallbackFont: fallbackFont,
            fallbackColor: fallbackColor,
            fallbackParagraphStyle: fallbackParagraphStyle,
            accessibilityLabel: accessibilityLabel,
            accessibilityIdentifier: accessibilityIdentifier,
            usesFastPlainTextRenderer: true
        )
    }
}

/// Lightweight native controls for the action row following a completed
/// message. Keeping this repeated row out of SwiftUI avoids constructing a
/// new view graph every time a cold message boundary enters the viewport.
struct MacConversationNativeFooterPresentation {
    let itemID: String
    let timestampLabel: String?
    let timestampAccessibilityLabel: String?
    let isTrailing: Bool
    let fontScale: CGFloat
    let accessibilityIdentifier: String?
}

protocol MacConversationTableRow: Equatable, Identifiable where ID == String {
    var contentRevision: UInt64 { get }
    var reuseIdentifier: String { get }
    /// Non-nil rows bypass SwiftUI hosting and render as one direct AppKit text
    /// view. Existing interactive or streaming rows continue through `makeRow`.
    @MainActor
    func nativeTextPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeTextPresentation?
    /// Exact, noninteractive text used only while a live gesture owns the
    /// viewport. Rows may replace richer controls with this presentation and
    /// restore their ordinary content after scrolling ends.
    @MainActor
    func liveScrollTextPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeTextPresentation?
    /// Non-nil completed-message footers use one reusable AppKit button/label
    /// cell instead of paying a SwiftUI hosting transition at every message.
    @MainActor
    func nativeFooterPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeFooterPresentation?
    /// The logical transcript record that owns this rendered row. A single
    /// record can project into many reusable table rows, so mutation IDs from
    /// the store do not necessarily match `id`.
    var mutationSourceID: String { get }
}

extension MacConversationTableRow {
    var mutationSourceID: String { id }
    @MainActor
    func nativeTextPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeTextPresentation? {
        nil
    }

    @MainActor
    func liveScrollTextPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeTextPresentation? {
        nativeTextPresentation(
            dynamicTypeSize: dynamicTypeSize,
            colorScheme: colorScheme
        )
    }

    @MainActor
    func nativeFooterPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeFooterPresentation? {
        nil
    }
}

/// A bounded group of projected table rows. Callers advance `revision` when
/// any row in the logical section changes; unchanged sections are then compared
/// without walking their rows.
struct MacConversationTableSection<Row> {
    let id: String
    let revision: UInt64
    let rows: [Row]
}

private struct MacConversationTableSnapshot<Row> {
    let sections: [MacConversationTableSection<Row>]
    let offsets: [Int]
    let count: Int

    init(sections: [MacConversationTableSection<Row>]) {
        self.sections = sections
        var offsets: [Int] = []
        offsets.reserveCapacity(sections.count + 1)
        offsets.append(0)
        for section in sections {
            offsets.append(offsets[offsets.count - 1] + section.rows.count)
        }
        self.offsets = offsets
        count = offsets.last ?? 0
    }

    static var empty: Self { Self(sections: []) }

    func hasSameIdentityAndRevisions(as other: Self) -> Bool {
        guard sections.count == other.sections.count else { return false }
        return sections.indices.allSatisfy { index in
            let lhs = sections[index]
            let rhs = other.sections[index]
            return lhs.id == rhs.id
                && lhs.revision == rhs.revision
                && lhs.rows.count == rhs.rows.count
        }
    }

    func location(ofFlatIndex index: Int) -> (section: Int, row: Int)? {
        guard index >= 0, index < count else { return nil }
        var lower = 0
        var upper = sections.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if offsets[middle + 1] <= index {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return (lower, index - offsets[lower])
    }

    subscript(index: Int) -> Row {
        let location = location(ofFlatIndex: index)!
        return sections[location.section].rows[location.row]
    }

    func rows(in range: Range<Int>) -> [Row] {
        range.map { self[$0] }
    }
}

@MainActor
enum MacConversationTableDiagnostics {
    struct Snapshot: Equatable {
        let reloadDataCalls: Int
        let targetedRowReloads: Int
        let preciseMutationPasses: Int
        let rowConfigurations: Int
        let ordinaryMountConfigurations: Int
        let explicitReconfigurations: Int
        let measuredRows: Int
        let heightInvalidationPasses: Int
        let scrollOriginCorrections: Int
        let watchedSourceConfigurations: Int
        let liveScrollRestorationPasses: Int
        let maximumLiveScrollRestorationsPerPass: Int
        let maximumLiveScrollRestorationMilliseconds: Double
        let maximumLiveScrollEndMilliseconds: Double
    }

    private(set) static var reloadDataCalls = 0
    private(set) static var targetedRowReloads = 0
    private(set) static var preciseMutationPasses = 0
    private(set) static var rowConfigurations = 0
    private(set) static var ordinaryMountConfigurations = 0
    private(set) static var explicitReconfigurations = 0
    private(set) static var measuredRows = 0
    private(set) static var heightInvalidationPasses = 0
    private(set) static var scrollOriginCorrections = 0
    private(set) static var watchedSourceConfigurations = 0
    private(set) static var liveScrollRestorationPasses = 0
    private(set) static var maximumLiveScrollRestorationsPerPass = 0
    private(set) static var maximumLiveScrollRestorationMilliseconds = 0.0
    private(set) static var maximumLiveScrollEndMilliseconds = 0.0
    private static var watchedMutationSourceID: String?

    static func reset() {
        reloadDataCalls = 0
        targetedRowReloads = 0
        preciseMutationPasses = 0
        rowConfigurations = 0
        ordinaryMountConfigurations = 0
        explicitReconfigurations = 0
        measuredRows = 0
        heightInvalidationPasses = 0
        scrollOriginCorrections = 0
        watchedSourceConfigurations = 0
        liveScrollRestorationPasses = 0
        maximumLiveScrollRestorationsPerPass = 0
        maximumLiveScrollRestorationMilliseconds = 0
        maximumLiveScrollEndMilliseconds = 0
        watchedMutationSourceID = nil
    }

    static func snapshot() -> Snapshot {
        Snapshot(
            reloadDataCalls: reloadDataCalls,
            targetedRowReloads: targetedRowReloads,
            preciseMutationPasses: preciseMutationPasses,
            rowConfigurations: rowConfigurations,
            ordinaryMountConfigurations: ordinaryMountConfigurations,
            explicitReconfigurations: explicitReconfigurations,
            measuredRows: measuredRows,
            heightInvalidationPasses: heightInvalidationPasses,
            scrollOriginCorrections: scrollOriginCorrections,
            watchedSourceConfigurations: watchedSourceConfigurations,
            liveScrollRestorationPasses: liveScrollRestorationPasses,
            maximumLiveScrollRestorationsPerPass:
                maximumLiveScrollRestorationsPerPass,
            maximumLiveScrollRestorationMilliseconds:
                maximumLiveScrollRestorationMilliseconds,
            maximumLiveScrollEndMilliseconds: maximumLiveScrollEndMilliseconds
        )
    }

    static func watchConfigurations(for mutationSourceID: String?) {
        watchedMutationSourceID = mutationSourceID
        watchedSourceConfigurations = 0
    }

    static func recordedReload() { reloadDataCalls += 1 }
    static func recordedTargetedRowReload(count: Int) {
        targetedRowReloads += count
    }
    static func recordedPreciseMutation() { preciseMutationPasses += 1 }
    static func recordedConfiguration(
        mutationSourceID: String,
        isExplicit: Bool
    ) {
        rowConfigurations += 1
        if mutationSourceID == watchedMutationSourceID {
            watchedSourceConfigurations += 1
        }
        if isExplicit {
            explicitReconfigurations += 1
        } else {
            ordinaryMountConfigurations += 1
        }
        measuredRows += 1
    }
    static func recordedHeightInvalidation() { heightInvalidationPasses += 1 }
    static func recordedScrollOriginCorrection() { scrollOriginCorrections += 1 }
    static func recordedLiveScrollRestoration(
        restoredRows: Int,
        milliseconds: Double
    ) {
        liveScrollRestorationPasses += 1
        maximumLiveScrollRestorationsPerPass = max(
            maximumLiveScrollRestorationsPerPass,
            restoredRows
        )
        maximumLiveScrollRestorationMilliseconds = max(
            maximumLiveScrollRestorationMilliseconds,
            milliseconds
        )
    }
    static func recordedLiveScrollEnd(milliseconds: Double) {
        maximumLiveScrollEndMilliseconds = max(
            maximumLiveScrollEndMilliseconds,
            milliseconds
        )
    }
}

/// A view-based AppKit transcript. The table owns scrolling and row geometry;
/// SwiftUI owns only the bounded content mounted in visible reusable cells.
struct MacConversationTableView<Row: MacConversationTableRow>: NSViewRepresentable {
    typealias NSViewType = NSScrollView

    let sections: [MacConversationTableSection<Row>]
    let snapshotGeneration: String?
    var transcriptMutation: TranscriptMutation? = nil
    var dataRevision: Int? = nil
    var styleRevision: Int = 0
    let reduceMotion: Bool
    let commandHandle: MacConversationTableCommandHandle
    let onNearBottomChange: (Bool) -> Void
    var onLiveScrollingChange: (Bool) -> Void = { _ in }
    let onAnchoredChange: (Bool) -> Void
    var prefetchRows: ([Row]) async -> Void = { _ in }
    var onNativeLink: @MainActor (URL) -> Bool = { _ in true }
    var onNativeCopyMessage: @MainActor (String) -> Void = { _ in }
    let makeRow: (Row, Bool, Bool) -> AnyView

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
            sections: sections,
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
            prefetchRows: prefetchRows,
            onNativeLink: onNativeLink,
            onNativeCopyMessage: onNativeCopyMessage,
            makeRow: makeRow
        )
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private enum PrefetchDirection: Equatable {
            case earlier
            case later
        }

        private weak var scrollView: NSScrollView?
        private weak var tableView: NSTableView?
        private var snapshot = MacConversationTableSnapshot<Row>.empty
        private var sectionIndexByID: [String: Int] = [:]
        private var snapshotGeneration: String?
        private var lastTranscriptMutationRevision: UInt64 = 0
        private var dataRevision: Int?
        private var styleRevision = 0
        private var environment = EnvironmentValues()
        private var makeRow: (Row, Bool, Bool) -> AnyView = { _, _, _ in
            AnyView(EmptyView())
        }
        private var onNearBottomChange: (Bool) -> Void = { _ in }
        private var onLiveScrollingChange: (Bool) -> Void = { _ in }
        private var onAnchoredChange: (Bool) -> Void = { _ in }
        private var prefetchRows: ([Row]) async -> Void = { _ in }
        private var onNativeLink: @MainActor (URL) -> Bool = { _ in true }
        private var onNativeCopyMessage: @MainActor (String) -> Void = { _ in }
        private var viewportPrefetchTask: Task<Void, Never>?
        private let scrollActivity = MacTranscriptScrollActivity()
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
        private var wheelScrollWindowActive = false
        private var wheelQuiescenceTimer: Timer?
        private var pendingLiveScrollHeightInvalidations = IndexSet()
        private let liveScrollCells = NSHashTable<MacConversationReusableCell>
            .weakObjects()
        private var liveScrollRestorationQueue: [LiveScrollRestoration] = []
        private var liveScrollRestorationIndex = 0
        private var liveScrollRestorationTimer: Timer?
        private var pendingLiveScrollRestorationAnchor: Anchor?
        private var pendingLiveScrollRestorationFollowsBottom = false
        private var pendingLiveScrollRestorationExpectedOriginY: CGFloat?
        private var lastViewportWidth: CGFloat?
        private var prefetchedRange: Range<Int>?
        private var lastPrefetchVisibleLowerBound: Int?
        private var lastPrefetchDirection: PrefetchDirection?

        private struct Anchor {
            let sectionID: String
            let rowID: String
            let localRowIndex: Int
            let offset: CGFloat
        }

        private final class LiveScrollRestoration {
            weak var cell: MacConversationReusableCell?
            let rowID: String
            let originalIndex: Int
            let reloadsCell: Bool

            init(
                cell: MacConversationReusableCell?,
                rowID: String,
                originalIndex: Int,
                reloadsCell: Bool
            ) {
                self.cell = cell
                self.rowID = rowID
                self.originalIndex = originalIndex
                self.reloadsCell = reloadsCell
            }
        }

        func attach(scrollView: NSScrollView, tableView: NSTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            scrollActivity.setHeightChangeHandler { [weak self] in
                self?.preparedContentWillChangeHeight()
            }
            (scrollView as? MacConversationTranscriptScrollView)?.onLayout = { [weak self] in
                _ = self?.applyPendingScrollCorrectionIfReady()
            }
            (scrollView as? MacConversationTranscriptScrollView)?.onWheelEvent = { [weak self] event in
                self?.wheelEventDidArrive(event)
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
                    MainActor.assumeIsolated { self?.viewportDidScroll() }
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
                    MainActor.assumeIsolated { self?.trackpadLiveScrollWillStart() }
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
            scrollActivity.setHeightChangeHandler(nil)
            // Recycled hosts may still be waiting to publish a prepared text
            // artifact. Drop those swaps before leaving live-scroll mode so
            // teardown cannot briefly mount stale content or measure its row.
            scrollActivity.cancelPendingAdoptions()
            scrollActivity.setLiveScrolling(false)
            scrollActivity.setIncrementalRestorationActive(false)
            (scrollView as? MacConversationTranscriptScrollView)?.onLayout = nil
            (scrollView as? MacConversationTranscriptScrollView)?.onWheelEvent = nil
            wheelQuiescenceTimer?.invalidate()
            wheelQuiescenceTimer = nil
            wheelScrollWindowActive = false
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
            liveScrollCells.removeAllObjects()
            cancelLiveScrollRestoration(requeueMountedCells: false)
            viewportPrefetchTask?.cancel()
            viewportPrefetchTask = nil
            lastViewportWidth = nil
            prefetchedRange = nil
            lastPrefetchVisibleLowerBound = nil
            lastPrefetchDirection = nil
        }

        func update(
            sections newSections: [MacConversationTableSection<Row>],
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
            prefetchRows: @escaping ([Row]) async -> Void,
            onNativeLink: @escaping @MainActor (URL) -> Bool,
            onNativeCopyMessage: @escaping @MainActor (String) -> Void,
            makeRow: @escaping (Row, Bool, Bool) -> AnyView
        ) {
            self.reduceMotion = reduceMotion
            self.environment = environment
            self.onNearBottomChange = onNearBottomChange
            self.onLiveScrollingChange = onLiveScrollingChange
            self.onAnchoredChange = onAnchoredChange
            self.prefetchRows = prefetchRows
            self.onNativeLink = onNativeLink
            self.onNativeCopyMessage = onNativeCopyMessage
            self.makeRow = makeRow
            commandHandle.performJump = { [weak self] in self?.jumpToLatest() }

            guard let tableView else { return }
            let newSnapshot = MacConversationTableSnapshot(sections: newSections)
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
            let rowsChanged = !snapshot.hasSameIdentityAndRevisions(as: newSnapshot)
            guard rowsChanged || styleChanged || generationChanged
                    || hasNewAuthoritativeReset else {
                snapshotGeneration = newSnapshotGeneration
                if let transcriptMutation {
                    lastTranscriptMutationRevision = transcriptMutation.revision
                }
                styleRevision = newStyleRevision
                return
            }
            let isInitialPopulation = snapshot.count == 0 && newSnapshot.count > 0
            if isInitialPopulation {
                tableView.rowHeight = estimatedAutomaticRowHeight(
                    in: newSnapshot,
                    viewportWidth: max(
                        800,
                        scrollView?.contentView.bounds.width
                            ?? tableView.bounds.width
                    )
                )
            }
            if generationChanged || styleChanged
                || snapshot.count != newSnapshot.count
                || snapshot.sections.first?.id != newSnapshot.sections.first?.id {
                prefetchedRange = nil
                lastPrefetchVisibleLowerBound = nil
                lastPrefetchDirection = nil
            }
            let needsInitialAnchor = isInitialPopulation
                || (!didInitialAnchor && newSnapshot.count > 0)
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
                    || snapshot.count == 0 || newSnapshot.count == 0 {
                    snapshot = newSnapshot
                    rebuildSectionIndex()
                    snapshotGeneration = newSnapshotGeneration
                    tableView.reloadData()
                    MacConversationTableDiagnostics.recordedReload()
                    didReload = true
                } else if rowsChanged {
                    let newMutation = transcriptMutation.flatMap {
                        $0.revision == lastTranscriptMutationRevision ? nil : $0
                    }
                    heightInvalidations.formUnion(applyPreciseChanges(
                        from: snapshot,
                        to: newSnapshot,
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
            } else if newSnapshot.count == 0 {
                didInitialAnchor = false
                pendingMutationAnchor = nil
                pendingMutationFollowsBottom = false
                pendingExpectedClipOriginY = nil
                DispatchQueue.main.async { [onAnchoredChange] in
                    onAnchoredChange(false)
                }
            }
            if newSnapshot.count > 0, !isLiveScrolling {
                scheduleMutationStabilization()
                if needsInitialAnchor {
                    DispatchQueue.main.async { [onAnchoredChange] in
                        onAnchoredChange(true)
                    }
                }
            }
            sampleNearBottom()
            scheduleViewportPrefetch()
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            snapshot.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row index: Int
        ) -> NSView? {
            guard let location = snapshot.location(ofFlatIndex: index) else { return nil }
            let section = snapshot.sections[location.section]
            let row = section.rows[location.row]
            let isFirst = index == 0
            let isLast = index == snapshot.count - 1
            let preparedContent = cellContent(
                for: row,
                isFirst: isFirst,
                isLast: isLast
            )
            let kind: MacConversationReusableCell.Kind = if isLiveScrolling,
                preparedContent.kind == .native {
                .nativeScroll
            } else {
                preparedContent.kind
            }
            let identifier = NSUserInterfaceItemIdentifier(
                "\(row.reuseIdentifier).\(kind.rawValue)"
            )
            let cell: MacConversationReusableCell
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil)
                as? MacConversationReusableCell,
               reused.kind == kind {
                cell = reused
            } else {
                switch kind {
                case .hosted:
                    cell = MacConversationHostedCell()
                case .native:
                    cell = MacConversationNativeTextCell()
                case .nativeScroll:
                    cell = MacConversationScrollTextCell()
                case .nativeFooter:
                    cell = MacConversationNativeFooterCell()
                }
                cell.identifier = identifier
            }
            configure(
                cell,
                with: row,
                isFirst: isFirst,
                isLast: isLast,
                preparedContent: preparedContent,
                isExplicit: false
            )
            if kind == .nativeScroll {
                liveScrollCells.add(cell)
            }
            return cell
        }

        private func applyPreciseChanges(
            from oldSnapshot: MacConversationTableSnapshot<Row>,
            to newSnapshot: MacConversationTableSnapshot<Row>,
            mutation: TranscriptMutation?,
            configureChangedRows: Bool,
            tableView: NSTableView
        ) -> IndexSet {
            let oldSectionIndex = Dictionary(
                oldSnapshot.sections.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            let newSectionIndex = Dictionary(
                newSnapshot.sections.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
            let oldCommonOrder = oldSnapshot.sections.compactMap {
                newSectionIndex[$0.id] == nil ? nil : $0.id
            }
            let newCommonOrder = newSnapshot.sections.compactMap {
                oldSectionIndex[$0.id] == nil ? nil : $0.id
            }

            guard oldCommonOrder == newCommonOrder else {
                snapshot = newSnapshot
                rebuildSectionIndex()
                tableView.reloadData()
                MacConversationTableDiagnostics.recordedReload()
                return []
            }

            var removals = IndexSet()
            var insertions = IndexSet()
            var changedIndexes = IndexSet()
            var cellClassChanges = IndexSet()

            for (sectionIndex, section) in oldSnapshot.sections.enumerated()
            where newSectionIndex[section.id] == nil {
                removals.insert(integersIn:
                    oldSnapshot.offsets[sectionIndex]..<oldSnapshot.offsets[sectionIndex + 1]
                )
            }
            for (sectionIndex, section) in newSnapshot.sections.enumerated()
            where oldSectionIndex[section.id] == nil {
                insertions.insert(integersIn:
                    newSnapshot.offsets[sectionIndex]..<newSnapshot.offsets[sectionIndex + 1]
                )
            }

            for sectionID in newCommonOrder {
                let oldSectionPosition = oldSectionIndex[sectionID]!
                let newSectionPosition = newSectionIndex[sectionID]!
                let oldSection = oldSnapshot.sections[oldSectionPosition]
                let newSection = newSnapshot.sections[newSectionPosition]
                guard oldSection.revision != newSection.revision
                        || oldSection.rows.count != newSection.rows.count else {
                    continue
                }

                let oldRowIndex = Dictionary(
                    oldSection.rows.enumerated().map { ($0.element.id, $0.offset) },
                    uniquingKeysWith: { first, _ in first }
                )
                let newRowIndex = Dictionary(
                    newSection.rows.enumerated().map { ($0.element.id, $0.offset) },
                    uniquingKeysWith: { first, _ in first }
                )
                let oldRowOrder = oldSection.rows.compactMap {
                    newRowIndex[$0.id] == nil ? nil : $0.id
                }
                let newRowOrder = newSection.rows.compactMap {
                    oldRowIndex[$0.id] == nil ? nil : $0.id
                }
                guard oldRowOrder == newRowOrder else {
                    snapshot = newSnapshot
                    rebuildSectionIndex()
                    tableView.reloadData()
                    MacConversationTableDiagnostics.recordedReload()
                    return []
                }

                let oldBase = oldSnapshot.offsets[oldSectionPosition]
                let newBase = newSnapshot.offsets[newSectionPosition]
                for (index, row) in oldSection.rows.enumerated()
                where newRowIndex[row.id] == nil {
                    removals.insert(oldBase + index)
                }
                for (index, row) in newSection.rows.enumerated() {
                    if oldRowIndex[row.id] == nil {
                        insertions.insert(newBase + index)
                    } else {
                        let oldRow = oldSection.rows[oldRowIndex[row.id]!]
                        if oldRow != row {
                            let flatIndex = newBase + index
                            changedIndexes.insert(flatIndex)
                            if cellKind(for: oldRow) != cellKind(for: row) {
                                cellClassChanges.insert(flatIndex)
                            }
                        }
                    }
                }
            }

            // Transcript padding belongs only to the global flattened edges.
            // Also revisit the surviving former edges: AppKit can retain their
            // hosted cells while an inserted row moves them inward, and their
            // content revision alone does not encode global padding.
            if let formerFirst = survivingFlatIndex(
                from: oldSnapshot,
                oldFlatIndex: 0,
                in: newSnapshot,
                newSectionIndex: newSectionIndex
            ) {
                changedIndexes.insert(formerFirst)
            }
            if let formerLast = survivingFlatIndex(
                from: oldSnapshot,
                oldFlatIndex: oldSnapshot.count - 1,
                in: newSnapshot,
                newSectionIndex: newSectionIndex
            ) {
                changedIndexes.insert(formerLast)
            }
            if newSnapshot.count > 0 {
                changedIndexes.insert(0)
                changedIndexes.insert(newSnapshot.count - 1)
            }

            _ = mutation // Revisions identify the bounded sections to inspect.
            snapshot = newSnapshot
            rebuildSectionIndex()
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

            // Live-scroll display cells are a viewport mode, not a model
            // property. A row that was already visible when the gesture began
            // can therefore have the right old/new model kind but the wrong
            // currently mounted cell class. Replace it before configuration
            // so streaming updates never send native content to a hosted cell.
            for index in changedIndexes
            where snapshot.location(ofFlatIndex: index) != nil {
                guard let cell = tableView.view(
                    atColumn: 0,
                    row: index,
                    makeIfNecessary: false
                ) as? MacConversationReusableCell else { continue }
                if cell.kind != cellKind(for: snapshot[index]) {
                    cellClassChanges.insert(index)
                }
            }

            if !cellClassChanges.isEmpty {
                tableView.reloadData(
                    forRowIndexes: cellClassChanges,
                    columnIndexes: IndexSet(integer: 0)
                )
                MacConversationTableDiagnostics.recordedTargetedRowReload(
                    count: cellClassChanges.count
                )
                changedIndexes.subtract(cellClassChanges)
            }

            guard configureChangedRows else { return cellClassChanges }
            var configuredIndexes = cellClassChanges
            for index in changedIndexes {
                guard snapshot.location(ofFlatIndex: index) != nil,
                      let cell = tableView.view(
                        atColumn: 0,
                        row: index,
                        makeIfNecessary: false
                      ) as? MacConversationReusableCell else {
                    continue
                }
                // Only rows whose cell actually changed re-measure; edge
                // indexes are revisited on every batch and would otherwise
                // re-fit the (possibly giant) first/last row each 33ms.
                if configure(
                    cell,
                    with: snapshot[index],
                    isFirst: index == 0,
                    isLast: index == snapshot.count - 1,
                    isExplicit: true
                ) {
                    configuredIndexes.insert(index)
                }
            }
            return configuredIndexes
        }

        private func survivingFlatIndex(
            from oldSnapshot: MacConversationTableSnapshot<Row>,
            oldFlatIndex: Int,
            in newSnapshot: MacConversationTableSnapshot<Row>,
            newSectionIndex: [String: Int]
        ) -> Int? {
            guard let oldLocation = oldSnapshot.location(ofFlatIndex: oldFlatIndex) else {
                return nil
            }
            let oldSection = oldSnapshot.sections[oldLocation.section]
            let rowID = oldSection.rows[oldLocation.row].id
            guard let sectionIndex = newSectionIndex[oldSection.id] else {
                return nil
            }
            let rows = newSnapshot.sections[sectionIndex].rows
            let rowIndex: Int?
            if rows.first?.id == rowID {
                rowIndex = 0
            } else if rows.last?.id == rowID {
                rowIndex = rows.count - 1
            } else {
                rowIndex = rows.firstIndex { $0.id == rowID }
            }
            guard let rowIndex else { return nil }
            return newSnapshot.offsets[sectionIndex] + rowIndex
        }

        private func reconfigureVisibleRows(in tableView: NSTableView) -> IndexSet {
            guard let scrollView else { return [] }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound else { return [] }
            var configuredIndexes = IndexSet()
            for index in visible.location..<NSMaxRange(visible) {
                guard snapshot.location(ofFlatIndex: index) != nil,
                      let cell = tableView.view(
                        atColumn: 0,
                        row: index,
                        makeIfNecessary: false
                      ) as? MacConversationReusableCell else {
                    continue
                }
                guard cell.kind == cellKind(for: snapshot[index]) else {
                    tableView.reloadData(
                        forRowIndexes: IndexSet(integer: index),
                        columnIndexes: IndexSet(integer: 0)
                    )
                    MacConversationTableDiagnostics.recordedTargetedRowReload(count: 1)
                    configuredIndexes.insert(index)
                    continue
                }
                configure(
                    cell,
                    with: snapshot[index],
                    isFirst: index == 0,
                    isLast: index == snapshot.count - 1,
                    force: true,
                    isExplicit: true
                )
                configuredIndexes.insert(index)
            }
            return configuredIndexes
        }

        @discardableResult
        private func configure(
            _ cell: MacConversationReusableCell,
            with row: Row,
            isFirst: Bool,
            isLast: Bool,
            force: Bool = false,
            preparedContent: MacConversationReusableCell.Content? = nil,
            isExplicit: Bool
        ) -> Bool {
            guard force || cell.representedRowID != row.id
                    || cell.contentRevision != row.contentRevision
                    || cell.isFirst != isFirst
                    || cell.isLast != isLast else {
                return false
            }
            // This is the frame-critical realization path. Store/projection
            // and table-mutation signposts retain end-to-end observability;
            // a begin/end signpost around every individual cell measurably
            // consumed the same frame budget it was intended to diagnose.
            cell.representedRowID = row.id
            cell.contentRevision = row.contentRevision
            cell.isFirst = isFirst
            cell.isLast = isLast
            cell.setContent(
                preparedContent ?? cellContent(
                    for: row,
                    isFirst: isFirst,
                    isLast: isLast
                ),
                scrollActivity: scrollActivity,
                nativeLinkHandler: onNativeLink,
                nativeCopyMessageHandler: onNativeCopyMessage
            )
            MacConversationTableDiagnostics.recordedConfiguration(
                mutationSourceID: row.mutationSourceID,
                isExplicit: isExplicit
            )
            return true
        }

        private func cellContent(
            for row: Row,
            isFirst: Bool,
            isLast: Bool
        ) -> MacConversationReusableCell.Content {
            if let presentation = row.nativeFooterPresentation(
                dynamicTypeSize: environment.dynamicTypeSize,
                colorScheme: environment.colorScheme
            ) {
                return isLiveScrolling
                    ? .native(liveScrollPresentation(for: presentation))
                    : .nativeFooter(presentation)
            }
            if isLiveScrolling,
               let presentation = row.liveScrollTextPresentation(
                    dynamicTypeSize: environment.dynamicTypeSize,
                    colorScheme: environment.colorScheme
               ) {
                return .native(presentation)
            }
            if let presentation = row.nativeTextPresentation(
                dynamicTypeSize: environment.dynamicTypeSize,
                colorScheme: environment.colorScheme
            ) {
                return .native(presentation)
            }
            return .hosted(AnyView(
                makeRow(row, isFirst, isLast)
                    .id(row.id)
                    .environment(\.self, environment)
                    .environment(
                        \.macTranscriptScrollActivity,
                        scrollActivity
                    )
            ))
        }

        private func cellKind(for row: Row) -> MacConversationReusableCell.Kind {
            if row.nativeFooterPresentation(
                dynamicTypeSize: environment.dynamicTypeSize,
                colorScheme: environment.colorScheme
            ) != nil {
                return isLiveScrolling ? .nativeScroll : .nativeFooter
            }
            let presentation = isLiveScrolling
                ? row.liveScrollTextPresentation(
                    dynamicTypeSize: environment.dynamicTypeSize,
                    colorScheme: environment.colorScheme
                )
                : row.nativeTextPresentation(
                    dynamicTypeSize: environment.dynamicTypeSize,
                    colorScheme: environment.colorScheme
                )
            guard presentation != nil else { return .hosted }
            return isLiveScrolling ? .nativeScroll : .native
        }

        private func liveScrollPresentation(
            for footer: MacConversationNativeFooterPresentation
        ) -> MacConversationNativeTextPresentation {
            MacConversationNativeTextPresentation(
                fallbackString: footer.timestampLabel ?? "",
                contentInsets: NSEdgeInsets(
                    top: 7,
                    left: 28,
                    bottom: 7,
                    right: 28
                ),
                firstRowTopInsetAdjustment: 15,
                lastRowBottomInsetAdjustment: 9,
                minimumTextContainerHeight: 44,
                maximumContentWidth: 760,
                maximumTextWidth: 220,
                horizontalAlignment: footer.isTrailing ? .trailing : .leading,
                fallbackFont: NSFont.systemFont(
                    ofSize: 11 * footer.fontScale
                ),
                fallbackColor: .secondaryLabelColor,
                accessibilityLabel: footer.timestampAccessibilityLabel,
                accessibilityIdentifier: footer.accessibilityIdentifier,
                usesFastPlainTextRenderer: true
            )
        }

        private func estimatedAutomaticRowHeight(
            in snapshot: MacConversationTableSnapshot<Row>,
            viewportWidth: CGFloat
        ) -> CGFloat {
            guard snapshot.count > 0, viewportWidth > 1 else { return 56 }
            let sampleCount = min(128, snapshot.count)
            var total: CGFloat = 0
            for sample in 0..<sampleCount {
                let index = sampleCount == 1
                    ? 0
                    : sample * (snapshot.count - 1) / (sampleCount - 1)
                total += estimatedHeight(
                    for: snapshot[index],
                    viewportWidth: viewportWidth
                )
            }
            // Automatic-height tables realize a burst of speculative cells
            // when their estimate is low. A deliberate upward bias costs only
            // provisional scroll-range accuracy; realized rows immediately
            // replace it with their exact intrinsic heights.
            let biasedMean = (total / CGFloat(sampleCount)) * 1.30
            return min(320, max(44, biasedMean.rounded()))
        }

        private func estimatedHeight(
            for row: Row,
            viewportWidth: CGFloat
        ) -> CGFloat {
            if row.nativeFooterPresentation(
                dynamicTypeSize: environment.dynamicTypeSize,
                colorScheme: environment.colorScheme
            ) != nil {
                return 58
            }
            guard let presentation = row.nativeTextPresentation(
                dynamicTypeSize: environment.dynamicTypeSize,
                colorScheme: environment.colorScheme
            ) else {
                return 56
            }
            let availableWidth = max(
                1,
                viewportWidth - presentation.contentInsets.left
                    - presentation.contentInsets.right
            )
            let containerWidth = min(
                availableWidth,
                presentation.maximumContentWidth ?? availableWidth
            )
            let alignedWidth = presentation.horizontalAlignment == .fill
                ? containerWidth
                : min(
                    containerWidth,
                    presentation.maximumTextWidth
                        ?? presentation.maximumContentWidth
                        ?? containerWidth
                )
            let textWidth = max(
                1,
                alignedWidth - presentation.textEdgeInsets.left
                    - presentation.textEdgeInsets.right
                    - (presentation.textContainerInset.width * 2)
            )
            let attributed = presentation.attributedString
                ?? NSAttributedString(
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
            let measured = attributed.boundingRect(
                with: NSSize(
                    width: textWidth,
                    height: CGFloat.greatestFiniteMagnitude
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return max(
                44,
                ceil(max(
                    measured.height
                        + presentation.textEdgeInsets.top
                        + presentation.textEdgeInsets.bottom
                        + (presentation.textContainerInset.height * 2),
                    presentation.minimumTextContainerHeight
                ))
                    + presentation.contentInsets.top
                    + presentation.contentInsets.bottom
            )
        }

        private func rebuildSectionIndex() {
            sectionIndexByID = Dictionary(
                snapshot.sections.enumerated().map { ($0.element.id, $0.offset) },
                uniquingKeysWith: { first, _ in first }
            )
        }

        private func prepareMutationStabilization(
            followsBottom: Bool,
            anchor: Anchor?
        ) {
            guard !isLiveScrolling else { return }
            // General model/style mutations own the viewport first. A
            // display-linked row restoration resumes only after that batch's
            // anchor has settled, so two independent correction owners can
            // never rewrite each other's expected clip origin.
            pendingLiveScrollRestorationAnchor = nil
            pendingLiveScrollRestorationFollowsBottom = false
            pendingLiveScrollRestorationExpectedOriginY = nil
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

        /// Legacy mouse wheels never post the willStart/didEndLiveScroll
        /// notification pair (per the NSScrollView header), so wheel scrolling
        /// previously bypassed every gesture protection: idle promotions and
        /// anchor corrections kept mutating rows under the moving viewport.
        /// Phase-less wheel events synthesize the same live-scroll window a
        /// trackpad gets, ended by a short quiescence timer.
        private func wheelEventDidArrive(_ event: NSEvent) {
            guard event.phase == [] && event.momentumPhase == [] else { return }
            if !isLiveScrolling {
                liveScrollDidBegin()
                wheelScrollWindowActive = true
            }
            guard wheelScrollWindowActive else { return }
            wheelQuiescenceTimer?.invalidate()
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.wheelQuiescenceTimer = nil
                    guard self.wheelScrollWindowActive else { return }
                    self.wheelScrollWindowActive = false
                    self.liveScrollDidEnd()
                }
            }
            wheelQuiescenceTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        /// A trackpad gesture takes ownership of any synthesized wheel
        /// window; its own didEnd notification will close the mode.
        private func trackpadLiveScrollWillStart() {
            wheelScrollWindowActive = false
            wheelQuiescenceTimer?.invalidate()
            wheelQuiescenceTimer = nil
            liveScrollDidBegin()
        }

        private func liveScrollDidBegin() {
            guard !isLiveScrolling else { return }
            scrollActivity.setLiveScrolling(true)
            scrollActivity.setIncrementalRestorationActive(false)
            let carriedCells = cancelLiveScrollRestoration(
                requeueMountedCells: true
            )
            // Already-mounted rows have completed layout and can move without
            // any configuration work. Replacing them here would front-load a
            // full visible-page reload into the first gesture frame. Only
            // rows newly realized (or changed) while scrolling use the cheap
            // display cell and are recorded for exact restoration below.
            liveScrollCells.removeAllObjects()
            for cell in carriedCells {
                liveScrollCells.add(cell)
            }
            isLiveScrolling = true
            cancelMutationStabilization()
            onLiveScrollingChange(true)
        }

        private func liveScrollDidEnd() {
            guard isLiveScrolling else { return }
            let startedAt = CACurrentMediaTime()
            defer {
                MacConversationTableDiagnostics.recordedLiveScrollEnd(
                    milliseconds: (CACurrentMediaTime() - startedAt) * 1_000
                )
            }
            isLiveScrolling = false
            scrollActivity.setIncrementalRestorationActive(true)
            scrollActivity.setLiveScrolling(false)
            guard let tableView else {
                liveScrollCells.removeAllObjects()
                pendingLiveScrollHeightInvalidations.removeAll()
                cancelLiveScrollRestoration(requeueMountedCells: false)
                scrollActivity.setIncrementalRestorationActive(false)
                onLiveScrollingChange(false)
                return
            }

            var transitionedIndexes = IndexSet()
            var restorations: [LiveScrollRestoration] = []
            let mountedCells = liveScrollCells.allObjects
            liveScrollCells.removeAllObjects()
            restorations.reserveCapacity(
                mountedCells.count + pendingLiveScrollHeightInvalidations.count
            )
            for cell in mountedCells where cell.kind == .nativeScroll {
                let index = tableView.row(for: cell)
                guard index >= 0,
                      snapshot.location(ofFlatIndex: index) != nil else {
                    continue
                }
                transitionedIndexes.insert(index)
                restorations.append(LiveScrollRestoration(
                    cell: cell,
                    rowID: snapshot[index].id,
                    originalIndex: index,
                    reloadsCell: true
                ))
            }
            for index in pendingLiveScrollHeightInvalidations
            where !transitionedIndexes.contains(index)
                && snapshot.location(ofFlatIndex: index) != nil {
                restorations.append(LiveScrollRestoration(
                    cell: nil,
                    rowID: snapshot[index].id,
                    originalIndex: index,
                    reloadsCell: false
                ))
            }
            pendingLiveScrollHeightInvalidations.removeAll()

            let visible = tableView.rows(
                in: scrollView?.contentView.bounds ?? tableView.visibleRect
            )
            let visibleMiddle = visible.location == NSNotFound
                ? 0
                : visible.location + (visible.length / 2)
            restorations.sort {
                abs($0.originalIndex - visibleMiddle)
                    < abs($1.originalIndex - visibleMiddle)
            }
            liveScrollRestorationQueue = restorations
            liveScrollRestorationIndex = 0
            sampleNearBottom()
            onLiveScrollingChange(false)
            scheduleViewportPrefetch()
            scheduleLiveScrollRestorationIfNeeded()
        }

        private func scheduleLiveScrollRestorationIfNeeded() {
            guard !isLiveScrolling,
                  liveScrollRestorationIndex < liveScrollRestorationQueue.count
                    || pendingLiveScrollRestorationAnchor != nil
                    || pendingLiveScrollRestorationFollowsBottom,
                  liveScrollRestorationTimer == nil else {
                if liveScrollRestorationIndex >= liveScrollRestorationQueue.count,
                   pendingLiveScrollRestorationAnchor == nil,
                   !pendingLiveScrollRestorationFollowsBottom {
                    finishLiveScrollRestoration()
                }
                return
            }
            // A run-loop timer, not NSWindow.displayLink: the underlying
            // CADisplayLink can fail to attach to the window's display (it
            // logs "failed to create CADisplayLink" and never fires), which
            // left the restoration queue stuck, live-scroll cells mounted
            // forever, and idle adoptions latched off. The timer matches the
            // 60 Hz pacing the idle-adoption queue already uses.
            let timer = Timer(
                timeInterval: 1.0 / 60.0,
                target: self,
                selector: #selector(restoreNextLiveScrollRow(_:)),
                userInfo: nil,
                repeats: true
            )
            liveScrollRestorationTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }

        @objc
        private func restoreNextLiveScrollRow(_ sender: Any) {
            guard !isLiveScrolling else { return }
            guard !stabilizationScheduled,
                  pendingMutationAnchor == nil,
                  !pendingMutationFollowsBottom else {
                return
            }
            let startedAt = CACurrentMediaTime()
            applyPendingLiveScrollRestorationCorrection()

            guard let tableView, let scrollView else {
                finishLiveScrollRestoration()
                return
            }
            // All still-visible transitioned rows restore in one batch so the
            // viewport flips to its resting rendering atomically; a row-per-
            // frame walk over the visible page read as a quarter-second of
            // rippling reflows. Off-screen rows keep the incremental pace.
            let visibleRange = tableView.rows(in: scrollView.contentView.bounds)
            var batchIndexes = IndexSet()
            var reloadIndexes = IndexSet()
            var remaining: [LiveScrollRestoration] = []
            var tookOffscreenFallback = false
            for position in liveScrollRestorationIndex..<liveScrollRestorationQueue.count {
                let restoration = liveScrollRestorationQueue[position]
                guard let index = currentIndex(for: restoration, in: tableView) else {
                    continue
                }
                let isVisible = visibleRange.location != NSNotFound
                    && NSLocationInRange(index, visibleRange)
                if isVisible {
                    batchIndexes.insert(index)
                    if restoration.reloadsCell { reloadIndexes.insert(index) }
                } else if batchIndexes.isEmpty && !tookOffscreenFallback {
                    tookOffscreenFallback = true
                    batchIndexes.insert(index)
                    if restoration.reloadsCell { reloadIndexes.insert(index) }
                } else {
                    remaining.append(restoration)
                }
            }
            if !batchIndexes.isEmpty {
                let followsBottom = isAtBottom
                pendingLiveScrollRestorationFollowsBottom = followsBottom
                pendingLiveScrollRestorationAnchor = followsBottom
                    ? nil
                    : captureAnchor()
                pendingLiveScrollRestorationExpectedOriginY = scrollView
                    .contentView.bounds.origin.y
                if !reloadIndexes.isEmpty {
                    tableView.reloadData(
                        forRowIndexes: reloadIndexes,
                        columnIndexes: IndexSet(integer: 0)
                    )
                    MacConversationTableDiagnostics.recordedTargetedRowReload(
                        count: reloadIndexes.count
                    )
                }
                tableView.noteHeightOfRows(withIndexesChanged: batchIndexes)
                MacConversationTableDiagnostics.recordedHeightInvalidation()
                scrollView.layoutSubtreeIfNeeded()
                tableView.layoutSubtreeIfNeeded()
                applyPendingLiveScrollRestorationCorrection(keepPending: true)
            }
            liveScrollRestorationQueue = remaining
            liveScrollRestorationIndex = 0

            MacConversationTableDiagnostics.recordedLiveScrollRestoration(
                restoredRows: batchIndexes.count,
                milliseconds: (CACurrentMediaTime() - startedAt) * 1_000
            )
            if remaining.isEmpty,
               pendingLiveScrollRestorationAnchor == nil,
               !pendingLiveScrollRestorationFollowsBottom {
                finishLiveScrollRestoration()
            }
        }

        private func currentIndex(
            for restoration: LiveScrollRestoration,
            in tableView: NSTableView
        ) -> Int? {
            let index: Int
            if let cell = restoration.cell {
                guard cell.kind == .nativeScroll else { return nil }
                index = tableView.row(for: cell)
            } else {
                index = restoration.originalIndex
            }
            guard index >= 0,
                  snapshot.location(ofFlatIndex: index) != nil,
                  snapshot[index].id == restoration.rowID else {
                return nil
            }
            return index
        }

        private func applyPendingLiveScrollRestorationCorrection(
            keepPending: Bool = false
        ) {
            guard pendingLiveScrollRestorationFollowsBottom
                    || pendingLiveScrollRestorationAnchor != nil else { return }
            if !keepPending,
               let scrollView,
               let expected = pendingLiveScrollRestorationExpectedOriginY,
               abs(scrollView.contentView.bounds.origin.y - expected) > 0.5 {
                pendingLiveScrollRestorationAnchor = nil
                pendingLiveScrollRestorationFollowsBottom = false
                pendingLiveScrollRestorationExpectedOriginY = nil
                return
            }
            if pendingLiveScrollRestorationFollowsBottom {
                pinToBottom()
            } else if let anchor = pendingLiveScrollRestorationAnchor {
                restore(anchor)
            }
            if keepPending {
                pendingLiveScrollRestorationExpectedOriginY = scrollView?
                    .contentView.bounds.origin.y
            } else {
                pendingLiveScrollRestorationAnchor = nil
                pendingLiveScrollRestorationFollowsBottom = false
                pendingLiveScrollRestorationExpectedOriginY = nil
            }
        }

        @discardableResult
        private func cancelLiveScrollRestoration(
            requeueMountedCells: Bool
        ) -> [MacConversationReusableCell] {
            liveScrollRestorationTimer?.invalidate()
            liveScrollRestorationTimer = nil
            let cells = requeueMountedCells
                ? liveScrollRestorationQueue[liveScrollRestorationIndex...]
                    .compactMap(\.cell)
                    .filter { $0.kind == .nativeScroll }
                : []
            liveScrollRestorationQueue.removeAll(keepingCapacity: true)
            liveScrollRestorationIndex = 0
            pendingLiveScrollRestorationAnchor = nil
            pendingLiveScrollRestorationFollowsBottom = false
            pendingLiveScrollRestorationExpectedOriginY = nil
            return cells
        }

        private func finishLiveScrollRestoration() {
            liveScrollRestorationTimer?.invalidate()
            liveScrollRestorationTimer = nil
            liveScrollRestorationQueue.removeAll(keepingCapacity: true)
            liveScrollRestorationIndex = 0
            scrollActivity.setIncrementalRestorationActive(false)
            sampleNearBottom()
            scheduleViewportPrefetch()
        }

        /// A row-local render artifact can change intrinsic height without a
        /// store mutation. Capture the user's current anchor before SwiftUI
        /// adopts it, then use the same bounded stabilization path as model
        /// changes so the post-gesture update cannot move the viewport.
        private func preparedContentWillChangeHeight() {
            guard !isLiveScrolling else { return }
            let followsBottom = isAtBottom
            prepareMutationStabilization(
                followsBottom: followsBottom,
                anchor: followsBottom ? nil : captureAnchor()
            )
            scheduleMutationStabilization()
        }

        private func cancelMutationStabilization() {
            stabilizationGeneration &+= 1
            stabilizationScheduled = false
            pendingMutationAnchor = nil
            pendingMutationFollowsBottom = false
            pendingExpectedClipOriginY = nil
        }

        private func primePinnedDocumentGeometry() {
            guard let tableView, let scrollView, snapshot.count > 0 else { return }
            let estimatedHeight = CGFloat(snapshot.count) * tableView.rowHeight
                + CGFloat(max(0, snapshot.count - 1)) * tableView.intercellSpacing.height
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
            if snapshot.count > 0 {
                guard let tableView else { return false }
                let expectedContentHeight = tableView.rect(
                    ofRow: snapshot.count - 1
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

        private func captureAnchor() -> Anchor? {
            guard let tableView, let scrollView, snapshot.count > 0 else { return nil }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound,
                  let location = snapshot.location(ofFlatIndex: visible.location) else {
                return nil
            }
            let rect = tableView.rect(ofRow: visible.location)
            return Anchor(
                sectionID: snapshot.sections[location.section].id,
                rowID: snapshot[visible.location].id,
                localRowIndex: location.row,
                offset: rect.minY - scrollView.contentView.bounds.minY
            )
        }

        private func restore(_ anchor: Anchor) {
            guard let tableView, let scrollView,
                  let sectionIndex = sectionIndexByID[anchor.sectionID] else { return }
            let sectionRows = snapshot.sections[sectionIndex].rows
            let localIndex: Int?
            if sectionRows.indices.contains(anchor.localRowIndex),
               sectionRows[anchor.localRowIndex].id == anchor.rowID {
                // Prepared/highlight adoption does not mutate the snapshot;
                // restoring its anchor must therefore be O(1), even inside a
                // maximum 8.4k-row logical item.
                localIndex = anchor.localRowIndex
            } else {
                // A simultaneous insertion/removal inside the anchored
                // logical section is the exceptional mutation path.
                localIndex = sectionRows.firstIndex { $0.id == anchor.rowID }
            }
            guard let localIndex else { return }
            let index = snapshot.offsets[sectionIndex] + localIndex
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

        private func viewportDidScroll() {
            sampleNearBottom()
            scheduleViewportPrefetch()
        }

        /// Warms a bounded band around the viewport. The range only advances
        /// after the visible rows approach its edge, so ordinary wheel events
        /// do not enqueue work on every frame.
        private func scheduleViewportPrefetch() {
            guard let tableView, let scrollView, snapshot.count > 0 else { return }
            let visible = tableView.rows(in: scrollView.contentView.bounds)
            guard visible.location != NSNotFound, visible.length > 0 else { return }
            let visibleLower = visible.location
            let visibleUpper = min(snapshot.count, NSMaxRange(visible))
            let previousVisibleLower = lastPrefetchVisibleLowerBound
            lastPrefetchVisibleLowerBound = visibleLower
            let didMove = previousVisibleLower.map { $0 != visibleLower } ?? false
            let direction: PrefetchDirection
            if let previousVisibleLower, visibleLower != previousVisibleLower {
                direction = visibleLower > previousVisibleLower ? .later : .earlier
            } else {
                direction = lastPrefetchDirection ?? .earlier
            }
            let directionReversed = didMove
                && lastPrefetchDirection.map { $0 != direction } == true
            if didMove || lastPrefetchDirection == nil {
                lastPrefetchDirection = direction
            }
            let triggerPadding = 6
            if let prefetchedRange,
               prefetchedRange.lowerBound <= max(0, visibleLower - triggerPadding),
               prefetchedRange.upperBound >= min(snapshot.count, visibleUpper + triggerPadding),
               !directionReversed {
                return
            }
            let overscan = 24
            let range = max(0, visibleLower - overscan)..<min(
                snapshot.count,
                visibleUpper + overscan
            )
            prefetchedRange = range
            var prioritized: [Row] = []
            prioritized.reserveCapacity(range.count)
            prioritized.append(contentsOf: snapshot.rows(in: visibleLower..<visibleUpper))
            let earlier = snapshot.rows(in: range.lowerBound..<visibleLower).reversed()
            let later = snapshot.rows(in: visibleUpper..<range.upperBound)
            if direction == .later {
                // Moving toward latest: put the rows ahead of the gesture in
                // the global preparation gate before the rows now behind it.
                prioritized.append(contentsOf: later)
                prioritized.append(contentsOf: earlier)
            } else {
                // Initial population opens at latest and normally moves into
                // older history, so earlier rows are the useful default.
                prioritized.append(contentsOf: earlier)
                prioritized.append(contentsOf: later)
            }
            viewportPrefetchTask?.cancel()
            viewportPrefetchTask = Task { [prefetchRows] in
                await prefetchRows(prioritized)
            }
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
            guard snapshot.count > 0 else { return }
            let followsBottom = isAtBottom
            if !isLiveScrolling {
                tableView.rowHeight = estimatedAutomaticRowHeight(
                    in: snapshot,
                    viewportWidth: width
                )
            }
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
private class MacConversationReusableCell: NSTableCellView {
    enum Kind: String {
        case hosted
        case native
        case nativeScroll = "native-scroll"
        case nativeFooter = "native-footer"
    }

    enum Content {
        case hosted(AnyView)
        case native(MacConversationNativeTextPresentation)
        case nativeFooter(MacConversationNativeFooterPresentation)

        var kind: Kind {
            switch self {
            case .hosted: .hosted
            case .native: .native
            case .nativeFooter: .nativeFooter
            }
        }
    }

    let kind: Kind
    var representedRowID: String?
    var contentRevision: UInt64 = 0
    var isFirst = false
    var isLast = false

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(
        _ content: Content,
        scrollActivity: MacTranscriptScrollActivity,
        nativeLinkHandler: @escaping MacConversationNativeTextPresentation.LinkHandler,
        nativeCopyMessageHandler: @escaping @MainActor (String) -> Void
    ) {
        preconditionFailure("Reusable transcript cell must implement content adoption")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedRowID = nil
        contentRevision = 0
        isFirst = false
        isLast = false
    }
}

@MainActor
private final class MacConversationHostedCell: MacConversationReusableCell {
    private var hosting: NSHostingView<AnyView>?

    init() {
        super.init(kind: .hosted)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setContent(
        _ content: Content,
        scrollActivity: MacTranscriptScrollActivity,
        nativeLinkHandler: @escaping MacConversationNativeTextPresentation.LinkHandler,
        nativeCopyMessageHandler: @escaping @MainActor (String) -> Void
    ) {
        guard case let .hosted(rootView) = content else {
            assertionFailure("Hosted transcript cell received native content")
            return
        }
        if let hosting {
            hosting.rootView = rootView
            return
        }
        let hosting = NSHostingView(rootView: rootView)
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
        // `viewFor` immediately replaces this bounded host. Clearing it first
        // performs a second SwiftUI graph transition for every cold row that
        // enters the viewport and cancels useful preparation already in flight.
    }
}

@MainActor
private final class MacConversationNativeFooterCell: MacConversationReusableCell {
    private let layoutContainer = NSView(frame: .zero)
    private let controls = NSStackView(frame: .zero)
    private let copyButton = NSButton(frame: .zero)
    private let timestampLabel = NSTextField(labelWithString: "")
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var controlsLeadingConstraint: NSLayoutConstraint!
    private var controlsTrailingConstraint: NSLayoutConstraint!
    private var copiedResetTask: Task<Void, Never>?
    private var copyMessageHandler: (@MainActor (String) -> Void)?
    private var itemID: String?

    init() {
        super.init(kind: .nativeFooter)

        layoutContainer.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 9

        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.title = ""
        copyButton.isBordered = false
        copyButton.imagePosition = .imageOnly
        copyButton.contentTintColor = .secondaryLabelColor
        copyButton.target = self
        copyButton.action = #selector(copyMessage)

        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.lineBreakMode = .byClipping
        timestampLabel.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(layoutContainer)
        layoutContainer.addSubview(controls)
        controls.addArrangedSubview(copyButton)
        controls.addArrangedSubview(timestampLabel)

        topConstraint = layoutContainer.topAnchor.constraint(equalTo: topAnchor)
        bottomConstraint = layoutContainer.bottomAnchor.constraint(equalTo: bottomAnchor)
        controlsLeadingConstraint = controls.leadingAnchor.constraint(
            equalTo: layoutContainer.leadingAnchor
        )
        controlsTrailingConstraint = controls.trailingAnchor.constraint(
            equalTo: layoutContainer.trailingAnchor
        )
        let preferredWidth = layoutContainer.widthAnchor.constraint(
            equalToConstant: 760
        )
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            layoutContainer.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor,
                constant: 28
            ),
            layoutContainer.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor,
                constant: -28
            ),
            layoutContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            layoutContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            preferredWidth,
            topConstraint,
            bottomConstraint,
            controls.topAnchor.constraint(equalTo: layoutContainer.topAnchor),
            controls.bottomAnchor.constraint(equalTo: layoutContainer.bottomAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 44),
            copyButton.heightAnchor.constraint(equalToConstant: 44),
        ])
        setCopyState(copied: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setContent(
        _ content: Content,
        scrollActivity: MacTranscriptScrollActivity,
        nativeLinkHandler: @escaping MacConversationNativeTextPresentation.LinkHandler,
        nativeCopyMessageHandler: @escaping @MainActor (String) -> Void
    ) {
        guard case let .nativeFooter(presentation) = content else {
            assertionFailure("Native footer cell received non-footer content")
            return
        }

        if itemID != presentation.itemID {
            copiedResetTask?.cancel()
            copiedResetTask = nil
            itemID = presentation.itemID
            setCopyState(copied: false)
        }
        copyMessageHandler = nativeCopyMessageHandler

        topConstraint.constant = isFirst ? 22 : 7
        bottomConstraint.constant = -(isLast ? 16 : 7)
        if presentation.isTrailing {
            if controlsLeadingConstraint.isActive {
                controlsLeadingConstraint.isActive = false
            }
            if !controlsTrailingConstraint.isActive {
                controlsTrailingConstraint.isActive = true
            }
        } else {
            if controlsTrailingConstraint.isActive {
                controlsTrailingConstraint.isActive = false
            }
            if !controlsLeadingConstraint.isActive {
                controlsLeadingConstraint.isActive = true
            }
        }

        timestampLabel.font = NSFont.systemFont(
            ofSize: NSFont.smallSystemFontSize * max(0.5, presentation.fontScale)
        )
        timestampLabel.stringValue = presentation.timestampLabel ?? ""
        timestampLabel.isHidden = presentation.timestampLabel == nil
        timestampLabel.setAccessibilityLabel(
            presentation.timestampAccessibilityLabel
        )
        setAccessibilityIdentifier(presentation.accessibilityIdentifier)
        copyButton.setAccessibilityIdentifier(
            presentation.accessibilityIdentifier.map { "\($0).copy" }
        )
    }

    override func prepareForReuse() {
        copiedResetTask?.cancel()
        copiedResetTask = nil
        copyMessageHandler = nil
        itemID = nil
        timestampLabel.stringValue = ""
        timestampLabel.setAccessibilityLabel(nil)
        setAccessibilityIdentifier(nil)
        copyButton.setAccessibilityIdentifier(nil)
        setCopyState(copied: false)
        super.prepareForReuse()
    }

    @objc
    private func copyMessage() {
        guard let itemID, let copyMessageHandler else { return }
        copyMessageHandler(itemID)
        setCopyState(copied: true)
        let representedRowID = representedRowID
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.representedRowID == representedRowID else { return }
            self.setCopyState(copied: false)
        }
    }

    private func setCopyState(copied: Bool) {
        let label = copied ? "Message copied" : "Copy message"
        let symbol = copied ? "checkmark" : "doc.on.doc"
        copyButton.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        )
        copyButton.setAccessibilityLabel(label)
    }
}

/// The cell used for rows that enter the viewport during a live gesture. It
/// intentionally has no Auto Layout graph and no selectable AppKit text
/// control: NSTableView can realize it with one Core Text measurement and
/// direct frames. Visible rows are replaced by the selectable/rich native cell
/// immediately after scrolling ends.
@MainActor
private final class MacConversationScrollTextCell: MacConversationReusableCell {
    private struct Geometry {
        let containerFrame: NSRect
        let textFrame: NSRect
        let height: CGFloat
    }

    private let textContainerView = NSView(frame: .zero)
    private let scrollTextView = MacConversationScrollTextView(frame: .zero)
    private var presentation: MacConversationNativeTextPresentation?
    private var lastWidth: CGFloat = -1

    init() {
        super.init(kind: .nativeScroll)
        addSubview(textContainerView)
        textContainerView.addSubview(scrollTextView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func setContent(
        _ content: Content,
        scrollActivity: MacTranscriptScrollActivity,
        nativeLinkHandler: @escaping MacConversationNativeTextPresentation.LinkHandler,
        nativeCopyMessageHandler: @escaping @MainActor (String) -> Void
    ) {
        guard case let .native(presentation) = content else {
            assertionFailure("Scroll transcript cell received non-text content")
            return
        }
        self.presentation = presentation
        scrollTextView.attributedString = presentation.attributedString
            ?? Self.fallbackAttributedString(
                presentation.fallbackString,
                font: presentation.fallbackFont,
                color: presentation.fallbackColor,
                paragraphStyle: presentation.fallbackParagraphStyle
            )
        scrollTextView.setAccessibilityLabel(presentation.accessibilityLabel)
        scrollTextView.setAccessibilityIdentifier(
            presentation.accessibilityIdentifier
        )
        let usesDecoratedContainer = presentation.backgroundColor != nil
            || presentation.backgroundCornerRadius > 0
        textContainerView.wantsLayer = usesDecoratedContainer
        if usesDecoratedContainer {
            textContainerView.layer?.backgroundColor = (
                presentation.backgroundColor ?? .clear
            ).cgColor
            textContainerView.layer?.cornerRadius = presentation
                .backgroundCornerRadius
            textContainerView.layer?.maskedCorners = Self.layerCorners(
                presentation.roundedCorners
            )
            textContainerView.layer?.masksToBounds = presentation
                .backgroundCornerRadius > 0
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var fittingSize: NSSize {
        guard presentation != nil else {
            return NSSize(width: max(1, bounds.width), height: 44)
        }
        let width = bounds.width > 1 ? bounds.width : 800
        return NSSize(
            width: width,
            height: geometry(for: width).height
        )
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - lastWidth) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        lastWidth = newSize.width
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard bounds.width > 0, presentation != nil else { return }
        let geometry = geometry(for: bounds.width)
        textContainerView.frame = geometry.containerFrame
        scrollTextView.frame = geometry.textFrame
    }

    override func prepareForReuse() {
        presentation = nil
        scrollTextView.setAccessibilityLabel(nil)
        scrollTextView.setAccessibilityIdentifier(nil)
        textContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        textContainerView.layer?.cornerRadius = 0
        textContainerView.layer?.maskedCorners = []
        super.prepareForReuse()
    }

    private func geometry(for width: CGFloat) -> Geometry {
        guard let presentation else {
            return Geometry(
                containerFrame: .zero,
                textFrame: .zero,
                height: 44
            )
        }
        let top = presentation.contentInsets.top
            + (isFirst ? presentation.firstRowTopInsetAdjustment : 0)
        let bottom = presentation.contentInsets.bottom
            + (isLast ? presentation.lastRowBottomInsetAdjustment : 0)
        let availableContentWidth = max(
            1,
            width - presentation.contentInsets.left
                - presentation.contentInsets.right
        )
        let contentWidth = min(
            availableContentWidth,
            presentation.maximumContentWidth ?? availableContentWidth
        )
        let contentX = presentation.contentInsets.left
            + ((availableContentWidth - contentWidth) / 2)
        let maximumTextContainerWidth = min(
            contentWidth,
            presentation.maximumTextWidth
                ?? presentation.maximumContentWidth
                ?? contentWidth
        )
        let textContainerWidth = presentation.horizontalAlignment == .fill
            ? contentWidth
            : maximumTextContainerWidth
        let textContainerX: CGFloat
        switch presentation.horizontalAlignment {
        case .fill, .leading:
            textContainerX = contentX
        case .trailing:
            textContainerX = contentX + contentWidth - textContainerWidth
        case .center:
            textContainerX = contentX
                + ((contentWidth - textContainerWidth) / 2)
        }
        let horizontalTextInset = presentation.textContainerInset.width
        let verticalTextInset = presentation.textContainerInset.height
        let textWidth = max(
            1,
            textContainerWidth - presentation.textEdgeInsets.left
                - presentation.textEdgeInsets.right
                - (horizontalTextInset * 2)
        )
        let textHeight = scrollTextView.textHeight(for: textWidth)
        let measuredContainerHeight = presentation.textEdgeInsets.top
            + verticalTextInset
            + textHeight
            + verticalTextInset
            + presentation.textEdgeInsets.bottom
        let containerHeight = max(
            presentation.minimumTextContainerHeight,
            measuredContainerHeight
        )
        let verticalCentering = max(
            0,
            (containerHeight - measuredContainerHeight) / 2
        )
        return Geometry(
            containerFrame: NSRect(
                x: textContainerX,
                y: top,
                width: textContainerWidth,
                height: containerHeight
            ),
            textFrame: NSRect(
                x: presentation.textEdgeInsets.left + horizontalTextInset,
                y: presentation.textEdgeInsets.top
                    + verticalTextInset
                    + verticalCentering,
                width: textWidth,
                height: textHeight
            ),
            height: max(1, ceil(top + containerHeight + bottom))
        )
    }

    private static func layerCorners(
        _ corners: MacConversationNativeTextPresentation.RoundedCorners
    ) -> CACornerMask {
        var result: CACornerMask = []
        if corners.contains(.topLeading) {
            result.insert(.layerMinXMaxYCorner)
        }
        if corners.contains(.topTrailing) {
            result.insert(.layerMaxXMaxYCorner)
        }
        if corners.contains(.bottomLeading) {
            result.insert(.layerMinXMinYCorner)
        }
        if corners.contains(.bottomTrailing) {
            result.insert(.layerMaxXMinYCorner)
        }
        return result
    }

    private static func fallbackAttributedString(
        _ string: String,
        font: NSFont?,
        color: NSColor?,
        paragraphStyle: NSParagraphStyle?
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: color ?? NSColor.labelColor,
                .paragraphStyle: paragraphStyle ?? NSParagraphStyle.default,
            ]
        )
    }
}

@MainActor
private final class MacConversationNativeTextCell:
    MacConversationReusableCell,
    NSTextViewDelegate
{
    private let layoutContainer = NSView(frame: .zero)
    private let textContainerView = NSView(frame: .zero)
    private let nativeTextView = MacConversationIntrinsicTextView(frame: .zero)
    private let fastTextField = MacConversationWrappingTextField(frame: .zero)
    private var leadingLimitConstraint: NSLayoutConstraint!
    private var trailingLimitConstraint: NSLayoutConstraint!
    private var fillLeadingConstraint: NSLayoutConstraint!
    private var fillTrailingConstraint: NSLayoutConstraint!
    private var centerXConstraint: NSLayoutConstraint!
    private var maximumWidthConstraint: NSLayoutConstraint!
    private var preferredWidthConstraint: NSLayoutConstraint!
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!
    private var textFillLeadingConstraint: NSLayoutConstraint!
    private var textFillTrailingConstraint: NSLayoutConstraint!
    private var textAlignedLeadingConstraint: NSLayoutConstraint!
    private var textAlignedTrailingConstraint: NSLayoutConstraint!
    private var textCenterXConstraint: NSLayoutConstraint!
    private var maximumTextWidthConstraint: NSLayoutConstraint!
    private var textTopConstraint: NSLayoutConstraint!
    private var textBottomConstraint: NSLayoutConstraint!
    private var textContentLeadingConstraint: NSLayoutConstraint!
    private var textContentTrailingConstraint: NSLayoutConstraint!
    private var fastTextTopConstraint: NSLayoutConstraint!
    private var fastTextBottomConstraint: NSLayoutConstraint!
    private var fastTextLeadingConstraint: NSLayoutConstraint!
    private var fastTextTrailingConstraint: NSLayoutConstraint!
    private var linkHandler: MacConversationNativeTextPresentation.LinkHandler?
    private var deferredPreparationTask: Task<Void, Never>?
    private var presentationGeneration: UInt64 = 0

    init() {
        super.init(kind: .native)

        layoutContainer.translatesAutoresizingMaskIntoConstraints = false
        textContainerView.translatesAutoresizingMaskIntoConstraints = false
        nativeTextView.translatesAutoresizingMaskIntoConstraints = false
        fastTextField.translatesAutoresizingMaskIntoConstraints = false
        fastTextField.isHidden = true
        nativeTextView.delegate = self
        addSubview(layoutContainer)
        layoutContainer.addSubview(textContainerView)
        textContainerView.addSubview(nativeTextView)
        textContainerView.addSubview(fastTextField)

        leadingLimitConstraint = layoutContainer.leadingAnchor.constraint(
            greaterThanOrEqualTo: leadingAnchor
        )
        trailingLimitConstraint = layoutContainer.trailingAnchor.constraint(
            lessThanOrEqualTo: trailingAnchor
        )
        fillLeadingConstraint = layoutContainer.leadingAnchor.constraint(
            equalTo: leadingAnchor
        )
        fillTrailingConstraint = layoutContainer.trailingAnchor.constraint(
            equalTo: trailingAnchor
        )
        centerXConstraint = layoutContainer.centerXAnchor.constraint(
            equalTo: centerXAnchor
        )
        maximumWidthConstraint = layoutContainer.widthAnchor.constraint(
            lessThanOrEqualToConstant: 1
        )
        preferredWidthConstraint = layoutContainer.widthAnchor.constraint(
            equalToConstant: 1
        )
        preferredWidthConstraint.priority = .defaultHigh
        topConstraint = layoutContainer.topAnchor.constraint(equalTo: topAnchor)
        bottomConstraint = layoutContainer.bottomAnchor.constraint(equalTo: bottomAnchor)

        textFillLeadingConstraint = textContainerView.leadingAnchor.constraint(
            equalTo: layoutContainer.leadingAnchor
        )
        textFillTrailingConstraint = textContainerView.trailingAnchor.constraint(
            equalTo: layoutContainer.trailingAnchor
        )
        textAlignedLeadingConstraint = textContainerView.leadingAnchor.constraint(
            equalTo: layoutContainer.leadingAnchor
        )
        textAlignedTrailingConstraint = textContainerView.trailingAnchor.constraint(
            equalTo: layoutContainer.trailingAnchor
        )
        textCenterXConstraint = textContainerView.centerXAnchor.constraint(
            equalTo: layoutContainer.centerXAnchor
        )
        maximumTextWidthConstraint = textContainerView.widthAnchor.constraint(
            lessThanOrEqualToConstant: 1
        )
        textTopConstraint = nativeTextView.topAnchor.constraint(
            equalTo: textContainerView.topAnchor
        )
        textBottomConstraint = nativeTextView.bottomAnchor.constraint(
            equalTo: textContainerView.bottomAnchor
        )
        textContentLeadingConstraint = nativeTextView.leadingAnchor.constraint(
            equalTo: textContainerView.leadingAnchor
        )
        textContentTrailingConstraint = nativeTextView.trailingAnchor.constraint(
            equalTo: textContainerView.trailingAnchor
        )
        fastTextTopConstraint = fastTextField.topAnchor.constraint(
            equalTo: textContainerView.topAnchor
        )
        fastTextBottomConstraint = fastTextField.bottomAnchor.constraint(
            equalTo: textContainerView.bottomAnchor
        )
        fastTextLeadingConstraint = fastTextField.leadingAnchor.constraint(
            equalTo: textContainerView.leadingAnchor
        )
        fastTextTrailingConstraint = fastTextField.trailingAnchor.constraint(
            equalTo: textContainerView.trailingAnchor
        )
        NSLayoutConstraint.activate([
            leadingLimitConstraint,
            trailingLimitConstraint,
            fillLeadingConstraint,
            fillTrailingConstraint,
            topConstraint,
            bottomConstraint,
            textFillLeadingConstraint,
            textFillTrailingConstraint,
            textContainerView.topAnchor.constraint(
                equalTo: layoutContainer.topAnchor
            ),
            textContainerView.bottomAnchor.constraint(
                equalTo: layoutContainer.bottomAnchor
            ),
            textTopConstraint,
            textBottomConstraint,
            textContentLeadingConstraint,
            textContentTrailingConstraint,
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func setContent(
        _ content: Content,
        scrollActivity: MacTranscriptScrollActivity,
        nativeLinkHandler: @escaping MacConversationNativeTextPresentation.LinkHandler,
        nativeCopyMessageHandler: @escaping @MainActor (String) -> Void
    ) {
        guard case let .native(presentation) = content else {
            assertionFailure("Native transcript cell received hosted content")
            return
        }

        presentationGeneration &+= 1
        let generation = presentationGeneration
        deferredPreparationTask?.cancel()
        deferredPreparationTask = nil

        leadingLimitConstraint.constant = presentation.contentInsets.left
        trailingLimitConstraint.constant = -presentation.contentInsets.right
        fillLeadingConstraint.constant = presentation.contentInsets.left
        fillTrailingConstraint.constant = -presentation.contentInsets.right
        centerXConstraint.constant = (
            presentation.contentInsets.left - presentation.contentInsets.right
        ) / 2
        topConstraint.constant = presentation.contentInsets.top
            + (isFirst ? presentation.firstRowTopInsetAdjustment : 0)
        bottomConstraint.constant = -(presentation.contentInsets.bottom
            + (isLast ? presentation.lastRowBottomInsetAdjustment : 0))
        if let maximumContentWidth = presentation.maximumContentWidth {
            setActive(fillLeadingConstraint, false)
            setActive(fillTrailingConstraint, false)
            maximumWidthConstraint.constant = maximumContentWidth
            preferredWidthConstraint.constant = maximumContentWidth
            setActive(centerXConstraint, true)
            setActive(maximumWidthConstraint, true)
            setActive(preferredWidthConstraint, true)
        } else {
            setActive(centerXConstraint, false)
            setActive(maximumWidthConstraint, false)
            setActive(preferredWidthConstraint, false)
            setActive(fillLeadingConstraint, true)
            setActive(fillTrailingConstraint, true)
        }

        let fillsText = presentation.horizontalAlignment == .fill
        let alignsTextLeading = presentation.horizontalAlignment == .leading
        let alignsTextTrailing = presentation.horizontalAlignment == .trailing
        let centersText = presentation.horizontalAlignment == .center
        let limitsTextWidth = !fillsText
        let textConstraints: [(NSLayoutConstraint, Bool)] = [
            (textFillLeadingConstraint, fillsText),
            (textFillTrailingConstraint, fillsText),
            (textAlignedLeadingConstraint, alignsTextLeading),
            (textAlignedTrailingConstraint, alignsTextTrailing),
            (textCenterXConstraint, centersText),
            (maximumTextWidthConstraint, limitsTextWidth),
        ]
        // Deactivate conflicts before activating the desired alignment, but
        // keep an unchanged constraint installed across cell reuse. Tearing
        // down and rebuilding the same Auto Layout graph for every tile was a
        // measurable part of cold-row scroll callbacks.
        for (constraint, shouldBeActive) in textConstraints
        where !shouldBeActive {
            setActive(constraint, false)
        }
        if limitsTextWidth {
            maximumTextWidthConstraint.constant = presentation.maximumTextWidth
                ?? presentation.maximumContentWidth
                ?? 760
        }
        for (constraint, shouldBeActive) in textConstraints
        where shouldBeActive {
            setActive(constraint, true)
        }

        let usesFastRenderer = presentation.usesFastPlainTextRenderer
        if usesFastRenderer {
            precondition(
                presentation.horizontalAlignment == .fill
                    && presentation.maximumTextWidth == nil
                    && (presentation.promotesFastRendererWhenIdle
                        || (presentation.deferredAttributedString == nil
                            && presentation.linkHandler == nil)),
                "Fast transcript text is only for immutable, noninteractive tiles."
            )
        }
        precondition(
            !presentation.promotesFastRendererWhenIdle || usesFastRenderer,
            "Only the fast renderer can defer rich-text adoption."
        )
        setRendererMode(
            usesFastRenderer ? .selectableFast : .rich
        )
        textTopConstraint.constant = presentation.textEdgeInsets.top
        textBottomConstraint.constant = -presentation.textEdgeInsets.bottom
        textContentLeadingConstraint.constant = presentation.textEdgeInsets.left
        textContentTrailingConstraint.constant = -presentation.textEdgeInsets.right
        fastTextTopConstraint.constant = presentation.textEdgeInsets.top
        fastTextBottomConstraint.constant = -presentation.textEdgeInsets.bottom
        fastTextLeadingConstraint.constant = presentation.textEdgeInsets.left
        fastTextTrailingConstraint.constant = -presentation.textEdgeInsets.right
        if usesFastRenderer {
            linkHandler = nil
            nativeTextView.maximumIntrinsicWidth = nil
            let provisionalContainerWidth = presentation.maximumContentWidth
                ?? max(
                    1,
                    bounds.width - presentation.contentInsets.left
                        - presentation.contentInsets.right
                )
            fastTextField.provisionalIntrinsicWidth = max(
                1,
                provisionalContainerWidth - presentation.textEdgeInsets.left
                    - presentation.textEdgeInsets.right
            )
            nativeTextView.setAccessibilityLabel(nil)
            nativeTextView.setAccessibilityIdentifier(nil)
            fastTextField.setAccessibilityLabel(
                presentation.accessibilityLabel
            )
            fastTextField.setAccessibilityIdentifier(
                presentation.accessibilityIdentifier
            )
        } else {
            nativeTextView.textContainerInset = presentation.textContainerInset
            nativeTextView.maximumIntrinsicWidth = presentation.maximumTextWidth.map {
                max(
                    1,
                    $0 - presentation.textEdgeInsets.left
                        - presentation.textEdgeInsets.right
                )
            }
            linkHandler = presentation.linkHandler ?? nativeLinkHandler
            nativeTextView.setAccessibilityLabel(presentation.accessibilityLabel)
            nativeTextView.setAccessibilityIdentifier(
                presentation.accessibilityIdentifier
            )
            fastTextField.setAccessibilityLabel(nil)
            fastTextField.setAccessibilityIdentifier(nil)
        }

        let usesDecoratedContainer = presentation.backgroundColor != nil
            || presentation.backgroundCornerRadius > 0
        textContainerView.wantsLayer = usesDecoratedContainer
        if usesDecoratedContainer {
            textContainerView.layer?.backgroundColor = (
                presentation.backgroundColor ?? .clear
            ).cgColor
            textContainerView.layer?.cornerRadius = presentation.backgroundCornerRadius
            textContainerView.layer?.maskedCorners = Self.layerCorners(
                presentation.roundedCorners
            )
            textContainerView.layer?.masksToBounds = presentation.backgroundCornerRadius > 0
        }

        setAttributedString(
            presentation.attributedString ?? Self.fallbackAttributedString(
                presentation.fallbackString,
                font: presentation.fallbackFont,
                color: presentation.fallbackColor,
                paragraphStyle: presentation.fallbackParagraphStyle
            ),
            renderer: usesFastRenderer ? .selectableFast : .rich
        )

        if usesFastRenderer {
            guard presentation.promotesFastRendererWhenIdle else { return }
            guard !scrollActivity.isLiveScrollActive else { return }
            let representedRowID = representedRowID
            let immediate = presentation.attributedString
            let deferred = presentation.deferredAttributedString
            deferredPreparationTask = Task { @MainActor [weak self] in
                let deferredArtifact: MacConversationNativeTextPresentation.DeferredArtifact?
                if let deferred {
                    deferredArtifact = await deferred()
                } else {
                    deferredArtifact = nil
                }
                guard !Task.isCancelled,
                      immediate != nil || deferredArtifact != nil else { return }
                await scrollActivity.adoptHeightChangingContentWhenIdle { [weak self] in
                    guard let self,
                          self.presentationGeneration == generation,
                          self.representedRowID == representedRowID else { return }
                    let resolved = deferredArtifact?.resolve() ?? immediate
                    guard let resolved else { return }
                    self.adoptRichText(
                        resolved,
                        presentation: presentation,
                        nativeLinkHandler: nativeLinkHandler
                    )
                }
            }
            return
        }

        guard let deferredAttributedString = presentation.deferredAttributedString else {
            return
        }
        let representedRowID = representedRowID
        deferredPreparationTask = Task { @MainActor [weak self] in
            guard let deferredArtifact = await deferredAttributedString(),
                  !Task.isCancelled else { return }
            await scrollActivity.adoptHeightChangingContentWhenIdle { [weak self] in
                guard let self,
                      self.presentationGeneration == generation,
                      self.representedRowID == representedRowID else { return }
                guard let prepared = deferredArtifact.resolve() else { return }
                self.setAttributedString(prepared, renderer: .rich)
            }
        }
    }

    private func adoptRichText(
        _ attributedString: NSAttributedString,
        presentation: MacConversationNativeTextPresentation,
        nativeLinkHandler: @escaping MacConversationNativeTextPresentation.LinkHandler
    ) {
        setRendererMode(.rich)
        nativeTextView.textContainerInset = presentation.textContainerInset
        nativeTextView.maximumIntrinsicWidth = presentation.maximumTextWidth.map {
            max(
                1,
                $0 - presentation.textEdgeInsets.left
                    - presentation.textEdgeInsets.right
            )
        }
        linkHandler = presentation.linkHandler ?? nativeLinkHandler
        nativeTextView.setAccessibilityLabel(presentation.accessibilityLabel)
        nativeTextView.setAccessibilityIdentifier(
            presentation.accessibilityIdentifier
        )
        fastTextField.setAccessibilityLabel(nil)
        fastTextField.setAccessibilityIdentifier(nil)
        setAttributedString(attributedString, renderer: .rich)
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        let url: URL?
        if let link = link as? URL {
            url = link
        } else if let link = link as? String {
            url = URL(string: link)
        } else {
            url = nil
        }
        // Native transcript links never fall through to AppKit's implicit URL
        // opener; callers explicitly apply the same repository/external-link
        // policy used by hosted rows.
        guard let url, let linkHandler else { return true }
        return linkHandler(url)
    }

    override func prepareForReuse() {
        presentationGeneration &+= 1
        deferredPreparationTask?.cancel()
        deferredPreparationTask = nil
        linkHandler = nil
        nativeTextView.setAccessibilityLabel(nil)
        nativeTextView.setAccessibilityIdentifier(nil)
        fastTextField.setAccessibilityLabel(nil)
        fastTextField.setAccessibilityIdentifier(nil)
        // `viewFor` immediately replaces this bounded storage. Clearing first
        // invalidates TextKit twice for every cold tile and never presents an
        // observable empty state.
        nativeTextView.maximumIntrinsicWidth = nil
        fastTextField.provisionalIntrinsicWidth = nil
        textContainerView.layer?.backgroundColor = NSColor.clear.cgColor
        textContainerView.layer?.cornerRadius = 0
        textContainerView.layer?.maskedCorners = []
        super.prepareForReuse()
    }

    private func setAttributedString(
        _ attributedString: NSAttributedString,
        renderer: Renderer
    ) {
        switch renderer {
        case .selectableFast:
            fastTextField.attributedStringValue = attributedString
            fastTextField.invalidateIntrinsicContentSize()
        case .rich:
            nativeTextView.textStorage?.setAttributedString(attributedString)
            nativeTextView.invalidateIntrinsicContentSize()
        }
        invalidateIntrinsicContentSize()
    }

    private enum Renderer: Equatable {
        case rich
        case selectableFast
    }

    private func setRendererMode(_ renderer: Renderer) {
        let nativeConstraints = [
            textTopConstraint,
            textBottomConstraint,
            textContentLeadingConstraint,
            textContentTrailingConstraint,
        ].compactMap { $0 }
        let fastConstraints = [
            fastTextTopConstraint,
            fastTextBottomConstraint,
            fastTextLeadingConstraint,
            fastTextTrailingConstraint,
        ].compactMap { $0 }
        let constraintsByRenderer: [(Renderer, [NSLayoutConstraint])] = [
            (.rich, nativeConstraints),
            (.selectableFast, fastConstraints),
        ]
        for (candidate, constraints) in constraintsByRenderer
        where candidate != renderer {
            for constraint in constraints { setActive(constraint, false) }
        }
        let selectedConstraints = constraintsByRenderer.first {
            $0.0 == renderer
        }?.1 ?? []
        for constraint in selectedConstraints { setActive(constraint, true) }
        nativeTextView.isHidden = renderer != .rich
        fastTextField.isHidden = renderer != .selectableFast
        invalidateIntrinsicContentSize()
    }

    private func setActive(
        _ constraint: NSLayoutConstraint,
        _ active: Bool
    ) {
        guard constraint.isActive != active else { return }
        constraint.isActive = active
    }

    private static func layerCorners(
        _ corners: MacConversationNativeTextPresentation.RoundedCorners
    ) -> CACornerMask {
        var result: CACornerMask = []
        if corners.contains(.topLeading) {
            result.insert(.layerMinXMaxYCorner)
        }
        if corners.contains(.topTrailing) {
            result.insert(.layerMaxXMaxYCorner)
        }
        if corners.contains(.bottomLeading) {
            result.insert(.layerMinXMinYCorner)
        }
        if corners.contains(.bottomTrailing) {
            result.insert(.layerMaxXMinYCorner)
        }
        return result
    }

    private static func fallbackAttributedString(
        _ string: String,
        font: NSFont?,
        color: NSColor?,
        paragraphStyle: NSParagraphStyle?
    ) -> NSAttributedString {
        NSAttributedString(
            string: string,
            attributes: [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: color ?? NSColor.labelColor,
                .paragraphStyle: paragraphStyle ?? NSParagraphStyle.default,
            ]
        )
    }
}

@MainActor
private final class MacConversationWrappingTextField: NSTextField {
    private var lastMeasuredWidth: CGFloat = -1
    var provisionalIntrinsicWidth: CGFloat? {
        didSet {
            if oldValue != provisionalIntrinsicWidth {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = true
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = false
        maximumNumberOfLines = 0
        lineBreakMode = .byCharWrapping
        cell?.wraps = true
        cell?.isScrollable = false
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let measurementWidth = bounds.width > 1
            ? bounds.width
            : (provisionalIntrinsicWidth ?? 0)
        guard measurementWidth > 1 else {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: NSView.noIntrinsicMetric
            )
        }
        let measured = attributedStringValue.boundingRect(
            with: NSSize(
                width: measurementWidth,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: max(1, ceil(measured.height))
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - lastMeasuredWidth) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        lastMeasuredWidth = newSize.width
        invalidateIntrinsicContentSize()
    }
}

/// A scroll-only Core Text surface. It keeps exact text visible while the
/// gesture owns the viewport, but avoids NSTextFieldCell/TextKit fitting and
/// selection machinery in the synchronous NSTableView realization callback.
/// The visible rows return to selectable controls as soon as scrolling ends.
@MainActor
final class MacConversationScrollTextView: NSView {
    private var framesetter: CTFramesetter?
    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0
    var provisionalIntrinsicWidth: CGFloat? {
        didSet {
            guard oldValue != provisionalIntrinsicWidth else { return }
            resetMeasurement()
        }
    }
    var attributedString = NSAttributedString() {
        didSet {
            framesetter = CTFramesetterCreateWithAttributedString(
                attributedString as CFAttributedString
            )
            setAccessibilityValue(attributedString.string)
            resetMeasurement()
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width > 1
            ? bounds.width
            : (provisionalIntrinsicWidth ?? 0)
        guard width > 1 else {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: NSView.noIntrinsicMetric
            )
        }
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: textHeight(for: width)
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - bounds.width) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        resetMeasurement()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let framesetter,
              let context = NSGraphicsContext.current?.cgContext,
              bounds.width > 0,
              bounds.height > 0 else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(
            rect: CGRect(origin: .zero, size: bounds.size),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    func textHeight(for width: CGFloat) -> CGFloat {
        guard let framesetter else { return 1 }
        if abs(width - measuredWidth) <= 0.5 {
            return measuredHeight
        }
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            ),
            nil
        )
        measuredWidth = width
        measuredHeight = max(1, ceil(suggested.height))
        return measuredHeight
    }

    private func resetMeasurement() {
        measuredWidth = -1
        measuredHeight = 0
        invalidateIntrinsicContentSize()
    }
}

@MainActor
private final class MacConversationIntrinsicTextView: NSTextView {
    private let ownedTextStorage: NSTextStorage
    private let ownedLayoutManager: NSLayoutManager
    private let ownedTextContainer: NSTextContainer
    private var lastMeasuredWidth: CGFloat = -1
    var maximumIntrinsicWidth: CGFloat? {
        didSet {
            if oldValue != maximumIntrinsicWidth {
                invalidateIntrinsicContentSize()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        let textStorage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(
            containerSize: NSSize(
                width: max(1, frameRect.width),
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        ownedTextStorage = textStorage
        ownedLayoutManager = layoutManager
        ownedTextContainer = textContainer
        super.init(frame: frameRect, textContainer: textContainer)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard let textContainer, let layoutManager else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        if let maximumIntrinsicWidth {
            let layoutWidth = max(
                1,
                maximumIntrinsicWidth - (textContainerInset.width * 2)
            )
            if abs(textContainer.containerSize.width - layoutWidth) > 0.5 {
                textContainer.containerSize = NSSize(
                    width: layoutWidth,
                    height: CGFloat.greatestFiniteMagnitude
                )
            }
            layoutManager.ensureLayout(for: textContainer)
            let used = layoutManager.usedRect(for: textContainer)
            return NSSize(
                width: min(
                    maximumIntrinsicWidth,
                    ceil(used.width + (textContainerInset.width * 2))
                ),
                height: ceil(used.height + (textContainerInset.height * 2))
            )
        }
        // Auto Layout can ask before horizontal constraints have assigned the
        // cell its real viewport/max-content width. Laying TextKit out at the
        // provisional zero width (clamped to one point) makes a short tile look
        // thousands of lines tall and stalls cold mounting. The width change
        // below invalidates this value once the constrained frame is known.
        guard bounds.width > (textContainerInset.width * 2) + 1 else {
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: NSView.noIntrinsicMetric
            )
        }
        let layoutWidth = max(
            1,
            bounds.width - (textContainerInset.width * 2)
        )
        if abs(textContainer.containerSize.width - layoutWidth) > 0.5 {
            textContainer.containerSize = NSSize(
                width: layoutWidth,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        layoutManager.ensureLayout(for: textContainer)
        let textHeight = layoutManager.usedRect(for: textContainer).height
        return NSSize(
            width: NSView.noIntrinsicMetric,
            height: ceil(textHeight + (textContainerInset.height * 2))
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - lastMeasuredWidth) > 0.5
        super.setFrameSize(newSize)
        guard widthChanged else { return }
        lastMeasuredWidth = newSize.width
        invalidateIntrinsicContentSize()
    }

    private func configure() {
        isEditable = false
        isSelectable = true
        isRichText = true
        importsGraphics = false
        allowsUndo = false
        drawsBackground = false
        isHorizontallyResizable = false
        isVerticallyResizable = true
        minSize = .zero
        maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textContainer?.widthTracksTextView = true
        textContainer?.heightTracksTextView = false
        textContainer?.lineFragmentPadding = 0
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)
    }
}
