import Foundation

struct TranscriptMarkdownContinuation: Equatable, Sendable {
    var openFence: String?
    var startsAtLineBoundary: Bool
    var pendingFenceLine: TranscriptMarkdownFenceLineState

    init(
        openFence: String?,
        startsAtLineBoundary: Bool,
        pendingFenceLine: TranscriptMarkdownFenceLineState? = nil
    ) {
        self.openFence = openFence
        self.startsAtLineBoundary = startsAtLineBoundary
        self.pendingFenceLine = pendingFenceLine
            ?? (startsAtLineBoundary ? .indent(0) : .ordinary)
    }

    static let initial = TranscriptMarkdownContinuation(
        openFence: nil,
        startsAtLineBoundary: true
    )
}

/// Bounded summary of a physical Markdown line split across projection rows.
/// It retains only fence-relevant state, never the line itself, so an
/// arbitrarily long info string or whitespace-only closer cannot make
/// projection memory depend on that line's length.
enum TranscriptMarkdownFenceLineState: Equatable, Sendable {
    case indent(Int)
    case opening(
        delimiter: UInt8,
        runLength: Int,
        inRun: Bool,
        infoValid: Bool
    )
    case closing(
        runLength: Int,
        inRun: Bool,
        trailingWhitespaceOnly: Bool
    )
    case ordinary
}

struct TranscriptTextSegment: Equatable, Sendable {
    let index: Int
    /// Exact retained source represented by this segment.
    let text: String
    /// Source passed to the renderer. Markdown fence delimiters may be
    /// synthesized at row boundaries so a split code block stays code.
    let renderedText: String
    /// Markdown parser state at the start of the exact retained source. This
    /// lets a streaming append re-project only the former tail even when a
    /// fenced block opened many rows earlier.
    let markdownContinuation: TranscriptMarkdownContinuation?
    /// True when this segment ends at a newline or the current source EOF.
    /// Fence state may only transition after a complete physical source line;
    /// a byte-budget cut must never turn a suffixed candidate into a close.
    let endsAtPhysicalLineEnd: Bool

    init(
        index: Int,
        text: String,
        renderedText: String? = nil,
        markdownContinuation: TranscriptMarkdownContinuation? = nil,
        endsAtPhysicalLineEnd: Bool = true
    ) {
        self.index = index
        self.text = text
        self.renderedText = renderedText ?? text
        self.markdownContinuation = markdownContinuation
        self.endsAtPhysicalLineEnd = endsAtPhysicalLineEnd
    }
}

struct TranscriptFirstTextSegment: Equatable, Sendable {
    let segment: TranscriptTextSegment
    let hasMore: Bool
}

/// Divides retained transcript text into exact, consecutive rendering units.
/// The units are table rows on macOS, so only units intersecting the viewport
/// have a SwiftUI/Markdown hierarchy. Joining every segment always reproduces
/// the retained source byte-for-byte; this type never truncates content.
enum TranscriptTextProjection {
    static func segments(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0,
        initialStartsAtLineBoundary: Bool = true
    ) -> [TranscriptTextSegment] {
        var result: [TranscriptTextSegment] = []
        result.reserveCapacity(max(1, source.utf8.count / maximumBytes))
        forEachSegment(
            of: source,
            maximumBytes: maximumBytes,
            maximumLines: maximumLines,
            startingIndex: startingIndex,
            initialStartsAtLineBoundary: initialStartsAtLineBoundary
        ) {
            result.append($0)
        }
        return result
    }

    private static func forEachSegment(
        of source: String,
        maximumBytes: Int,
        maximumLines: Int,
        startingIndex: Int,
        initialStartsAtLineBoundary: Bool,
        _ body: (TranscriptTextSegment) -> Void
    ) {
        guard !source.isEmpty else {
            body(TranscriptTextSegment(index: startingIndex, text: ""))
            return
        }
        precondition(maximumBytes >= 4)
        precondition(maximumLines > 1)

        let utf8 = source.utf8
        var start = utf8.startIndex
        var segmentIndex = startingIndex
        var startsAtLineBoundary = initialStartsAtLineBoundary
        while start < utf8.endIndex {
            var end = start
            var bytes = 0
            var lineCount = 1
            var lastLineBoundary: String.UTF8View.Index?
            while end < utf8.endIndex, bytes < maximumBytes {
                let byte = utf8[end]
                if byte == 0x0A, lineCount >= maximumLines {
                    break
                }
                end = utf8.index(after: end)
                bytes += 1
                if byte == 0x0A {
                    lineCount += 1
                    lastLineBoundary = end
                    if !startsAtLineBoundary {
                        // Finish the physical line that began in an earlier
                        // tile before admitting later lines. This lets the
                        // bounded fence state commit before rendering the next
                        // independently parsed row.
                        break
                    }
                }
            }

            // Prefer a complete source line when a row must split. Besides
            // preserving Markdown/list semantics, this prevents a delimiter
            // newline from becoming a leading blank line in the next row.
            if end < utf8.endIndex, let lastLineBoundary {
                end = lastLineBoundary
            }

            // A byte budget can end within a multi-byte scalar. Move the cut
            // to its leading byte so every row is valid UTF-8 and no byte is
            // lost when the segments are reassembled.
            if end < utf8.endIndex, utf8[end] & 0xC0 == 0x80 {
                repeat {
                    end = utf8.index(before: end)
                } while end > start && utf8[end] & 0xC0 == 0x80
            }
            precondition(end > start, "The transcript segment budget must fit one UTF-8 scalar")

            body(
                TranscriptTextSegment(
                    index: segmentIndex,
                    text: String(decoding: utf8[start..<end], as: UTF8.self),
                    endsAtPhysicalLineEnd: end == utf8.endIndex
                        || utf8[utf8.index(before: end)] == 0x0A
                )
            )
            segmentIndex += 1
            start = end
            startsAtLineBoundary = utf8[utf8.index(before: end)] == 0x0A
        }
    }

