import AppKit

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
