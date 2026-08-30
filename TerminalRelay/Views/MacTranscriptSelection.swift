import AppKit

/// Receives raw transcript mouse events from `MacTranscriptTableView` and
/// the standard editing actions. Implemented by the table coordinator, which
/// owns the selection controller and the cells.
@MainActor
protocol MacTranscriptTableSelectionDelegate: AnyObject {
    func selectionMouseDown(_ event: NSEvent)
    func selectionMouseDragged(_ event: NSEvent)
    func selectionMouseUp(_ event: NSEvent)
    func selectionCopy()
    func selectionSelectAll()
    /// Esc pressed while the table is first responder. Returns true when the
    /// press was consumed (a selection was cleared); false lets the event
    /// take the normal responder path.
    func selectionCancel() -> Bool
    /// Context menu for a right-click at the given window point: "Copy" over
    /// an active selection, "Copy Message" over a message row otherwise.
    func selectionContextMenu(atWindowPoint point: NSPoint) -> NSMenu?
    /// Pointer feedback: I-beam over text, pointing hand over links, nil for
    /// the arrow default.
    func selectionCursor(atWindowPoint point: NSPoint) -> NSCursor?
    /// A key or event that can scroll the transcript passed through a user
    /// input funnel (used to distinguish user moves from machine drift).
    func selectionMarkUserScrollInput()
    var selectionIsActive: Bool { get }
}

/// The transcript's table view. Text rows and row backgrounds are hit-test
/// transparent down to this view (their cells return nil), so the WINDOW's
/// mouse-down view for every selection drag is the table itself — a view
/// that streaming's remove+insert churn can never destroy mid-drag. Hosted
/// rows (SwiftUI controls) and footer cells keep normal hit-testing and
/// never reach these overrides.
final class MacTranscriptTableView: NSTableView {
    weak var selectionDelegate: MacTranscriptTableSelectionDelegate?

    /// Keeps the scrollable document extent immutable while a live gesture
    /// owns the viewport. Automatic row-height measurements may continue to
    /// settle internally, but they are published only after the coordinator
    /// releases this clamp and restores the user's row anchor at idle.
    private var frozenDocumentHeight: CGFloat?

    func setLiveScrollFrozenDocumentHeight(_ height: CGFloat?) {
        frozenDocumentHeight = height.map { max(1, $0) }
        guard let frozenDocumentHeight,
              abs(frame.height - frozenDocumentHeight) > 0.5 else { return }
        super.setFrameSize(NSSize(
            width: frame.width,
            height: frozenDocumentHeight
        ))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(NSSize(
            width: newSize.width,
            height: frozenDocumentHeight ?? newSize.height
        ))
    }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Deliberately no super: NSTableView's row-selection tracking loop
        // would swallow the drag events the selection state machine needs.
        selectionDelegate?.selectionMouseDown(event)
    }

    override func mouseDragged(with event: NSEvent) {
        selectionDelegate?.selectionMouseDragged(event)
    }

    override func mouseUp(with event: NSEvent) {
        selectionDelegate?.selectionMouseUp(event)
    }

    @objc func copy(_ sender: Any?) {
        selectionDelegate?.selectionCopy()
    }

    override func selectAll(_ sender: Any?) {
        selectionDelegate?.selectionSelectAll()
    }

    override func keyDown(with event: NSEvent) {
        // Keys reach the table only while a selection holds first responder;
        // any of them may scroll (page/arrow/home/end), which is user intent.
        selectionDelegate?.selectionMarkUserScrollInput()
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if selectionDelegate?.selectionCancel() == true { return }
        nextResponder?.tryToPerform(
            #selector(cancelOperation(_:)),
            with: sender
        )
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        selectionDelegate?.selectionContextMenu(
            atWindowPoint: event.locationInWindow
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        guard let cursor = selectionDelegate?.selectionCursor(
            atWindowPoint: event.locationInWindow
        ) else {
            super.cursorUpdate(with: event)
            return
        }
        cursor.set()
    }

    override func validateUserInterfaceItem(
        _ item: any NSValidatedUserInterfaceItem
    ) -> Bool {
        if item.action == #selector(copy(_:)) {
            return selectionDelegate?.selectionIsActive == true
        }
        if item.action == #selector(selectAll(_:)) {
            return numberOfRows > 0
        }
        return super.validateUserInterfaceItem(item)
    }
}