    static func firstSegment(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0,
        initialStartsAtLineBoundary: Bool = true
    ) -> TranscriptFirstTextSegment {
        guard !source.isEmpty else {
            return TranscriptFirstTextSegment(
                segment: TranscriptTextSegment(index: startingIndex, text: ""),
                hasMore: false
            )
        }
        precondition(maximumBytes >= 4)
        precondition(maximumLines > 1)

        let utf8 = source.utf8
        let start = utf8.startIndex
        var end = start
        var bytes = 0
        var lineCount = 1
        var lastLineBoundary: String.UTF8View.Index?
        while end < utf8.endIndex, bytes < maximumBytes {
            let byte = utf8[end]
            if byte == 0x0A, lineCount >= maximumLines {
                break
            }
            end = utf8.index(after: end)
            bytes += 1
            if byte == 0x0A {
                lineCount += 1
                lastLineBoundary = end
                if !initialStartsAtLineBoundary {
                    break
                }
            }
        }
        if end < utf8.endIndex, let lastLineBoundary {
            end = lastLineBoundary
        }
        if end < utf8.endIndex, utf8[end] & 0xC0 == 0x80 {
            repeat {
                end = utf8.index(before: end)
            } while end > start && utf8[end] & 0xC0 == 0x80
        }
        precondition(end > start, "The transcript segment budget must fit one UTF-8 scalar")
        return TranscriptFirstTextSegment(
            segment: TranscriptTextSegment(
                index: startingIndex,
                text: String(decoding: utf8[start..<end], as: UTF8.self),
                endsAtPhysicalLineEnd: end == utf8.endIndex
                    || utf8[utf8.index(before: end)] == 0x0A
            ),
            hasMore: end < utf8.endIndex
        )
    }

    /// Keeps fenced code semantically continuous across independently parsed
    /// table rows. Synthetic opening/closing delimiters affect rendering only;
    /// `text` remains the exact retained source used for completeness checks.
    static func markdownSegments(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0,
        initialContinuation: TranscriptMarkdownContinuation = .initial
    ) -> [TranscriptTextSegment] {
        let byteBudget = markdownByteBudget(maximumBytes: maximumBytes)
        precondition(maximumLines >= 3)
        let raw = segments(
            of: source,
            maximumBytes: byteBudget.sourceBytes,
            maximumLines: maximumLines - 2,
            startingIndex: startingIndex,
            initialStartsAtLineBoundary: initialContinuation.startsAtLineBoundary
        )
        var continuation = initialContinuation
        return raw.map { segment in
            renderedMarkdownSegment(
                segment,
                continuation: &continuation,
                maximumSyntheticFenceBytes: byteBudget.syntheticFenceBytes
            )
        }
    }

    /// Returns only the newest rendered Markdown keys while scanning source
    /// once and retaining at most `limit` small values. This is used by cache
    /// warming so a maximum retained item never creates a temporary full row
    /// array merely to select the visible suffix.
    static func markdownSegmentSuffix(
        of source: String,
        limit: Int,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0,
        initialContinuation: TranscriptMarkdownContinuation = .initial
    ) -> [TranscriptTextSegment] {
        guard limit > 0 else { return [] }
        let byteBudget = markdownByteBudget(maximumBytes: maximumBytes)
        precondition(maximumLines >= 3)
        var continuation = initialContinuation
        var suffix: [TranscriptTextSegment] = []
        suffix.reserveCapacity(limit)
        forEachSegment(
            of: source,
            maximumBytes: byteBudget.sourceBytes,
            maximumLines: maximumLines - 2,
            startingIndex: startingIndex,
            initialStartsAtLineBoundary: initialContinuation.startsAtLineBoundary
        ) { raw in
            let rendered = renderedMarkdownSegment(
                raw,
                continuation: &continuation,
                maximumSyntheticFenceBytes: byteBudget.syntheticFenceBytes
            )
            if suffix.count == limit {
                suffix.removeFirst()
            }
            suffix.append(rendered)
        }
        return suffix
    }

    static func firstMarkdownSegment(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0,
        initialContinuation: TranscriptMarkdownContinuation = .initial
    ) -> TranscriptFirstTextSegment {
        let byteBudget = markdownByteBudget(maximumBytes: maximumBytes)
        precondition(maximumLines >= 3)
        let raw = firstSegment(
            of: source,
            maximumBytes: byteBudget.sourceBytes,
            maximumLines: maximumLines - 2,
            startingIndex: startingIndex,
            initialStartsAtLineBoundary: initialContinuation.startsAtLineBoundary
        )
        var continuation = initialContinuation
        return TranscriptFirstTextSegment(
            segment: renderedMarkdownSegment(
                raw.segment,
                continuation: &continuation,
                maximumSyntheticFenceBytes: byteBudget.syntheticFenceBytes
            ),
            hasMore: raw.hasMore
        )
    }

