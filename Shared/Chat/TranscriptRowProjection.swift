import Foundation

struct TranscriptTextSegment: Equatable, Sendable {
    let index: Int
    /// Exact retained source represented by this segment.
    let text: String
    /// Source passed to the renderer. Markdown fence delimiters may be
    /// synthesized at row boundaries so a split code block stays code.
    let renderedText: String

    init(index: Int, text: String, renderedText: String? = nil) {
        self.index = index
        self.text = text
        self.renderedText = renderedText ?? text
    }
}

/// Divides retained transcript text into exact, consecutive rendering units.
/// The units are table rows on macOS, so only units intersecting the viewport
/// have a SwiftUI/Markdown hierarchy. Joining every segment always reproduces
/// the retained source byte-for-byte; this type never truncates content.
enum TranscriptTextProjection {
    static func segments(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines
    ) -> [TranscriptTextSegment] {
        guard !source.isEmpty else {
            return [TranscriptTextSegment(index: 0, text: "")]
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
                    index: result.count,
                    text: String(decoding: utf8[start..<end], as: UTF8.self)
                )
            )
            start = end
        }
        return result
    }

    /// Keeps fenced code semantically continuous across independently parsed
    /// table rows. Synthetic opening/closing delimiters affect rendering only;
    /// `text` remains the exact retained source used for completeness checks.
    static func markdownSegments(
        of source: String,
        maximumBytes: Int = TranscriptRowProjection.maximumDisplayBytes,
        maximumLines: Int = TranscriptRowProjection.maximumDisplayLines
    ) -> [TranscriptTextSegment] {
        precondition(maximumBytes >= 12)
        precondition(maximumLines >= 3)
        let raw = segments(
            of: source,
            // Reserve room for a synthetic three-byte fence and newline at
            // each edge. Rendered input therefore stays inside the same cap.
            maximumBytes: maximumBytes - 8,
            maximumLines: maximumLines - 2
        )
        var openFence: String?
        var startsAtLineBoundary = true
        return raw.map { segment in
            let prefix = openFence.map { "\($0)\n" } ?? ""
            for (lineIndex, line) in segment.text.split(
                separator: "\n",
                omittingEmptySubsequences: false
            ).enumerated() where startsAtLineBoundary || lineIndex > 0 {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if let active = openFence {
                    if trimmed.hasPrefix(active) {
                        openFence = nil
                    }
                } else if trimmed.hasPrefix("```") {
                    openFence = "```"
                } else if trimmed.hasPrefix("~~~") {
                    openFence = "~~~"
                }
            }
            startsAtLineBoundary = segment.text.hasSuffix("\n")
            let suffix: String
            if let openFence {
                suffix = (segment.text.hasSuffix("\n") ? "" : "\n")
                    + openFence
            } else {
                suffix = ""
            }
            return TranscriptTextSegment(
                index: segment.index,
                text: segment.text,
                renderedText: prefix + segment.text + suffix
            )
        }
    }
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

    static let maximumDisplayBytes = 64 * 1_024
    static let maximumDisplayLines = 120

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

    private struct Draft {
        let id: String
        let kind: Kind
        let section: Section
        let sectionKey: String
        let displayItem: ConversationItem
        let sourceText: String
        let accessibilitySummary: String
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

        return drafts.enumerated().map { index, draft in
            let previousSection = index > 0 ? drafts[index - 1].sectionKey : nil
            let nextSection = index + 1 < drafts.count ? drafts[index + 1].sectionKey : nil
            return TranscriptRowProjection(
                id: draft.id,
                sourceItemID: item.id,
                kind: draft.kind,
                section: draft.section,
                contentRevision: stableRevision(for: draft),
                displayItem: draft.displayItem,
                sourceText: draft.sourceText,
                isFirstInItem: index == 0,
                isLastInItem: index == drafts.count - 1,
                isFirstInSection: previousSection != draft.sectionKey,
                isLastInSection: nextSection != draft.sectionKey,
                accessibilitySummary: draft.accessibilitySummary
            )
        }
    }

    private static func messageDrafts(_ source: ChatMessage) -> [Draft] {
        let summary = source.role == .user ? "You" : "Assistant"
        let contents = source.contents.isEmpty
            ? [MessageContent(id: "\(source.id):content:0", text: "")]
            : source.contents
        let segmented = contents.map { content in
            let rendersMarkdown = content.kind != .code
                && content.kind != .imagePlaceholder
                && !(source.role == .user
                    && (content.kind == .plainText || content.kind == .generic))
            let segments = rendersMarkdown
                ? TranscriptTextProjection.markdownSegments(of: content.text)
                : TranscriptTextProjection.segments(of: content.text)
            return (content, segments)
        }
        let lastContentIndex = segmented.count - 1

        return segmented.enumerated().flatMap { contentIndex, value in
            let (content, segments) = value
            return segments.map { segment in
                let isLast = contentIndex == lastContentIndex
                    && segment.index == segments.count - 1
                var displayedContent = content
                displayedContent.text = segment.renderedText
                displayedContent.isComplete = isLast ? content.isComplete : true
                var displayedMessage = source
                displayedMessage.contents = [displayedContent]
                displayedMessage.isStreaming = source.isStreaming && isLast
                return Draft(
                    id: rowID(source.id, section: "message:\(content.id)", segment.index),
                    kind: .message,
                    section: .message,
                    sectionKey: "message:\(content.id)",
                    displayItem: .message(displayedMessage),
                    sourceText: segment.text,
                    accessibilitySummary: summary
                )
            }
        }
    }

    private static func reasoningDrafts(_ source: ChatReasoning) -> [Draft] {
        TranscriptTextProjection.segments(of: source.text).map { segment in
            var displayed = source
            displayed.text = segment.text
            return Draft(
                id: rowID(source.id, section: "reasoning", segment.index),
                kind: .reasoning,
                section: .reasoning,
                sectionKey: "reasoning",
                displayItem: .reasoning(displayed),
                sourceText: segment.text,
                accessibilitySummary: source.isStreaming ? "Thinking" : "Reasoning summary"
            )
        }
    }

    private static func toolDrafts(_ source: ToolActivity) -> [Draft] {
        var result: [Draft] = []

        func append(_ text: String?, section: Section, key: String) {
            guard let text, !text.isEmpty else { return }
            for segment in TranscriptTextProjection.segments(of: text) {
                var displayed = source
                displayed.input = section == .toolInput ? segment.text : nil
                displayed.output = section == .toolOutput ? segment.text : nil
                displayed.errorMessage = section == .toolError ? segment.text : nil
                result.append(
                    Draft(
                        id: rowID(source.id, section: key, segment.index),
                        kind: .tool,
                        section: section,
                        sectionKey: key,
                        displayItem: .tool(displayed),
                        sourceText: segment.text,
                        accessibilitySummary: boundedSummary(source.title)
                    )
                )
            }
        }

        append(source.input, section: .toolInput, key: "tool-input")
        append(source.output, section: .toolOutput, key: "tool-output")
        append(source.errorMessage, section: .toolError, key: "tool-error")
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
                    accessibilitySummary: boundedSummary(source.title)
                )
            )
        }
        return result
    }

    private static func diffDrafts(_ source: ChatDiff) -> [Draft] {
        TranscriptTextProjection.segments(of: source.unifiedDiff).map { segment in
            var displayed = source
            displayed.unifiedDiff = segment.text
            return Draft(
                id: rowID(source.id, section: "diff", segment.index),
                kind: .diff,
                section: .diff,
                sectionKey: "diff",
                displayItem: .diff(displayed),
                sourceText: segment.text,
                accessibilitySummary: boundedSummary(source.path ?? "File changes")
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
                        accessibilitySummary: boundedSummary(title)
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
                        accessibilitySummary: boundedSummary(source.title ?? "Plan")
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
                    accessibilitySummary: "Plan"
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
                accessibilitySummary: boundedSummary(source.title)
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
    private static func stableRevision(for draft: Draft) -> UInt64 {
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