/// Row container that never claims hits for itself: clicks on text surfaces
/// and row padding fall through to the table (the drag owner), while real
/// subview controls (hosted SwiftUI rows, footer buttons) still receive
/// theirs.
final class MacTranscriptRowView: NSTableRowView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// TextKit layout mirror for a fast plain tile (`NSTextField` has no
/// hit-test or highlight-geometry API). Line breaks match NSStringDrawing
/// exactly; per-line heights do not (16.0 vs 17.0 for SF 13), so all
/// conversions scale y by the ratio of total heights — exact because fast
/// tiles are single-font and every line shares one height (pinned by the
/// task 1.1 spike).
@MainActor
final class MacTranscriptFastTextLayout {
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let container: NSTextContainer
    let width: CGFloat
    let sourceString: NSAttributedString

    init(attributedString: NSAttributedString, width: CGFloat) {
        sourceString = attributedString
        self.width = width
        storage = NSTextStorage(attributedString: attributedString)
        layoutManager = NSLayoutManager()
        container = NSTextContainer(
            containerSize: NSSize(
                width: max(1, width),
                height: CGFloat.greatestFiniteMagnitude
            )
        )
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
    }

    private var usedHeight: CGFloat {
        layoutManager.usedRect(for: container).height
    }

    private func scale(forFieldHeight fieldHeight: CGFloat) -> CGFloat {
        guard fieldHeight > 0, usedHeight > 0 else { return 1 }
        return usedHeight / fieldHeight
    }

    /// Nearest insertion index (UTF-16, composed-boundary aligned) for a
    /// point in the FIELD's coordinate space.
    func insertionIndex(
        atFieldPoint point: NSPoint,
        fieldHeight: CGFloat
    ) -> Int {
        let mapped = NSPoint(
            x: point.x,
            y: point.y * scale(forFieldHeight: fieldHeight)
        )
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(
            for: mapped,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        let text = storage.string as NSString
        guard index < text.length else { return text.length }
        let sequence = text.rangeOfComposedCharacterSequence(at: index)
        return fraction >= 0.5 ? NSMaxRange(sequence) : sequence.location
    }

    /// Highlight rectangles for a UTF-16 range, in FIELD coordinates.
    func highlightRects(
        forRange range: NSRange,
        fieldHeight: CGFloat
    ) -> [NSRect] {
        let text = storage.string as NSString
        let clamped = NSIntersectionRange(
            range,
            NSRange(location: 0, length: text.length)
        )
        guard clamped.length > 0 else { return [] }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: clamped,
            actualCharacterRange: nil
        )
        var rects: [NSRect] = []
        layoutManager.enumerateEnclosingRects(
            forGlyphRange: glyphRange,
            withinSelectedGlyphRange: NSRange(
                location: NSNotFound,
                length: 0
            ),
            in: container
        ) { rect, _ in
            rects.append(rect)
        }
        let scale = scale(forFieldHeight: fieldHeight)
        guard scale > 0 else { return rects }
        return rects.map { rect in
            NSRect(
                x: rect.minX,
                y: rect.minY / scale,
                width: rect.width,
                height: rect.height / scale
            )
        }
    }
}

/// One end of a cross-transcript selection. Endpoints live in model space
/// (row ID + UTF-16 offset) and additionally snapshot the displayed string
/// they were hit-tested against: a promoted rich tile displays a different
/// string than its model source, and the copied slice must contain the
/// characters the user visibly selected at the endpoints.
struct MacTranscriptSelectionEndpoint: Equatable {
    var rowID: String
    /// UTF-16 offset into `displayedText`.
    var offset: Int
    /// The string the endpoint was resolved against at hit-test time.
    var displayedText: String
    /// Row-granular endpoints (hosted rows without character access) cover
    /// their whole row.
    var isRowGranular: Bool
}

/// Highlight contribution of one row to the current selection, in the space
/// of the string the owning endpoint was resolved against (cells clamp to
/// their currently displayed string when painting).
enum MacTranscriptRowHighlight: Equatable {
    case none
    case full
    case range(NSRange)
}