    private static func renderedMarkdownSegment(
        _ segment: TranscriptTextSegment,
        continuation: inout TranscriptMarkdownContinuation,
        maximumSyntheticFenceBytes: Int
    ) -> TranscriptTextSegment {
        let continuationAtStart = continuation
        let isPhysicalLineFragment = !continuation.startsAtLineBoundary
            || !segment.endsAtPhysicalLineEnd
        if isPhysicalLineFragment {
            // A split physical line is never allowed to open or close a fence:
            // its unseen suffix can change whether the candidate is valid.
            // Render the fragment literally. Inside a real fenced block an
            // unmatchable guard fence prevents a partial delimiter run from
            // closing the independently parsed tile; outside a block the
            // first delimiter is an equivalent character reference so it
            // remains visible without becoming an artificial fence.
            let renderedText: String
            if continuation.openFence != nil {
                let guardFence = literalGuardFence(
                    for: segment.text,
                    maximumBytes: maximumSyntheticFenceBytes
                )
                renderedText = guardFence + "\n" + segment.text
                    + (segment.text.hasSuffix("\n") ? "" : "\n")
                    + guardFence
            } else {
                renderedText = neutralizingLeadingFence(in: segment.text)
            }
            consumeFenceState(
                in: segment.text,
                endsAtPhysicalLineEnd: segment.endsAtPhysicalLineEnd,
                continuation: &continuation,
                maximumSyntheticFenceBytes: maximumSyntheticFenceBytes
            )
            return TranscriptTextSegment(
                index: segment.index,
                text: segment.text,
                renderedText: renderedText,
                markdownContinuation: continuationAtStart,
                endsAtPhysicalLineEnd: segment.endsAtPhysicalLineEnd
            )
        }
        let prefix = syntheticFence(
            continuation.openFence,
            suffix: "\n",
            maximumBytes: maximumSyntheticFenceBytes
        )
        consumeFenceState(
            in: segment.text,
            endsAtPhysicalLineEnd: segment.endsAtPhysicalLineEnd,
            continuation: &continuation,
            maximumSyntheticFenceBytes: maximumSyntheticFenceBytes
        )
        let suffix: String
        if let openFence = continuation.openFence {
            suffix = syntheticFence(
                openFence,
                prefix: segment.text.hasSuffix("\n") ? "" : "\n",
                maximumBytes: maximumSyntheticFenceBytes
            )
        } else {
            suffix = ""
        }
        return TranscriptTextSegment(
            index: segment.index,
            text: segment.text,
            renderedText: prefix + segment.text + suffix,
            markdownContinuation: continuationAtStart,
            endsAtPhysicalLineEnd: segment.endsAtPhysicalLineEnd
        )
    }

    private static func consumeFenceState(
        in text: String,
        endsAtPhysicalLineEnd: Bool,
        continuation: inout TranscriptMarkdownContinuation,
        maximumSyntheticFenceBytes: Int
    ) {
        for byte in text.utf8 {
            if byte == 0x0A {
                commitPendingFenceLine(
                    continuation: &continuation,
                    maximumSyntheticFenceBytes: maximumSyntheticFenceBytes
                )
                continuation.startsAtLineBoundary = true
                continue
            }
            consumeFenceByte(
                byte,
                continuation: &continuation,
                maximumSyntheticFenceBytes: maximumSyntheticFenceBytes
            )
            continuation.startsAtLineBoundary = false
        }

        // A final source line without a newline is still a complete Markdown
        // line. A later streaming append re-projects the former tail from its
        // saved start continuation, so committing here cannot lose append
        // context.
        if endsAtPhysicalLineEnd, !text.hasSuffix("\n") {
            commitPendingFenceLine(
                continuation: &continuation,
                maximumSyntheticFenceBytes: maximumSyntheticFenceBytes
            )
            continuation.startsAtLineBoundary = false
        }
    }

