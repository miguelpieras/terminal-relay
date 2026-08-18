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