/// Cross-transcript selection state, keyed entirely to the row MODEL: table
/// row churn (remove+insert of the same row IDs during streaming seals and
/// gesture restorations) is invisible here, because validity is re-derived
/// from row snapshots, never from table callbacks. The controller owns no
/// views; the table subclass feeds it hit-tested endpoints and row snapshots
/// and asks it for per-row highlights and pasteboard text.
@MainActor
final class MacTranscriptSelectionController<Row: MacConversationTableRow> {
    private(set) var anchor: MacTranscriptSelectionEndpoint?
    private(set) var focus: MacTranscriptSelectionEndpoint?
    private(set) var rows: [Row] = []
    private var rowIndexByID: [String: Int] = [:]

    var hasSelection: Bool {
        guard let ordered = orderedEndpoints else { return false }
        return ordered.start != ordered.end
            || ordered.start.isRowGranular
            || ordered.startIndex != ordered.endIndex
    }

    func begin(at endpoint: MacTranscriptSelectionEndpoint) {
        anchor = endpoint
        focus = endpoint
    }

    func extend(to endpoint: MacTranscriptSelectionEndpoint) {
        guard anchor != nil else { return }
        focus = endpoint
    }

    func clear() {
        anchor = nil
        focus = nil
    }

    /// Selects every contributing row of the current snapshot (the retained
    /// transcript window; paged-out server history is out of scope).
    func selectAll() {
        guard let first = rows.first, let last = rows.last else {
            clear()
            return
        }
        anchor = MacTranscriptSelectionEndpoint(
            rowID: first.id,
            offset: 0,
            displayedText: first.selectionText ?? "",
            isRowGranular: true
        )
        let lastText = last.selectionText ?? ""
        focus = MacTranscriptSelectionEndpoint(
            rowID: last.id,
            offset: (lastText as NSString).length,
            displayedText: lastText,
            isRowGranular: true
        )
    }

    /// Anchor/focus ordered by flat row position, then offset.
    var orderedEndpoints: (
        start: MacTranscriptSelectionEndpoint,
        end: MacTranscriptSelectionEndpoint,
        startIndex: Int,
        endIndex: Int
    )? {
        guard let anchor, let focus,
              let anchorIndex = rowIndexByID[anchor.rowID],
              let focusIndex = rowIndexByID[focus.rowID] else {
            return nil
        }
        if anchorIndex < focusIndex
            || (anchorIndex == focusIndex && anchor.offset <= focus.offset) {
            return (anchor, focus, anchorIndex, focusIndex)
        }
        return (focus, anchor, focusIndex, anchorIndex)
    }

    var coveredRows: [Row] {
        guard let ordered = orderedEndpoints else { return [] }
        return Array(rows[ordered.startIndex...ordered.endIndex])
    }

    func copyText() -> String {
        guard let ordered = orderedEndpoints else { return "" }
        return MacTranscriptSelectionSlicer.copyText(
            rows: coveredRows,
            start: ordered.start,
            end: ordered.end
        )
    }

    /// True while the row holds an endpoint — such rows must defer their
    /// fast-to-rich promotion, which would swap the string the endpoint's
    /// offsets refer to mid-selection.
    func hasEndpoint(inRowWithID id: String) -> Bool {
        anchor?.rowID == id || focus?.rowID == id
    }

    func highlight(forRowID id: String) -> MacTranscriptRowHighlight {
        guard let ordered = orderedEndpoints,
              let index = rowIndexByID[id],
              (ordered.startIndex...ordered.endIndex).contains(index) else {
            return .none
        }
        let isStartRow = index == ordered.startIndex
            && !ordered.start.isRowGranular
        let isEndRow = index == ordered.endIndex && !ordered.end.isRowGranular
        guard isStartRow || isEndRow else { return .full }
        let snapshot = isStartRow
            ? ordered.start.displayedText
            : ordered.end.displayedText
        let length = (snapshot as NSString).length
        let lower = isStartRow ? min(ordered.start.offset, length) : 0
        let upper = isEndRow ? min(ordered.end.offset, length) : length
        guard upper > lower else { return .none }
        return .range(NSRange(location: lower, length: upper - lower))
    }