    private static func consumeFenceByte(
        _ byte: UInt8,
        continuation: inout TranscriptMarkdownContinuation,
        maximumSyntheticFenceBytes: Int
    ) {
        switch continuation.pendingFenceLine {
        case .indent(let count):
            if byte == 0x20 {
                continuation.pendingFenceLine = count < 3
                    ? .indent(count + 1)
                    : .ordinary
                return
            }
            if let active = continuation.openFence,
               byte == active.utf8.first {
                continuation.pendingFenceLine = .closing(
                    runLength: 1,
                    inRun: true,
                    trailingWhitespaceOnly: true
                )
            } else if continuation.openFence == nil,
                      byte == 0x60 || byte == 0x7E {
                continuation.pendingFenceLine = .opening(
                    delimiter: byte,
                    runLength: 1,
                    inRun: true,
                    infoValid: true
                )
            } else {
                continuation.pendingFenceLine = .ordinary
            }

        case .opening(
            let delimiter,
            let runLength,
            let inRun,
            let infoValid
        ):
            if inRun, byte == delimiter {
                continuation.pendingFenceLine = .opening(
                    delimiter: delimiter,
                    runLength: min(
                        runLength + 1,
                        maximumSyntheticFenceBytes + 1
                    ),
                    inRun: true,
                    infoValid: infoValid
                )
            } else {
                continuation.pendingFenceLine = .opening(
                    delimiter: delimiter,
                    runLength: runLength,
                    inRun: false,
                    infoValid: infoValid
                        && (delimiter != 0x60 || byte != 0x60)
                )
            }

        case .closing(
            let runLength,
            let inRun,
            let trailingWhitespaceOnly
        ):
            let delimiter = continuation.openFence?.utf8.first
            if inRun, byte == delimiter {
                let requiredLength = continuation.openFence?.utf8.count ?? 0
                continuation.pendingFenceLine = .closing(
                    runLength: min(runLength + 1, max(requiredLength, 1)),
                    inRun: true,
                    trailingWhitespaceOnly: trailingWhitespaceOnly
                )
            } else {
                continuation.pendingFenceLine = .closing(
                    runLength: runLength,
                    inRun: false,
                    trailingWhitespaceOnly: trailingWhitespaceOnly
                        && (byte == 0x20 || byte == 0x09 || byte == 0x0D)
                )
            }

        case .ordinary:
            break
        }
    }

    private static func commitPendingFenceLine(
        continuation: inout TranscriptMarkdownContinuation,
        maximumSyntheticFenceBytes: Int
    ) {
        switch continuation.pendingFenceLine {
        case .opening(
            let delimiter,
            let runLength,
            _,
            let infoValid
        ) where continuation.openFence == nil
            && runLength >= 3
            && runLength <= maximumSyntheticFenceBytes
            && infoValid:
            continuation.openFence = String(
                repeating: String(UnicodeScalar(delimiter)),
                count: runLength
            )

        case .closing(
            let runLength,
            _,
            let trailingWhitespaceOnly
        ) where runLength >= (continuation.openFence?.utf8.count ?? .max)
            && trailingWhitespaceOnly:
            continuation.openFence = nil

        default:
            break
        }
        continuation.pendingFenceLine = .indent(0)
    }

    private static func markdownByteBudget(
        maximumBytes: Int
    ) -> (sourceBytes: Int, syntheticFenceBytes: Int) {
        // Reserve enough room for both an opening and a closing synthetic
        // delimiter, including their newlines. Making the source allowance no
        // larger than the delimiter allowance guarantees that every fence a
        // source row can contain can also be synthesized on adjacent rows.
        precondition(maximumBytes >= 16)
        let syntheticFenceBytes = maximumBytes / 3
        let syntheticReserveBytes = (syntheticFenceBytes + 1) * 2
        let sourceBytes = maximumBytes - syntheticReserveBytes
        precondition(sourceBytes >= 4)
        precondition(sourceBytes <= syntheticFenceBytes)
        return (sourceBytes, syntheticFenceBytes)
    }

    private static func syntheticFence(
        _ fence: String?,
        prefix: String = "",
        suffix: String = "",
        maximumBytes: Int
    ) -> String {
        guard let fence,
              fence.utf8.count <= maximumBytes else {
            return ""
        }
        return prefix + fence + suffix
    }

    /// Picks a fence that no run in this bounded fragment can close. The
    /// Markdown byte budget reserves one more delimiter byte than raw source,
    /// so even a fragment made entirely of one delimiter has a safe guard.
    private static func literalGuardFence(
        for text: String,
        maximumBytes: Int
    ) -> String {
        func maximumRun(of delimiter: UInt8) -> Int {
            var maximum = 0
            var current = 0
            for byte in text.utf8 {
                if byte == delimiter {
                    current += 1
                    maximum = max(maximum, current)
                } else {
                    current = 0
                }
            }
            return maximum
        }
        let backticks = maximumRun(of: 0x60)
        let tildes = maximumRun(of: 0x7E)
        let delimiter: Character = backticks <= tildes ? "`" : "~"
        let length = max(3, min(backticks, tildes) + 1)
        precondition(length <= maximumBytes)
        return String(repeating: String(delimiter), count: length)
    }

    private static func neutralizingLeadingFence(in text: String) -> String {
        let characters = Array(text)
        var index = 0
        while index < characters.count, characters[index] == " ", index < 4 {
            index += 1
        }
        guard index <= 3, index < characters.count else { return text }
        let delimiter = characters[index]
        guard delimiter == "`" || delimiter == "~" else { return text }
        var end = index
        while end < characters.count, characters[end] == delimiter {
            end += 1
        }
        guard end - index >= 3 else { return text }
        let entity = delimiter == "`" ? "&#96;" : "&#126;"
        return String(characters[..<index])
            + entity
            + String(characters[(index + 1)...])
    }

}

enum TranscriptProjectionTailAppend: Equatable, Sendable {
    case message(contentID: String, text: String)
    case reasoning(text: String)
    case toolOutput(text: String)
}

struct TranscriptProjectionIncrementalResult: Equatable, Sendable {
    let rows: [TranscriptRowProjection]
    let resegmentedSourceBytes: Int
}

