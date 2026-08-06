import Foundation

struct TranscriptMarkdownContinuation: Equatable, Sendable {
    var openFence: String?
    var startsAtLineBoundary: Bool

    static let initial = TranscriptMarkdownContinuation(
        openFence: nil,
        startsAtLineBoundary: true
    )
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

    init(
        index: Int,
        text: String,
        renderedText: String? = nil,
        markdownContinuation: TranscriptMarkdownContinuation? = nil
    ) {
        self.index = index
        self.text = text
        self.renderedText = renderedText ?? text
        self.markdownContinuation = markdownContinuation
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
        startingIndex: Int = 0
    ) -> [TranscriptTextSegment] {
        guard !source.isEmpty else {
            return [TranscriptTextSegment(index: startingIndex, text: "")]
        }
        precondition(maximumBytes >= 4)
        precondition(maximumLines > 1)

        let utf8 = source.utf8
        var result: [TranscriptTextSegment] = []
        result.reserveCapacity(max(1, utf8.count / maximumBytes))
        var start = utf8.startIndex

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

            result.append(
                TranscriptTextSegment(
                    index: startingIndex + result.count,
                    text: String(decoding: utf8[start..<end], as: UTF8.self)
                )
            )
            start = end
        }
        return result
    }

    static func firstSegment(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0
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
                text: String(decoding: utf8[start..<end], as: UTF8.self)
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
        precondition(maximumBytes >= 12)
        precondition(maximumLines >= 3)
        let raw = segments(
            of: source,
            // Reserve room for a synthetic three-byte fence and newline at
            // each edge. Rendered input therefore stays inside the same cap.
            maximumBytes: maximumBytes - 8,
            maximumLines: maximumLines - 2,
            startingIndex: startingIndex
        )
        var continuation = initialContinuation
        return raw.map { segment in
            renderedMarkdownSegment(segment, continuation: &continuation)
        }
    }

    static func firstMarkdownSegment(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines,
        startingIndex: Int = 0,
        initialContinuation: TranscriptMarkdownContinuation = .initial
    ) -> TranscriptFirstTextSegment {
        precondition(maximumBytes >= 12)
        precondition(maximumLines >= 3)
        let raw = firstSegment(
            of: source,
            maximumBytes: maximumBytes - 8,
            maximumLines: maximumLines - 2,
            startingIndex: startingIndex
        )
        var continuation = initialContinuation
        return TranscriptFirstTextSegment(
            segment: renderedMarkdownSegment(
                raw.segment,
                continuation: &continuation
            ),
            hasMore: raw.hasMore
        )
    }

    private static func renderedMarkdownSegment(
        _ segment: TranscriptTextSegment,
        continuation: inout TranscriptMarkdownContinuation
    ) -> TranscriptTextSegment {
        let continuationAtStart = continuation
        let prefix = continuation.openFence.map { "\($0)\n" } ?? ""
        for (lineIndex, line) in segment.text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).enumerated() where continuation.startsAtLineBoundary || lineIndex > 0 {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let active = continuation.openFence {
                if trimmed.hasPrefix(active) {
                    continuation.openFence = nil
                }
            } else if trimmed.hasPrefix("```") {
                continuation.openFence = "```"
            } else if trimmed.hasPrefix("~~~") {
                continuation.openFence = "~~~"
            }
        }
        continuation.startsAtLineBoundary = segment.text.hasSuffix("\n")
        let suffix: String
        if let openFence = continuation.openFence {
            suffix = (segment.text.hasSuffix("\n") ? "" : "\n") + openFence
        } else {
            suffix = ""
        }
        return TranscriptTextSegment(
            index: segment.index,
            text: segment.text,
            renderedText: prefix + segment.text + suffix,
            markdownContinuation: continuationAtStart
        )
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

    // Keep each independently mounted table row small enough that TextKit and
    // SwiftUI cannot turn a single viewport insertion into a long frame. The
    // Markdown projection reserves part of these budgets for synthetic fence
    // delimiters, so rendered text (not only retained source) stays bounded.
    static let maximumDisplayBytes = 4 * 1_024
    static let maximumDisplayLines = 256

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