    /// Adopts a new row snapshot, remapping or releasing endpoints per the
    /// verified mutation rules: an authoritative reset clears; an endpoint
    /// whose row survives (same ID, offset still inside its text) is
    /// untouched; an endpoint whose row shrank or vanished remaps through
    /// its content section by absolute source offset (tail re-segmentation
    /// moves text across rows without losing the user's position); a start
    /// endpoint whose section is gone re-anchors to the first surviving row
    /// (retention head-eviction must not drop a held Cmd-A); an end endpoint
    /// whose section is gone clears the selection.
    func updateRows(_ newRows: [Row], isAuthoritativeReset: Bool = false) {
        let previousRows = rows
        let previousIndex = rowIndexByID
        rows = newRows
        rowIndexByID = Dictionary(
            newRows.enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        guard anchor != nil || focus != nil else { return }
        if isAuthoritativeReset {
            clear()
            return
        }
        let remappedAnchor = remap(
            anchor,
            previousRows: previousRows,
            previousIndex: previousIndex
        )
        let remappedFocus = remap(
            focus,
            previousRows: previousRows,
            previousIndex: previousIndex
        )
        switch (remappedAnchor, remappedFocus) {
        case (.some(let newAnchor), .some(let newFocus)):
            anchor = newAnchor
            focus = newFocus
        case (.none, .some(let survivor)), (.some(let survivor), .none):
            // One endpoint's section left the model entirely. A loss at the
            // HEAD is retention eviction — keep the selection by re-anchoring
            // to the first surviving row (a held Cmd-A must survive an
            // active turn). A loss at the tail end means the selected
            // content no longer exists — release.
            let lost = remappedAnchor == nil ? anchor : focus
            let lostWasEarlier: Bool = {
                guard let lost,
                      let lostPosition = previousIndex[lost.rowID] else {
                    return true
                }
                let survivorPosition = previousIndex[survivor.rowID]
                    ?? Int.max
                return lostPosition <= survivorPosition
            }()
            guard lostWasEarlier, let first = rows.first else {
                clear()
                return
            }
            anchor = MacTranscriptSelectionEndpoint(
                rowID: first.id,
                offset: 0,
                displayedText: first.selectionText ?? "",
                isRowGranular: true
            )
            focus = survivor
        case (.none, .none):
            clear()
        }
    }

    private func remap(
        _ endpoint: MacTranscriptSelectionEndpoint?,
        previousRows: [Row],
        previousIndex: [String: Int]
    ) -> MacTranscriptSelectionEndpoint? {
        guard let endpoint else { return nil }
        if let index = rowIndexByID[endpoint.rowID] {
            let currentLength = (
                (rows[index].selectionText ?? "") as NSString
            ).length
            if endpoint.isRowGranular || endpoint.offset <= currentLength {
                return endpoint
            }
            // The row survives but its text shrank below the endpoint:
            // re-segmentation moved the selected position into a successor
            // row. Fall through to the section remap.
        }
        guard let oldPosition = previousIndex[endpoint.rowID] else {
            return nil
        }
        let sectionID = previousRows[oldPosition].selectionSectionID
            ?? previousRows[oldPosition].id
        var absolute = endpoint.offset
        var walker = oldPosition - 1
        while walker >= 0,
              (previousRows[walker].selectionSectionID
                ?? previousRows[walker].id) == sectionID {
            absolute += (
                (previousRows[walker].selectionText ?? "") as NSString
            ).length
            walker -= 1
        }
        return endpointAt(
            absoluteOffset: absolute,
            sectionID: sectionID,
            isRowGranular: endpoint.isRowGranular
        )
    }

    private func endpointAt(
        absoluteOffset: Int,
        sectionID: String,
        isRowGranular: Bool
    ) -> MacTranscriptSelectionEndpoint? {
        var remaining = absoluteOffset
        var lastSectionRow: (row: Row, length: Int)?
        for row in rows
        where (row.selectionSectionID ?? row.id) == sectionID {
            let text = row.selectionText ?? ""
            let length = (text as NSString).length
            if remaining <= length {
                return MacTranscriptSelectionEndpoint(
                    rowID: row.id,
                    offset: clampToComposedBoundary(text, offset: remaining),
                    displayedText: text,
                    isRowGranular: isRowGranular
                )
            }
            remaining -= length
            lastSectionRow = (row, length)
        }
        guard let lastSectionRow else { return nil }
        let text = lastSectionRow.row.selectionText ?? ""
        return MacTranscriptSelectionEndpoint(
            rowID: lastSectionRow.row.id,
            offset: lastSectionRow.length,
            displayedText: text,
            isRowGranular: isRowGranular
        )
    }

    /// Rounds a UTF-16 offset down to the nearest composed character
    /// boundary, so a remap can never park an endpoint inside a surrogate
    /// pair or emoji sequence.
    private func clampToComposedBoundary(_ text: String, offset: Int) -> Int {
        let source = text as NSString
        guard offset > 0, offset < source.length else {
            return max(0, min(offset, source.length))
        }
        let sequence = source.rangeOfComposedCharacterSequence(at: offset)
        return sequence.location == offset ? offset : sequence.location
    }
}

/// Builds pasteboard text for an ordered run of selected rows. Interior rows
/// contribute their model `selectionText` whole; endpoint rows substring
/// their displayed-string snapshot. Assembly rules: tiles of one content
/// section rejoin without separators (they recompose the source
/// byte-for-byte), sections of one item join with one newline, items join
/// with a blank line, and message items are prefixed with their role label
/// when the slice spans more than one item.
enum MacTranscriptSelectionSlicer {
    private struct Contribution {
        let itemID: String
        let sectionID: String
        let roleLabel: String?
        let text: String
    }