struct TranscriptFirstRowProjectionResult: Equatable, Sendable {
    let row: TranscriptRowProjection
    let projectedSourceBytes: Int
}

struct TranscriptRowProjection: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        case message
        case reasoning
        case tool
        case diff
        case plan
        case generic

        var isDisclosure: Bool {
            switch self {
            case .reasoning, .tool, .diff, .generic: true
            case .message, .plan: false
            }
        }
    }

    enum Section: String, Sendable {
        case message
        case reasoning
        case toolHeader
        case toolInput
        case toolOutput
        case toolError
        case diff
        case planTitle
        case planStep
        case generic
    }

    // Keep each independently mounted table row below a single scroll-frame
    // layout budget without exploding an 8 MiB newline-dense transcript into
    // hundreds of thousands of table records. At 1 KiB / 128 lines a plain
    // cold Text measures around 4 ms p95 on the supported macOS baseline;
    // dense attributed artifacts are collapsed to bounded run counts before
    // mounting. Markdown also reserves space for synthetic fence delimiters.
    static let maximumDisplayBytes = 1 * 1_024
    static let maximumDisplayLines = 128

    let id: String
    let sourceItemID: String
    let kind: Kind
    let section: Section
    let contentRevision: UInt64
    let displayItem: ConversationItem
    let sourceText: String
    let isFirstInItem: Bool
    let isLastInItem: Bool
    let isFirstInSection: Bool
    let isLastInSection: Bool
    let accessibilitySummary: String
    let projectionSectionID: String
    let segmentIndex: Int
    let markdownContinuation: TranscriptMarkdownContinuation?

    private struct Draft {
        let id: String
        let kind: Kind
        let section: Section
        let sectionKey: String
        let displayItem: ConversationItem
        let sourceText: String
        let accessibilitySummary: String
        let segmentIndex: Int
        let markdownContinuation: TranscriptMarkdownContinuation?
    }

    static func makeRows(item: ConversationItem) -> [TranscriptRowProjection] {
        let drafts: [Draft]
        switch item {
        case .message(let message):
            drafts = messageDrafts(message)
        case .reasoning(let reasoning):
            drafts = reasoningDrafts(reasoning)
        case .tool(let tool):
            drafts = toolDrafts(tool)
        case .diff(let diff):
            drafts = diffDrafts(diff)
        case .plan(let plan):
            drafts = planDrafts(plan)
        case .generic(let generic):
            drafts = genericDrafts(generic)
        }

        return finalizedRows(drafts, sourceItemID: item.id)
    }

    static func makeFirstRow(
        item: ConversationItem
    ) -> TranscriptFirstRowProjectionResult? {
        let draft: Draft
        let hasMoreInSection: Bool
        let hasMoreInItem: Bool
        switch item {
        case .message, .plan:
            return nil

        case .reasoning(let reasoning):
            let first = TranscriptTextProjection.firstSegment(of: reasoning.text)
            guard let value = reasoningDrafts(
                reasoning,
                segments: [first.segment]
            ).first else { return nil }
            draft = value
            hasMoreInSection = first.hasMore
            hasMoreInItem = first.hasMore

        case .tool(let tool):
            let selection: (String, Section, Bool)?
            if let input = tool.input, !input.isEmpty {
                selection = (
                    input,
                    .toolInput,
                    tool.output?.isEmpty == false || tool.errorMessage?.isEmpty == false
                )
            } else if let output = tool.output, !output.isEmpty {
                selection = (
                    output,
                    .toolOutput,
                    tool.errorMessage?.isEmpty == false
                )
            } else if let error = tool.errorMessage, !error.isEmpty {
                selection = (error, .toolError, false)
            } else {
                selection = nil
            }
            if let (text, section, hasLaterSection) = selection {
                let first = TranscriptTextProjection.firstSegment(of: text)
                guard let value = toolDrafts(
                    tool,
                    section: section,
                    segments: [first.segment]
                ).first else { return nil }
                draft = value
                hasMoreInSection = first.hasMore
                hasMoreInItem = first.hasMore || hasLaterSection
            } else {
                guard let value = toolDrafts(tool).first else { return nil }
                draft = value
                hasMoreInSection = false
                hasMoreInItem = false
            }

        case .diff(let diff):
            let first = TranscriptTextProjection.firstSegment(of: diff.unifiedDiff)
            guard let value = diffDrafts(diff, segments: [first.segment]).first else {
                return nil
            }
            draft = value
            hasMoreInSection = first.hasMore
            hasMoreInItem = first.hasMore

        case .generic(let generic):
            let first = TranscriptTextProjection.firstSegment(of: generic.detail ?? "")
            guard let value = genericDrafts(generic, segments: [first.segment]).first else {
                return nil
            }
            draft = value
            hasMoreInSection = first.hasMore
            hasMoreInItem = first.hasMore
        }

        let row = projection(
            draft,
            sourceItemID: item.id,
            isFirstInItem: true,
            isLastInItem: !hasMoreInItem,
            isFirstInSection: true,
            isLastInSection: !hasMoreInSection
        )
        return TranscriptFirstRowProjectionResult(
            row: row,
            projectedSourceBytes: row.sourceText.utf8.count
        )
    }

    static func appendingToTail(
        _ append: TranscriptProjectionTailAppend,
        item: ConversationItem,
        previousRows: [TranscriptRowProjection]
    ) -> TranscriptProjectionIncrementalResult? {
        guard let previousTail = previousRows.last,
              previousTail.sourceItemID == item.id else {
            return nil
        }

        let drafts: [Draft]
        let appendedText: String
        switch (append, item) {
        case (.message(let contentID, let text), .message(let message)):
            guard let content = message.contents.last,
                  content.id == contentID,
                  previousTail.projectionSectionID == messageSectionID(contentID),
                  previousTail.section == .message else {
                return nil
            }
            appendedText = text
            let combinedTail = previousTail.sourceText + text
            let segments: [TranscriptTextSegment]
            if messageContentRendersMarkdown(content, message: message) {
                guard let continuation = previousTail.markdownContinuation else {
                    return nil
                }
                segments = TranscriptTextProjection.markdownSegments(
                    of: combinedTail,
                    startingIndex: previousTail.segmentIndex,
                    initialContinuation: continuation
                )
            } else {
                segments = TranscriptTextProjection.segments(
                    of: combinedTail,
                    startingIndex: previousTail.segmentIndex
                )
            }
            drafts = messageDrafts(
                message,
                content: content,
                segments: segments,
                isLastContent: true
            )

        case (.reasoning(let text), .reasoning(let reasoning)):
            guard previousTail.projectionSectionID == "reasoning",
                  previousTail.section == .reasoning else {
                return nil
            }
            appendedText = text
            let segments = TranscriptTextProjection.segments(
                of: previousTail.sourceText + text,
                startingIndex: previousTail.segmentIndex
            )
            drafts = reasoningDrafts(reasoning, segments: segments)

        case (.toolOutput(let text), .tool(let tool)):
            guard previousTail.projectionSectionID == "tool-output",
                  previousTail.section == .toolOutput else {
                return nil
            }
            appendedText = text
            let segments = TranscriptTextProjection.segments(
                of: previousTail.sourceText + text,
                startingIndex: previousTail.segmentIndex
            )
            drafts = toolDrafts(tool, section: .toolOutput, segments: segments)

        default:
            return nil
        }

        let tailRows = finalizedTailRows(
            drafts,
            sourceItemID: item.id,
            firstInItem: previousTail.isFirstInItem,
            firstInSection: previousTail.isFirstInSection
        )
        return TranscriptProjectionIncrementalResult(
            rows: Array(previousRows.dropLast()) + tailRows,
            resegmentedSourceBytes: previousTail.sourceText.utf8.count
                + appendedText.utf8.count
        )
    }

    private static func finalizedRows(
        _ drafts: [Draft],
        sourceItemID: String
    ) -> [TranscriptRowProjection] {
        drafts.enumerated().map { index, draft in
            let previousSection = index > 0 ? drafts[index - 1].sectionKey : nil
            let nextSection = index + 1 < drafts.count ? drafts[index + 1].sectionKey : nil
            return projection(
                draft,
                sourceItemID: sourceItemID,
                isFirstInItem: index == 0,
                isLastInItem: index == drafts.count - 1,
                isFirstInSection: previousSection != draft.sectionKey,
                isLastInSection: nextSection != draft.sectionKey
            )
        }
    }

    private static func finalizedTailRows(
        _ drafts: [Draft],
        sourceItemID: String,
        firstInItem: Bool,
        firstInSection: Bool
    ) -> [TranscriptRowProjection] {
        drafts.enumerated().map { index, draft in
            projection(
                draft,
                sourceItemID: sourceItemID,
                isFirstInItem: firstInItem && index == 0,
                isLastInItem: index == drafts.count - 1,
                isFirstInSection: firstInSection && index == 0,
                isLastInSection: index == drafts.count - 1
            )
        }
    }

    private static func projection(
        _ draft: Draft,
        sourceItemID: String,
        isFirstInItem: Bool,
        isLastInItem: Bool,
        isFirstInSection: Bool,
        isLastInSection: Bool
    ) -> TranscriptRowProjection {
        TranscriptRowProjection(
                id: draft.id,
                sourceItemID: sourceItemID,
                kind: draft.kind,
                section: draft.section,
                contentRevision: stableRevision(
                    for: draft,
                    isFirstInItem: isFirstInItem,
                    isLastInItem: isLastInItem,
                    isFirstInSection: isFirstInSection,
                    isLastInSection: isLastInSection
                ),
                displayItem: draft.displayItem,
                sourceText: draft.sourceText,
                isFirstInItem: isFirstInItem,
                isLastInItem: isLastInItem,
                isFirstInSection: isFirstInSection,
                isLastInSection: isLastInSection,
                accessibilitySummary: draft.accessibilitySummary,
                projectionSectionID: draft.sectionKey,
                segmentIndex: draft.segmentIndex,
                markdownContinuation: draft.markdownContinuation
        )
    }

    private static func messageDrafts(_ source: ChatMessage) -> [Draft] {
        let contents = source.contents.isEmpty
            ? [MessageContent(id: "\(source.id):content:0", text: "")]
            : source.contents
        let segmented = contents.map { content in
            let segments = messageContentRendersMarkdown(content, message: source)
                ? TranscriptTextProjection.markdownSegments(of: content.text)
                : TranscriptTextProjection.segments(of: content.text)
            return (content, segments)
        }
        let lastContentIndex = segmented.count - 1

        return segmented.enumerated().flatMap { contentIndex, value in
            let (content, segments) = value
            return messageDrafts(
                source,
                content: content,
                segments: segments,
                isLastContent: contentIndex == lastContentIndex
            )
        }
    }

    private static func messageDrafts(
        _ source: ChatMessage,
        content: MessageContent,
        segments: [TranscriptTextSegment],
        isLastContent: Bool
    ) -> [Draft] {
        let summary = source.role == .user ? "You" : "Assistant"
        let sectionID = messageSectionID(content.id)
        return segments.enumerated().map { offset, segment in
            let isLast = isLastContent && offset == segments.count - 1
            var displayedContent = content
            displayedContent.text = segment.renderedText
            displayedContent.isComplete = isLast ? content.isComplete : true
            var displayedMessage = source
            displayedMessage.contents = [displayedContent]
            displayedMessage.isStreaming = source.isStreaming && isLast
            return Draft(
                id: rowID(source.id, section: sectionID, segment.index),
                kind: .message,
                section: .message,
                sectionKey: sectionID,
                displayItem: .message(displayedMessage),
                sourceText: segment.text,
                accessibilitySummary: summary,
                segmentIndex: segment.index,
                markdownContinuation: segment.markdownContinuation
            )
        }
    }

    private static func messageContentRendersMarkdown(
        _ content: MessageContent,
        message: ChatMessage
    ) -> Bool {
        content.kind != .code
            && content.kind != .imagePlaceholder
            && !(message.role == .user
                && (content.kind == .plainText || content.kind == .generic))
    }

    private static func messageSectionID(_ contentID: String) -> String {
        "message:\(contentID)"
    }

    private static func reasoningDrafts(_ source: ChatReasoning) -> [Draft] {
        reasoningDrafts(
            source,
            segments: TranscriptTextProjection.segments(of: source.text)
        )
    }

    private static func reasoningDrafts(
        _ source: ChatReasoning,
        segments: [TranscriptTextSegment]
    ) -> [Draft] {
        segments.map { segment in
            var displayed = source
            displayed.text = segment.text
            return Draft(
                id: rowID(source.id, section: "reasoning", segment.index),
                kind: .reasoning,
                section: .reasoning,
                sectionKey: "reasoning",
                displayItem: .reasoning(displayed),
                sourceText: segment.text,
                accessibilitySummary: source.isStreaming ? "Thinking" : "Reasoning summary",
                segmentIndex: segment.index,
                markdownContinuation: nil
            )
        }
    }

    private static func toolDrafts(_ source: ToolActivity) -> [Draft] {
        var result: [Draft] = []

        func append(_ text: String?, section: Section) {
            guard let text, !text.isEmpty else { return }
            result.append(contentsOf: toolDrafts(
                source,
                section: section,
                segments: TranscriptTextProjection.segments(of: text)
            ))
        }

        append(source.input, section: .toolInput)
        append(source.output, section: .toolOutput)
        append(source.errorMessage, section: .toolError)
        if result.isEmpty {
            var displayed = source
            displayed.input = nil
            displayed.output = nil
            displayed.errorMessage = nil
            result.append(
                Draft(
                    id: rowID(source.id, section: "tool-header", 0),
                    kind: .tool,
                    section: .toolHeader,
                    sectionKey: "tool-header",
                    displayItem: .tool(displayed),
                    sourceText: "",
                    accessibilitySummary: boundedSummary(source.title),
                    segmentIndex: 0,
                    markdownContinuation: nil
                )
            )
        }
        return result
    }

    private static func toolDrafts(
        _ source: ToolActivity,
        section: Section,
        segments: [TranscriptTextSegment]
    ) -> [Draft] {
        let key: String
        switch section {
        case .toolInput:
            key = "tool-input"
        case .toolOutput:
            key = "tool-output"
        case .toolError:
            key = "tool-error"
        default:
            preconditionFailure("A tool text projection requires a text section")
        }
        return segments.map { segment in
            var displayed = source
            displayed.input = section == .toolInput ? segment.text : nil
            displayed.output = section == .toolOutput ? segment.text : nil
            displayed.errorMessage = section == .toolError ? segment.text : nil
            return Draft(
                id: rowID(source.id, section: key, segment.index),
                kind: .tool,
                section: section,
                sectionKey: key,
                displayItem: .tool(displayed),
                sourceText: segment.text,
                accessibilitySummary: boundedSummary(source.title),
                segmentIndex: segment.index,
                markdownContinuation: nil
            )
        }
    }

    private static func diffDrafts(_ source: ChatDiff) -> [Draft] {
        diffDrafts(
            source,
            segments: TranscriptTextProjection.segments(of: source.unifiedDiff)
        )
    }

    private static func diffDrafts(
        _ source: ChatDiff,
        segments: [TranscriptTextSegment]
    ) -> [Draft] {
        segments.map { segment in
            var displayed = source
            displayed.unifiedDiff = segment.text
            return Draft(
                id: rowID(source.id, section: "diff", segment.index),
                kind: .diff,
                section: .diff,
                sectionKey: "diff",
                displayItem: .diff(displayed),
                sourceText: segment.text,
                accessibilitySummary: boundedSummary(source.path ?? "File changes"),
                segmentIndex: segment.index,
                markdownContinuation: nil
            )
        }
    }

    private static func planDrafts(_ source: ChatPlan) -> [Draft] {
        var result: [Draft] = []
        if let title = source.title {
            for segment in TranscriptTextProjection.segments(of: title) {
                var displayed = source
                displayed.title = segment.text
                displayed.steps = []
                result.append(
                    Draft(
                        id: rowID(source.id, section: "plan-title", segment.index),
                        kind: .plan,
                        section: .planTitle,
                        sectionKey: "plan-title",
                        displayItem: .plan(displayed),
                        sourceText: segment.text,
                        accessibilitySummary: boundedSummary(title),
                        segmentIndex: segment.index,
                        markdownContinuation: nil
                    )
                )
            }
        }
        for step in source.steps {
            for segment in TranscriptTextProjection.segments(of: step.title) {
                var displayedStep = step
                displayedStep.title = segment.text
                var displayed = source
                displayed.title = nil
                displayed.steps = [displayedStep]
                result.append(
                    Draft(
                        id: rowID(source.id, section: "plan-step:\(step.id)", segment.index),
                        kind: .plan,
                        section: .planStep,
                        sectionKey: "plan-step:\(step.id)",
                        displayItem: .plan(displayed),
                        sourceText: segment.text,
                        accessibilitySummary: boundedSummary(source.title ?? "Plan"),
                        segmentIndex: segment.index,
                        markdownContinuation: nil
                    )
                )
            }
        }
        if result.isEmpty {
            result.append(
                Draft(
                    id: rowID(source.id, section: "plan-title", 0),
                    kind: .plan,
                    section: .planTitle,
                    sectionKey: "plan-title",
                    displayItem: .plan(source),
                    sourceText: "",
                    accessibilitySummary: "Plan",
                    segmentIndex: 0,
                    markdownContinuation: nil
                )
            )
        }
        return result
    }

    private static func genericDrafts(_ source: ChatGenericItem) -> [Draft] {
        let segments = source.detail.map { detail in
            TranscriptTextProjection.segments(of: detail)
        }
            ?? [TranscriptTextSegment(index: 0, text: "")]
        return genericDrafts(source, segments: segments)
    }

    private static func genericDrafts(
        _ source: ChatGenericItem,
        segments: [TranscriptTextSegment]
    ) -> [Draft] {
        return segments.map { segment in
            var displayed = source
            displayed.detail = source.detail == nil ? nil : segment.text
            return Draft(
                id: rowID(source.id, section: "generic", segment.index),
                kind: .generic,
                section: .generic,
                sectionKey: "generic",
                displayItem: .generic(displayed),
                sourceText: segment.text,
                accessibilitySummary: boundedSummary(source.title),
                segmentIndex: segment.index,
                markdownContinuation: nil
            )
        }
    }

    private static func boundedSummary(_ text: String) -> String {
        String(text.prefix(200))
    }

    private static func rowID(_ itemID: String, section: String, _ index: Int) -> String {
        "\(itemID):transcript:\(section):\(index)"
    }

    /// A deterministic content hash lets the table reconfigure only the tail
    /// segment that actually changed during streaming. Item-wide revisions
    /// would otherwise remount every visible segment on every delta.
    private static func stableRevision(
        for draft: Draft,
        isFirstInItem: Bool,
        isLastInItem: Bool,
        isFirstInSection: Bool,
        isLastInSection: Bool
    ) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        func combine(_ value: String) {
            for byte in value.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
            hash ^= 0xFF
            hash &*= 1_099_511_628_211
        }
        combine(draft.kind.rawValue)
        combine(draft.section.rawValue)
        combine(isFirstInItem ? "first-item" : "middle-item")
        combine(isLastInItem ? "last-item" : "middle-item")
        combine(isFirstInSection ? "first-section" : "middle-section")
        combine(isLastInSection ? "last-section" : "middle-section")
        switch draft.displayItem {
        case .message(let message):
            combine(message.role.rawValue)
            combine(message.text)
            combine(message.isStreaming ? "streaming" : "complete")
            combine(String(message.occurredAt ?? -1))
        case .reasoning(let reasoning):
            combine(reasoning.text)
            combine(reasoning.isStreaming ? "streaming" : "complete")
        case .tool(let tool):
            combine(tool.title)
            combine(tool.status.rawValue)
            combine(tool.input ?? "")
            combine(tool.output ?? "")
            combine(tool.errorMessage ?? "")
            combine(String(tool.durationMilliseconds ?? -1))
            combine(String(tool.exitCode ?? Int.min))
        case .diff(let diff):
            combine(diff.path ?? "")
            combine(diff.unifiedDiff)
            combine(diff.isTruncated ? "source-truncated" : "complete")
        case .plan(let plan):
            combine(plan.title ?? "")
            for step in plan.steps {
                combine(step.id)
                combine(step.title)
                combine(step.isCompleted ? "complete" : "pending")
            }
        case .generic(let generic):
            combine(generic.title)
            combine(generic.type)
            combine(generic.detail ?? "")
        }
        return hash
    }
}