    static func copyText<Row: MacConversationTableRow>(
        rows: [Row],
        start: MacTranscriptSelectionEndpoint?,
        end: MacTranscriptSelectionEndpoint?
    ) -> String {
        var contributions: [Contribution] = []
        for row in rows {
            let text: String?
            let isStartRow = start.map { $0.rowID == row.id && !$0.isRowGranular } ?? false
            let isEndRow = end.map { $0.rowID == row.id && !$0.isRowGranular } ?? false
            if isStartRow || isEndRow {
                let snapshot = (isStartRow ? start?.displayedText : end?.displayedText) ?? ""
                let lower = isStartRow ? (start?.offset ?? 0) : 0
                let upper = isEndRow
                    ? (end?.offset ?? (snapshot as NSString).length)
                    : (snapshot as NSString).length
                text = utf16Substring(snapshot, from: lower, to: upper)
            } else {
                text = row.selectionText
            }
            guard let text else { continue }
            contributions.append(Contribution(
                itemID: row.mutationSourceID,
                sectionID: row.selectionSectionID ?? row.id,
                roleLabel: row.selectionRoleLabel,
                text: text
            ))
        }

        let spansMultipleItems = Set(contributions.map(\.itemID)).count > 1
        var result = ""
        var previous: Contribution?
        for contribution in contributions {
            let isNewItem = previous?.itemID != contribution.itemID
            if let previous {
                if previous.itemID != contribution.itemID {
                    result += "\n\n"
                } else if previous.sectionID != contribution.sectionID {
                    result += "\n"
                }
            }
            if spansMultipleItems, isNewItem,
               let label = contribution.roleLabel {
                result += label + "\n"
            }
            result += contribution.text
            previous = contribution
        }
        return result
    }

    /// UTF-16 substring with bounds clamping and composed-character-sequence
    /// expansion, so an offset that lands mid-grapheme (a tile cut through a
    /// scalar boundary, or a clamped remap) can never tear a surrogate pair
    /// or emoji sequence in the copied text.
    static func utf16Substring(_ text: String, from: Int, to: Int) -> String {
        let source = text as NSString
        let lower = max(0, min(from, source.length))
        let upper = max(lower, min(to, source.length))
        guard upper > lower else { return "" }
        let safeRange = source.rangeOfComposedCharacterSequences(
            for: NSRange(location: lower, length: upper - lower)
        )
        return source.substring(with: safeRange)
    }
}
