import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Sanitized scroll diagnostics: state names and pin commands only, logged on
/// transitions rather than per frame. `log stream --predicate 'subsystem ==
/// "com.mpieras.TerminalRelay"'` shows them under `conversation-scroll`.
let conversationScrollLogger = Logger(
    subsystem: "com.mpieras.TerminalRelay",
    category: "conversation-scroll"
)

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

#if os(macOS)
private extension DynamicTypeSize {
    var macTranscriptFontScale: CGFloat {
        switch self {
        case .xSmall: 0.82
        case .small: 0.88
        case .medium: 0.94
        case .large: 1
        case .xLarge: 1.12
        case .xxLarge: 1.23
        case .xxxLarge: 1.35
        case .accessibility1: 1.64
        case .accessibility2: 1.95
        case .accessibility3: 2.35
        case .accessibility4: 2.76
        case .accessibility5: 3.12
        @unknown default: 1
        }
    }
}

struct MacMessageFooter: Equatable {
    let itemID: String
    let turnID: String?
    let occurredAt: Int64?
    let role: ChatMessageRole

    var id: String { "\(itemID):footer" }
}

enum MacTranscriptRow: MacConversationTableRow {
    case history(id: String, revision: UInt64)
    case item(TranscriptRowProjection, isExpanded: Bool, copiedItemID: String?)
    case messageFooter(MacMessageFooter, revision: UInt64)
    case toolGroupHeader(ToolGroupHeaderModel, revision: UInt64)
    case toolGroupLive(ToolGroupLiveModel, revision: UInt64)
    case pendingTurn
    case approval(ApprovalRequest, revision: UInt64)
    case question(QuestionRequest, revision: UInt64)

    var id: String {
        switch self {
        case .history(let id, _): id
        case .item(let projection, _, _): projection.id
        case .messageFooter(let footer, _): footer.id
        case .toolGroupHeader(let header, _): header.id
        case .toolGroupLive(let live, _): live.id
        case .pendingTurn: "pending-turn"
        case .approval(let approval, _): "approval:\(approval.id)"
        case .question(let question, _): "question:\(question.id)"
        }
    }

    var contentRevision: UInt64 {
        switch self {
        case .history(_, let revision), .messageFooter(_, let revision),
             .approval(_, let revision), .question(_, let revision),
             .toolGroupHeader(_, let revision), .toolGroupLive(_, let revision):
            return revision
        case .pendingTurn:
            return 0
        case .item(let projection, let isExpanded, let copiedItemID):
            var revision = projection.contentRevision &* 1099511628211
            revision ^= isExpanded ? 1 : 0
            if copiedItemID == projection.sourceItemID
                || copiedItemID?.hasPrefix("\(projection.sourceItemID):") == true {
                revision ^= 2
            }
            return revision
        }
    }

    var reuseIdentifier: String {
        switch self {
        case .history: "transcript.history"
        case .item(let projection, _, _): "transcript.\(projection.kind.rawValue)"
        case .messageFooter: "transcript.message-footer"
        case .toolGroupHeader: "transcript.toolgroup-header"
        case .toolGroupLive: "transcript.toolgroup-live"
        case .pendingTurn: "transcript.pending-turn"
        case .approval: "transcript.approval"
        case .question: "transcript.question"
        }
    }

    /// Store mutations are expressed in logical conversation-item IDs while
    /// one item may project into many table tiles. The table uses this value
    /// to route a logical update to the visible tiles that belong to it.
    var mutationSourceID: String {
        switch self {
        case .item(let projection, _, _):
            projection.sourceItemID
        case .messageFooter(let footer, _):
            footer.itemID
        default:
            id
        }
    }

    /// Completed Markdown artifact used by the corresponding hosted row.
    /// The table asks for a bounded band around the viewport, never the full
    /// transcript, so preparation stays ahead of cell realization.
    var preparedMarkdownText: String? {
        guard case .item(let projection, _, _) = self,
              case .message(let message) = projection.displayItem,
              !message.isStreaming,
              let content = message.contents.first,
              content.isComplete else {
            return nil
        }
        switch content.kind {
        case .code, .imagePlaceholder:
            return nil
        case .plainText, .generic:
            return message.role == .user ? nil : content.text
        case .markdown:
            return content.text
        }
    }

    /// Plain text this row contributes to a cross-transcript selection.
    /// Tiles contribute their model text; collapsed disclosure first rows and
    /// tool-group lines contribute the exact composed headline they render;
    /// hidden collapsed bodies and non-text rows contribute nothing.
    var selectionText: String? {
        switch self {
        case .item(let projection, let isExpanded, _):
            guard projection.kind.isDisclosure else {
                return projection.rowText
            }
            if projection.isFirstInItem {
                switch projection.displayItem {
                case .tool(let tool):
                    return tool.composedHeadline(
                        compactLine: projection.compactLine
                    )
                case .reasoning(let reasoning):
                    return reasoning.isStreaming
                        ? "Thinking…"
                        : "Reasoning summary"
                case .diff(let diff):
                    return diff.path ?? "File changes"
                case .generic(let generic):
                    return generic.title
                case .message, .plan:
                    return projection.rowText
                }
            }
            guard isExpanded else { return nil }
            return projection.rowText
        case .toolGroupHeader(let header, _):
            return header.summary
        case .toolGroupLive(let live, _):
            return live.headline
        case .history, .messageFooter, .pendingTurn, .approval, .question:
            return nil
        }
    }

    var selectionRoleLabel: String? {
        guard case .item(let projection, _, _) = self,
              case .message(let message) = projection.displayItem else {
            return nil
        }
        return message.role == .user ? "You:" : "Assistant:"
    }

    var selectionSectionID: String? {
        guard case .item(let projection, _, _) = self else { return id }
        return projection.projectionSectionID
    }

    /// Stable text tiles bypass SwiftUI hosting entirely. Interactive rows,
    /// streaming tails, image content, and disclosure headers stay hosted; a
    /// completed message footer is a separate small native control row, so the
    /// final large-message text tile can use TextKit.
    @MainActor
    func liveScrollTextPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeTextPresentation? {
        guard case .item(let projection, let isExpanded, _) = self else {
            return nil
        }
        if let native = nativeTextPresentation(
            dynamicTypeSize: dynamicTypeSize,
            colorScheme: colorScheme
        ) {
            return native.liveScrollCopy(
                fallbackString: projection.rowText,
                accessibilityLabel: projection.accessibilitySummary
            )
        }
        let fontScale = dynamicTypeSize.macTranscriptFontScale
        // Compact activity lines (tool headlines, reasoning/diff/generic
        // headers) are a single truncated line in the hosted row; the scroll
        // stand-in draws the same line over the same fixed floor so the cell
        // swap at gesture boundaries never changes row height.
        if projection.isFirstInItem, projection.kind.isDisclosure {
            let line: String
            switch projection.displayItem {
            case .tool(let tool):
                var text = projection.compactLine ?? tool.compactHeadline
                if let outcome = tool.compactOutcome { text += " · \(outcome)" }
                line = text
            case .reasoning(let reasoning):
                line = reasoning.isStreaming ? "Thinking…" : "Reasoning summary"
            case .diff(let diff):
                line = diff.path ?? "File changes"
            case .generic(let generic):
                line = generic.title
            case .message, .plan:
                line = projection.rowText
            }
            return MacConversationNativeTextPresentation(
                fallbackString: Self.boundedCompactActivityLine(line),
                contentInsets: NSEdgeInsets(
                    top: ChatTypography.activityLinePadding,
                    left: 28,
                    bottom: projection.isLastInItem || !isExpanded
                        ? ChatTypography.activityLinePadding
                        : 0,
                    right: 28
                ),
                firstRowTopInsetAdjustment: 22 - ChatTypography.activityLinePadding,
                lastRowBottomInsetAdjustment: 16 - ChatTypography.activityLinePadding,
                minimumTextContainerHeight: ChatTypography.activityLineHeight,
                maximumContentWidth: 760,
                fallbackFont: NSFont.systemFont(
                    ofSize: NSFont.systemFontSize * fontScale
                ),
                fallbackColor: .secondaryLabelColor,
                accessibilityLabel: projection.accessibilitySummary,
                accessibilityIdentifier: "conversation.item.\(projection.sourceItemID)",
                usesFastPlainTextRenderer: true
            )
        }
        let isMonospaced: Bool
        switch projection.kind {
        case .diff:
            isMonospaced = projection.section != .diffPath
        case .generic:
            isMonospaced = projection.section == .generic
        case .tool:
            isMonospaced = projection.section != .toolTitle
                && projection.section != .toolError
        case .message:
            if case .message(let message) = projection.displayItem {
                isMonospaced = message.contents.first?.kind == .code
            } else {
                isMonospaced = false
            }
        case .reasoning, .plan:
            isMonospaced = false
        }
        let font = isMonospaced
            ? NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize * fontScale,
                weight: .regular
            )
            : NSFont.systemFont(
                ofSize: NSFont.systemFontSize * fontScale
            )
        // Disclosure first rows returned above as compact activity lines, so
        // only message tiles and expanded disclosure body tiles reach here.
        let semanticHeader = Self.liveScrollSemanticHeader(for: projection)
        let source = projection.kind.isDisclosure && !isExpanded
            ? ""
            : projection.rowText
        let displayText = Self.boundedLiveScrollText(
            source: source,
            semanticHeader: semanticHeader
        )
        let isDisclosureBody = projection.kind.isDisclosure
            && !projection.isFirstInItem
        return MacConversationNativeTextPresentation(
            fallbackString: displayText,
            contentInsets: NSEdgeInsets(
                top: projection.isFirstInItem ? 7 : 0,
                left: 28,
                bottom: isDisclosureBody
                    ? 4 + (projection.isLastInItem
                        ? ChatTypography.activityLinePadding
                        : 0)
                    : (projection.isLastInItem ? 7 : 0),
                right: 28
            ),
            firstRowTopInsetAdjustment: isDisclosureBody
                ? 22 - ChatTypography.activityLinePadding
                : 15,
            lastRowBottomInsetAdjustment: isDisclosureBody
                ? 16 - ChatTypography.activityLinePadding
                : 9,
            minimumTextContainerHeight: semanticHeader == nil ? 0 : 44,
            maximumContentWidth: 760,
            fallbackFont: font,
            fallbackColor: projection.kind == .reasoning
                ? .secondaryLabelColor
                : .labelColor,
            accessibilityLabel: projection.accessibilitySummary,
            accessibilityIdentifier: projection.isFirstInItem
                ? "conversation.item.\(projection.sourceItemID)"
                : "conversation.item.\(projection.sourceItemID).segment.\(projection.id)",
            usesFastPlainTextRenderer: true
        )
    }

    private static func liveScrollSemanticHeader(
        for projection: TranscriptRowProjection
    ) -> String? {
        switch projection.displayItem {
        case .message(let message):
            guard projection.sourceText.isEmpty,
                  message.contents.first?.kind == .imagePlaceholder else {
                return nil
            }
            return "Image"
        case .reasoning(let reasoning):
            guard projection.isFirstInItem else { return nil }
            return reasoning.isStreaming ? "Thinking…" : "Reasoning summary"
        case .tool(let tool):
            var components: [String] = []
            if projection.isFirstInItem {
                if projection.section != .toolTitle {
                    components.append(projection.accessibilitySummary)
                }
                components.append(tool.status.rawValue.capitalized)
            }
            if projection.isFirstInSection {
                switch projection.section {
                case .toolInput:
                    components.append("Input")
                case .toolOutput:
                    components.append("Output")
                case .toolError:
                    components.append("Error")
                case .toolHeader:
                    break
                default:
                    break
                }
            }
            if projection.rowText.isEmpty,
               projection.section != .toolTitle {
                components.append(
                    tool.status == .running
                        ? "Waiting for output…"
                        : "No additional output"
                )
            }
            return components.isEmpty ? nil : components.joined(separator: " · ")
        case .diff(let diff):
            guard projection.isFirstInItem else { return nil }
            if projection.section == .diffPath {
                return diff.isTruncated ? "Source truncated" : nil
            }
            return diff.isTruncated
                ? "\(projection.accessibilitySummary) · Source truncated"
                : projection.accessibilitySummary
        case .plan:
            return projection.sourceText.isEmpty ? "Plan" : nil
        case .generic(let generic):
            guard projection.isFirstInItem else { return nil }
            if projection.section == .genericTitle
                || projection.section == .genericType {
                return nil
            }
            var components = [projection.accessibilitySummary]
            if !generic.type.isEmpty {
                components.append(
                    TranscriptTextProjection.boundedUTF8Prefix(
                        generic.type,
                        maximumBytes: 200
                    )
                )
            }
            if projection.sourceText.isEmpty {
                components.append("No additional details")
            }
            return components.joined(separator: " · ")
        }
    }

    /// Stand-ins for single-line activity rows must never wrap: a wrapped
    /// line would measure taller than the hosted row it replaces. Bounding
    /// characters keeps one line at any realistic transcript width; bounding
    /// bytes keeps dense grapheme clusters from hiding kilobytes in it.
    private static func boundedCompactActivityLine(_ value: String) -> String {
        let flattened = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        var bounded = TranscriptTextProjection.boundedUTF8Prefix(
            flattened,
            maximumBytes: 192
        )
        if bounded.count > 48 {
            bounded = String(bounded.prefix(48))
        }
        return bounded == flattened ? bounded : bounded + "…"
    }

    /// Header metadata shares the same bounded Core Text input as the exact
    /// source. Source bytes always win; a semantic header uses only the spare
    /// budget so the live renderer never hides or truncates retained content.
    private static func boundedLiveScrollText(
        source: String,
        semanticHeader: String?
    ) -> String {
        guard let semanticHeader, !semanticHeader.isEmpty else { return source }
        let normalizedHeader = TranscriptTextProjection.boundedUTF8Prefix(
            semanticHeader,
            maximumBytes: TranscriptRowProjection.maximumDisplayBytes
        )
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !normalizedHeader.isEmpty else { return source }
        if !source.isEmpty {
            guard TranscriptTextProjection.logicalLineCount(
                source,
                stoppingAt: TranscriptRowProjection.maximumDisplayLines
            ) < TranscriptRowProjection.maximumDisplayLines else {
                return source
            }
        }
        let separator = source.isEmpty ? "" : "\n"
        let remainingBytes = TranscriptRowProjection.maximumDisplayBytes
            - source.utf8.count
            - separator.utf8.count
        guard remainingBytes > 0 else { return source }

        var boundedHeader = ""
        boundedHeader.reserveCapacity(min(normalizedHeader.count, remainingBytes))
        var byteCount = 0
        for character in normalizedHeader {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= remainingBytes else { break }
            boundedHeader.append(character)
            byteCount += characterBytes
        }
        guard !boundedHeader.isEmpty else { return source }
        return boundedHeader + separator + source
    }

    @MainActor
    func nativeTextPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeTextPresentation? {
        guard case .item(let projection, let isExpanded, _) = self else {
            return nil
        }
        let fontScale = dynamicTypeSize.macTranscriptFontScale
        let identifier = projection.isFirstInItem
            ? "conversation.item.\(projection.sourceItemID)"
            : "conversation.item.\(projection.sourceItemID).segment.\(projection.id)"
        let itemTopInset: CGFloat = projection.isFirstInItem ? 7 : 0
        // Disclosure items use the compact activity spacing, matching the
        // hosted rows they swap with.
        let disclosureBottomInset: CGFloat = projection.isLastInItem
            ? ChatTypography.activityLinePadding
            : 0

        switch projection.displayItem {
        case .message(let message):
            guard !message.isStreaming,
                  let content = message.contents.first,
                  content.isComplete else {
                return nil
            }
            switch content.kind {
            case .code:
                guard message.role != .user else { return nil }
                return Self.codeNativePresentation(
                    text: projection.sourceText,
                    projection: projection,
                    identifier: identifier,
                    fontScale: fontScale
                )
            case .imagePlaceholder:
                return nil
            case .markdown, .plainText, .generic:
                break
            }

            if message.role == .user,
               content.kind == .plainText || content.kind == .generic {
                return Self.userNativePresentation(
                    text: projection.sourceText,
                    projection: projection,
                    identifier: identifier,
                    fontScale: fontScale
                )
            }
            let source = content.text
            // The prepared attributed representation flattens tables to text
            // lines; rows carrying one stay hosted for real grid rendering.
            if MarkdownSafety.containsTableCandidate(source) { return nil }
            // Every role mounts its rich Markdown immediately when the AppKit
            // artifact is already translated for this style: both probes are
            // pure lookups (one NSCache read, one single-slot memo read) and
            // never parse or translate, so they are safe on the gesture
            // realization and height-estimation paths. Mounting plain first
            // when the rich artifact is right there made a settled message
            // visibly reformat on every scroll pass — Markdown collapses soft
            // line breaks, so line-structured replies changed shape entirely.
            let cached = SanitizedMarkdownCache.shared.lookupPrepared(raw: source)
            let immediate = cached?.cachedAppKitAttributedText(
                fontScale: fontScale,
                colorScheme: colorScheme
            )
            let deferred: MacConversationNativeTextPresentation.DeferredAttributedString?
            if immediate == nil {
                deferred = {
                    let prepared: PreparedMarkdown
                    if let cached {
                        prepared = cached
                    } else {
                        guard let value = await SanitizedMarkdownCache.shared
                            .preparedMarkdown(raw: source) else {
                            return nil
                        }
                        prepared = value
                    }
                    return MacConversationNativeTextPresentation.DeferredArtifact {
                        prepared.appKitAttributedText(
                            fontScale: fontScale,
                            colorScheme: colorScheme
                        )
                    }
                }
            } else {
                deferred = nil
            }
            if message.role == .user {
                return Self.userNativePresentation(
                    attributedString: immediate,
                    fallbackText: projection.sourceText,
                    projection: projection,
                    identifier: identifier,
                    fontScale: fontScale,
                    deferredAttributedString: deferred
                )
            }
            // A warm artifact mounts as rich text directly; only genuinely
            // cold tiles paint exact source first and promote when idle.
            let isWarmRich = immediate != nil
            return MacConversationNativeTextPresentation(
                attributedString: immediate,
                fallbackString: projection.sourceText,
                contentInsets: NSEdgeInsets(
                    top: itemTopInset,
                    left: 28,
                    bottom: 0,
                    right: 28
                ),
                firstRowTopInsetAdjustment: 15,
                lastRowBottomInsetAdjustment: 9,
                maximumContentWidth: 760,
                fallbackFont: NSFont.systemFont(
                    ofSize: NSFont.systemFontSize * fontScale
                ),
                fallbackColor: .labelColor,
                accessibilityLabel: projection.accessibilitySummary,
                accessibilityIdentifier: identifier,
                deferredAttributedString: deferred,
                usesFastPlainTextRenderer: !isWarmRich,
                promotesFastRendererWhenIdle: !isWarmRich
            )

        case .reasoning(let reasoning):
            guard isExpanded,
                  !projection.isFirstInItem,
                  !reasoning.isStreaming else {
                return nil
            }
            return Self.plainNativePresentation(
                text: reasoning.text,
                projection: projection,
                identifier: identifier,
                color: .secondaryLabelColor,
                isMonospaced: false,
                topInset: 0,
                bottomInset: 4 + disclosureBottomInset,
                leadingTextInset: 23,
                fontScale: fontScale
            )

        case .generic(let generic):
            if let metadataText = projection.metadataText {
                guard isExpanded, !projection.isFirstInItem else { return nil }
                return Self.plainNativePresentation(
                    text: metadataText,
                    projection: projection,
                    identifier: identifier,
                    color: .secondaryLabelColor,
                    isMonospaced: false,
                    topInset: 0,
                    bottomInset: 4 + disclosureBottomInset,
                    leadingTextInset: 23,
                    fontScale: fontScale
                )
            }
            guard isExpanded,
                  !projection.isFirstInItem,
                  let detail = generic.detail else {
                return nil
            }
            return Self.plainNativePresentation(
                text: detail,
                projection: projection,
                identifier: identifier,
                color: .labelColor,
                isMonospaced: true,
                topInset: 0,
                bottomInset: 4 + disclosureBottomInset,
                leadingTextInset: 23,
                fontScale: fontScale
            )

        case .tool(let tool):
            if let metadataText = projection.metadataText {
                guard isExpanded, !projection.isFirstInItem else { return nil }
                return Self.plainNativePresentation(
                    text: metadataText,
                    projection: projection,
                    identifier: identifier,
                    color: .secondaryLabelColor,
                    isMonospaced: false,
                    topInset: 0,
                    bottomInset: 4 + disclosureBottomInset,
                    leadingTextInset: 23,
                    fontScale: fontScale
                )
            }
            guard isExpanded,
                  !projection.isFirstInItem,
                  !projection.isFirstInSection,
                  tool.status != .pending,
                  tool.status != .running else {
                return nil
            }
            return Self.plainNativePresentation(
                text: projection.sourceText,
                projection: projection,
                identifier: identifier,
                color: projection.section == .toolError
                    ? .systemRed
                    : .labelColor,
                isMonospaced: projection.section != .toolError,
                topInset: 0,
                bottomInset: 4 + disclosureBottomInset,
                leadingTextInset: 23,
                fontScale: fontScale
            )

        case .diff:
            if let metadataText = projection.metadataText {
                guard isExpanded, !projection.isFirstInItem else { return nil }
                return Self.plainNativePresentation(
                    text: metadataText,
                    projection: projection,
                    identifier: identifier,
                    color: .secondaryLabelColor,
                    isMonospaced: false,
                    topInset: 0,
                    bottomInset: 4 + disclosureBottomInset,
                    leadingTextInset: 23,
                    fontScale: fontScale
                )
            }
            guard isExpanded, !projection.isFirstInItem else { return nil }
            return Self.plainNativePresentation(
                text: projection.sourceText,
                projection: projection,
                identifier: identifier,
                color: .labelColor,
                isMonospaced: true,
                topInset: 0,
                bottomInset: 4 + disclosureBottomInset,
                leadingTextInset: 23,
                fontScale: fontScale
            )

        case .plan:
            return nil
        }
    }

    @MainActor
    func nativeFooterPresentation(
        dynamicTypeSize: DynamicTypeSize,
        colorScheme: ColorScheme
    ) -> MacConversationNativeFooterPresentation? {
        guard case .messageFooter(let footer, _) = self else { return nil }
        let date = ChatTimestamp.date(
            milliseconds: footer.occurredAt,
            fallbackUUIDv7s: [footer.turnID, footer.itemID]
        )
        return MacConversationNativeFooterPresentation(
            itemID: footer.itemID,
            timestampLabel: date.map { ChatTimestamp.label(for: $0) },
            timestampAccessibilityLabel: date?.formatted(
                date: .complete,
                time: .shortened
            ),
            isTrailing: footer.role == .user,
            fontScale: dynamicTypeSize.macTranscriptFontScale,
            accessibilityIdentifier: "conversation.item.\(footer.itemID).footer"
        )
    }

    @MainActor
    private static func userNativePresentation(
        text: String,
        projection: TranscriptRowProjection,
        identifier: String,
        fontScale: CGFloat
    ) -> MacConversationNativeTextPresentation {
        return userNativePresentation(
            attributedString: nil,
            fallbackText: text,
            projection: projection,
            identifier: identifier,
            fontScale: fontScale
        )
    }

    @MainActor
    private static func userNativePresentation(
        attributedString: NSAttributedString?,
        fallbackText: String,
        projection: TranscriptRowProjection,
        identifier: String,
        fontScale: CGFloat,
        deferredAttributedString:
            MacConversationNativeTextPresentation.DeferredAttributedString? = nil
    ) -> MacConversationNativeTextPresentation {
        var corners: MacConversationNativeTextPresentation.RoundedCorners = []
        if projection.isFirstInItem {
            corners.formUnion([.topLeading, .topTrailing])
        }
        if projection.isLastInItem {
            corners.formUnion([.bottomLeading, .bottomTrailing])
        }
        return MacConversationNativeTextPresentation(
            attributedString: attributedString,
            fallbackString: fallbackText,
            contentInsets: NSEdgeInsets(
                top: projection.isFirstInItem ? 7 : 0,
                left: 28,
                bottom: 0,
                right: 28
            ),
            firstRowTopInsetAdjustment: 15,
            lastRowBottomInsetAdjustment: 0,
            textEdgeInsets: NSEdgeInsets(
                top: projection.isFirstInItem
                    ? 12
                    : (projection.isFirstInSection ? 10 : 0),
                left: 12,
                bottom: projection.isLastInItem ? 12 : 0,
                right: 12
            ),
            maximumContentWidth: 760,
            maximumTextWidth: 640,
            // Only an undivided message may hug its text. A message long
            // enough to span several tiles keeps the shared bubble width so
            // the stacked segments cannot come out ragged.
            hugsTextWidth: projection.isFirstInItem && projection.isLastInItem,
            backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.12),
            backgroundCornerRadius: 16,
            roundedCorners: corners,
            horizontalAlignment: .trailing,
            fallbackFont: NSFont.systemFont(
                ofSize: NSFont.systemFontSize * fontScale
            ),
            fallbackColor: .labelColor,
            accessibilityLabel: projection.accessibilitySummary,
            accessibilityIdentifier: identifier,
            deferredAttributedString: deferredAttributedString
        )
    }

    @MainActor
    private static func plainNativePresentation(
        text: String,
        projection: TranscriptRowProjection,
        identifier: String,
        color: NSColor,
        isMonospaced: Bool,
        topInset: CGFloat,
        bottomInset: CGFloat,
        leadingTextInset: CGFloat,
        fontScale: CGFloat
    ) -> MacConversationNativeTextPresentation {
        let paragraph = NSMutableParagraphStyle()
        paragraph.headIndent = leadingTextInset
        paragraph.firstLineHeadIndent = leadingTextInset
        let font = isMonospaced
            ? NSFont.monospacedSystemFont(
                ofSize: NSFont.systemFontSize * fontScale,
                weight: .regular
            )
            : NSFont.systemFont(ofSize: NSFont.systemFontSize * fontScale)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        return MacConversationNativeTextPresentation(
            attributedString: attributed,
            fallbackString: text,
            contentInsets: NSEdgeInsets(
                top: topInset,
                left: 28,
                bottom: bottomInset,
                right: 28
            ),
            // Disclosure tiles carry the compact 2pt item spacing, so the
            // global 22pt/16pt transcript edges need larger adjustments than
            // the 7pt message tiles use.
            firstRowTopInsetAdjustment: 22 - ChatTypography.activityLinePadding,
            lastRowBottomInsetAdjustment: 16 - ChatTypography.activityLinePadding,
            maximumContentWidth: 760,
            fallbackFont: font,
            fallbackColor: color,
            fallbackParagraphStyle: paragraph,
            accessibilityLabel: projection.accessibilitySummary,
            accessibilityIdentifier: identifier,
            usesFastPlainTextRenderer: true
        )
    }

    @MainActor
    private static func codeNativePresentation(
        text: String,
        projection: TranscriptRowProjection,
        identifier: String,
        fontScale: CGFloat
    ) -> MacConversationNativeTextPresentation {
        var corners: MacConversationNativeTextPresentation.RoundedCorners = []
        if projection.isFirstInSection {
            corners.formUnion([.topLeading, .topTrailing])
        }
        if projection.isLastInSection {
            corners.formUnion([.bottomLeading, .bottomTrailing])
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byCharWrapping
        let font = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize * fontScale,
            weight: .regular
        )
        let color = NSColor.labelColor
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]
        )
        return MacConversationNativeTextPresentation(
            attributedString: attributed,
            fallbackString: text,
            contentInsets: NSEdgeInsets(
                top: projection.isFirstInItem ? 7 : 0,
                left: 28,
                bottom: 0,
                right: 28
            ),
            firstRowTopInsetAdjustment: 15,
            lastRowBottomInsetAdjustment: 9,
            textEdgeInsets: NSEdgeInsets(
                top: projection.isFirstInSection ? 12 : 0,
                left: 12,
                bottom: projection.isLastInSection ? 12 : 0,
                right: 12
            ),
            maximumContentWidth: 760,
            backgroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.065),
            backgroundCornerRadius: 12,
            roundedCorners: corners,
            fallbackFont: font,
            fallbackColor: color,
            fallbackParagraphStyle: paragraph,
            accessibilityLabel: projection.accessibilitySummary,
            accessibilityIdentifier: identifier,
            usesFastPlainTextRenderer: true
        )
    }
}

func makeMacTranscriptRows(
    item: ConversationItem,
    projections: [TranscriptRowProjection],
    isExpanded: Bool,
    copiedItemID: String?,
    sectionRevision: UInt64
) -> [MacTranscriptRow] {
    var rows = projections.map { projection in
        MacTranscriptRow.item(
            projection,
            isExpanded: isExpanded,
            copiedItemID: copiedItemID
        )
    }
    if case .message(let message) = item,
       !message.isStreaming,
       message.hasText {
        rows.append(
            .messageFooter(
                MacMessageFooter(
                    itemID: message.id,
                    turnID: message.turnID,
                    occurredAt: message.occurredAt,
                    role: message.role
                ),
                revision: sectionRevision
            )
        )
    }
    return rows
}

/// Reuses the projected rows for every unchanged logical item. SwiftUI can
/// reevaluate the transcript for unrelated state, but that must not remap all
/// 68k bounded rows in a maximum newline-dense retained conversation.
private final class MacTranscriptSectionCache {
    private struct Entry {
        let revision: UInt64
        let rows: [MacTranscriptRow]
    }

    private var entries: [String: Entry] = [:]
    private var retainedItemIDs: Set<String> = []

    func section(
        for itemID: String,
        revision: UInt64,
        makeRows: () -> [MacTranscriptRow]
    ) -> MacConversationTableSection<MacTranscriptRow> {
        let rows: [MacTranscriptRow]
        if let cached = entries[itemID], cached.revision == revision {
            rows = cached.rows
        } else {
            rows = makeRows()
            entries[itemID] = Entry(revision: revision, rows: rows)
        }
        return MacConversationTableSection(
            id: "item:\(itemID)",
            revision: revision,
            rows: rows
        )
    }

    func retain(itemIDs: Set<String>) {
        guard itemIDs != retainedItemIDs else { return }
        entries = entries.filter { itemIDs.contains($0.key) }
        retainedItemIDs = itemIDs
    }
}
#endif

/// Coarse scroll geometry: only boundary crossings and content-height motion
/// change this value, so the scroll-geometry action never runs on plain
/// scrolled frames. That keeps user scrolling free of SwiftUI graph work.
private struct ConversationScrollGeometrySample: Equatable {
    var isAtBottom: Bool
    var isNearBottom: Bool
    var contentHeightBucket: Int

    static let initial = ConversationScrollGeometrySample(
        isAtBottom: true,
        isNearBottom: true,
        contentHeightBucket: 0
    )
}

/// Scroll bookkeeping that must never invalidate the view body.
@MainActor
private final class ConversationScrollScratch {
    var lastSample = ConversationScrollGeometrySample.initial
}

struct ConversationView: View {
    @ObservedObject private var store: ConversationStore

    let coordinator: ConversationCoordinator
    let isReadOnly: Bool
    let showsComposer: Bool
    let startsCoordinator: Bool
    let attachmentActions: ChatAttachmentActions?

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @State private var escapeRouter = ComposerEscapeRouter()
    #endif
    @State private var rowActions: ChatRowActions

    init(
        coordinator: ConversationCoordinator,
        isReadOnly: Bool = false,
        showsComposer: Bool = true,
        startsCoordinator: Bool = true,
        attachmentActions: ChatAttachmentActions? = nil
    ) {
        self.coordinator = coordinator
        _store = ObservedObject(wrappedValue: coordinator.store)
        self.isReadOnly = isReadOnly
        self.showsComposer = showsComposer
        self.startsCoordinator = startsCoordinator
        self.attachmentActions = attachmentActions
        _rowActions = State(
            wrappedValue: ChatRowActions(
                store: coordinator.store,
                coordinator: coordinator
            )
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
                .overlay(alignment: .bottom) {
                    // Floating, so appearing and disappearing never resizes
                    // the viewport: a layout shift here would break the
                    // at-bottom follow state during every reconnect.
                    if !isReadOnly {
                        syncingNotice
                    }
                }
            if !isReadOnly {
                compactNotice
            }
            if !isReadOnly, showsComposer {
                composer
            }
        }
        .background(Color.chatCanvas)
        .task {
            if startsCoordinator {
                coordinator.start()
            }
        }
        .onChange(of: isPendingTurnGap, initial: true) { _, isPending in
            pendingTurnRevealTask?.cancel()
            pendingTurnRevealTask = nil
            if isPending {
                // Envelope boundaries (reasoning sealed, tool about to
                // start) pass through a pending gap for one publish; only a
                // gap that persists is the model actually thinking.
                pendingTurnRevealTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    showsPendingTurnIndicator = true
                }
            } else {
                showsPendingTurnIndicator = false
            }
        }
        .onDisappear {
            if startsCoordinator {
                Task {
                    await coordinator.detach()
                }
            }
        }
        #if os(iOS)
        .onKeyPress(.escape, phases: [.down, .repeat]) { keyPress in
            guard !isReadOnly, showsComposer else { return .ignored }
            switch escapeRouter.route(
                activeTurnID: store.state.activeTurnID,
                timestamp: ProcessInfo.processInfo.systemUptime,
                isRepeat: keyPress.phase.contains(.repeat)
            ) {
            case .passThrough:
                return .ignored
            case .consume:
                return .handled
            case .interrupt:
                Task {
                    await coordinator.interrupt()
                }
                return .handled
            }
        }
        #endif
        .sheet(
            item: Binding(
                get: { store.state.filePreview },
                set: { value in
                    if value == nil { store.dismissFilePreview() }
                }
            )
        ) { preview in
            FilePreviewSheet(preview: preview) {
                store.dismissFilePreview()
            }
        }
    }

    /// iOS keeps an explicit history window around its eager SwiftUI stack.
    /// macOS uses reusable AppKit rows and does not use this window.
    private static let transcriptWindowStep = 150

    @State private var firstVisibleItemID: String?
    @State private var showsPendingTurnIndicator = false
    @State private var pendingTurnRevealTask: Task<Void, Never>?

    private var isPendingTurnGap: Bool {
        PendingTurnIndicator.showsPendingTurn(
            turnState: store.state.turnState,
            lastItem: store.state.items.last
        )
    }

    #if os(macOS)
    /// False until the AppKit transcript has applied content and completed
    /// its one-shot open anchor; the loading curtain covers the canvas until
    /// then so an open never shows a bare black transcript.
    @State private var isTranscriptAnchored = false
    #endif

    private var visibleItems: ArraySlice<ConversationItem> {
        let items = store.state.items
        if let firstVisibleItemID,
           let index = items.firstIndex(where: { $0.id == firstVisibleItemID }) {
            return items[index...]
        }
        return items.suffix(Self.transcriptWindowStep)
    }

    private var hasHiddenLocalItems: Bool {
        visibleItems.first?.id != store.state.items.first?.id
    }

    /// Everything the hosted transcript content can visually depend on.
    /// Control-only records advance the replay cursor without changing this
    /// revision, so opening a cached conversation does not synchronously
    /// remeasure every row for its attach ack, heartbeats, and ready state.
    private var transcriptContentRevision: Int {
        var hasher = Hasher()
        hasher.combine(store.transcriptContentRevision)
        hasher.combine(store.state.items.count)
        hasher.combine(store.state.items.first?.id)
        hasher.combine(store.state.items.last?.id)
        hasher.combine(firstVisibleItemID)
        hasher.combine(store.expandedItemIDs)
        hasher.combine(store.copiedItemID)
        hasher.combine(store.respondingInteractionIDs)
        hasher.combine(store.selectedQuestionOptions)
        hasher.combine(store.questionText)
        hasher.combine(store.isLoadingOlderHistory)
        hasher.combine(store.state.hasOlderHistory)
        hasher.combine(store.state.didTruncateHistory)
        hasher.combine(showsPendingTurnIndicator)
        hasher.combine(colorScheme)
        hasher.combine(dynamicTypeSize)
        return hasher.finalize()
    }

    @ViewBuilder
    private var transcript: some View {
        #if os(macOS)
        macTranscript
        #else
        iosTranscript
        #endif
    }

    #if os(macOS)
    @State private var macTableCommandHandle = MacConversationTableCommandHandle()
    @State private var macTranscriptSectionCache = MacTranscriptSectionCache()

    private var macSections: [MacConversationTableSection<MacTranscriptRow>] {
        var sections: [MacConversationTableSection<MacTranscriptRow>] = []
        if store.state.hasOlderHistory {
            var hasher = Hasher()
            hasher.combine(store.state.oldestItemID)
            hasher.combine(store.state.didTruncateHistory)
            hasher.combine(store.isLoadingOlderHistory)
            let revision = UInt64(truncatingIfNeeded: hasher.finalize())
            let id = "history:\(store.state.oldestItemID ?? "start")"
            sections.append(
                MacConversationTableSection(
                    id: id,
                    revision: revision,
                    rows: [.history(
                        id: "history:\(store.state.oldestItemID ?? "start")",
                        revision: revision
                    )]
                )
            )
        }
        var retainedItemIDs = Set<String>()
        retainedItemIDs.reserveCapacity(store.state.items.count)
        let renderedItems = store.state.items.filter { !$0.isTranscriptNoise }
        for entry in TranscriptEntry.entries(of: renderedItems) {
            switch entry {
            case .item(let item):
                retainedItemIDs.insert(item.id)
                let isExpanded = store.expandedItemIDs.contains(item.id)
                let isDisclosure: Bool
                switch item {
                case .reasoning, .tool, .diff, .generic:
                    isDisclosure = true
                case .message, .plan:
                    isDisclosure = false
                }
                var sectionRevision = store.transcriptItemContentRevision(for: item.id)
                    &* 1099511628211
                if isExpanded { sectionRevision ^= 1 }
                if store.copiedItemID == item.id
                    || store.copiedItemID?.hasPrefix("\(item.id):") == true {
                    sectionRevision ^= 2
                }
                sections.append(
                    macTranscriptSectionCache.section(
                        for: item.id,
                        revision: sectionRevision
                    ) {
                        let visibleProjections: [TranscriptRowProjection]
                        if isDisclosure && !isExpanded {
                            visibleProjections = store.transcriptFirstProjection(for: item)
                                .map { [$0] } ?? []
                        } else {
                            visibleProjections = store.transcriptProjections(for: item)
                        }
                        return makeMacTranscriptRows(
                            item: item,
                            projections: visibleProjections,
                            isExpanded: isExpanded,
                            copiedItemID: store.copiedItemID,
                            sectionRevision: sectionRevision
                        )
                    }
                )
            case .toolGroup(let group):
                retainedItemIDs.insert(group.id)
                let isGroupExpanded = store.expandedItemIDs.contains(group.id)
                // Collapsed groups hash only what their two fixed-height
                // lines can show, so output deltas leave the section — and
                // the table — completely untouched.
                var hasher = Hasher()
                hasher.combine(isGroupExpanded)
                for tool in group.tools {
                    hasher.combine(tool.id)
                    hasher.combine(tool.status)
                    hasher.combine(tool.title)
                    hasher.combine(tool.kind)
                    hasher.combine(tool.input?.utf8.count ?? -1)
                    hasher.combine(tool.exitCode)
                    if isGroupExpanded {
                        hasher.combine(store.expandedItemIDs.contains(tool.id))
                        hasher.combine(
                            store.transcriptItemContentRevision(for: tool.id)
                        )
                        if store.copiedItemID == tool.id
                            || store.copiedItemID?.hasPrefix("\(tool.id):") == true {
                            hasher.combine(store.copiedItemID)
                        }
                    }
                }
                let groupRevision = UInt64(truncatingIfNeeded: hasher.finalize())
                sections.append(
                    macTranscriptSectionCache.section(
                        for: group.id,
                        revision: groupRevision
                    ) {
                        makeToolGroupRows(
                            group: group,
                            isGroupExpanded: isGroupExpanded,
                            revision: groupRevision
                        )
                    }
                )
            }
        }
        macTranscriptSectionCache.retain(itemIDs: retainedItemIDs)
        if showsPendingTurnIndicator {
            sections.append(
                MacConversationTableSection(
                    id: "pending-turn",
                    revision: 0,
                    rows: [.pendingTurn]
                )
            )
        }
        sections.append(contentsOf: store.state.approvals.map { approval in
            var hasher = Hasher()
            hasher.combine(approval.id)
            hasher.combine(approval.status.rawValue)
            hasher.combine(store.respondingInteractionIDs.contains(approval.id))
            hasher.combine(store.pendingDestructiveApprovalConfirmation?.approvalID == approval.id)
            let revision = UInt64(truncatingIfNeeded: hasher.finalize())
            return MacConversationTableSection(
                id: "approval:\(approval.id)",
                revision: revision,
                rows: [.approval(approval, revision: revision)]
            )
        })
        sections.append(contentsOf: store.state.questions.map { question in
            var hasher = Hasher()
            hasher.combine(question.id)
            hasher.combine(question.status.rawValue)
            hasher.combine(store.respondingInteractionIDs.contains(question.id))
            hasher.combine(store.selectedQuestionOptions)
            hasher.combine(store.questionText)
            let revision = UInt64(truncatingIfNeeded: hasher.finalize())
            return MacConversationTableSection(
                id: "question:\(question.id)",
                revision: revision,
                rows: [.question(question, revision: revision)]
            )
        })
        return sections
    }

    private func makeToolGroupRows(
        group: ToolGroup,
        isGroupExpanded: Bool,
        revision: UInt64
    ) -> [MacTranscriptRow] {
        var rows: [MacTranscriptRow] = [
            .toolGroupHeader(
                group.headerModel(isExpanded: isGroupExpanded),
                revision: revision
            ),
        ]
        if isGroupExpanded {
            for item in group.items {
                let isExpanded = store.expandedItemIDs.contains(item.id)
                let projections: [TranscriptRowProjection]
                if isExpanded {
                    projections = store.transcriptProjections(for: item)
                } else {
                    projections = store.transcriptFirstProjection(for: item)
                        .map { [$0] } ?? []
                }
                rows.append(contentsOf: makeMacTranscriptRows(
                    item: item,
                    projections: projections,
                    isExpanded: isExpanded,
                    copiedItemID: store.copiedItemID,
                    sectionRevision: revision
                ))
            }
        } else if let runningTool = group.runningTool {
            rows.append(
                .toolGroupLive(
                    ToolGroupLiveModel(
                        groupID: group.id,
                        headline: runningTool.compactHeadline
                    ),
                    revision: revision
                )
            )
        }
        return rows
    }

    private var macTranscript: some View {
        var styleHasher = Hasher()
        styleHasher.combine(colorScheme)
        styleHasher.combine(dynamicTypeSize)
        return MacConversationTableView(
            sections: macSections,
            snapshotGeneration: store.state.snapshotGeneration,
            transcriptMutation: store.transcriptMutation,
            dataRevision: transcriptContentRevision,
            styleRevision: styleHasher.finalize(),
            reduceMotion: reduceMotion,
            commandHandle: macTableCommandHandle,
            onNearBottomChange: { store.setNearBottom($0) },
            onLiveScrollingChange: { store.setTranscriptLiveScrolling($0) },
            onAnchoredChange: { isTranscriptAnchored = $0 },
            prefetchRows: { rows in
                let texts = rows.compactMap(\.preparedMarkdownText)
                guard !texts.isEmpty else { return }
                await SanitizedMarkdownCache.shared.prefetch(texts: texts)
            },
            onNativeLink: { url in
                switch ChatURLPolicy.classify(url) {
                case .external(let externalURL):
                    openURL(externalURL)
                case .repository(let link):
                    rowActions.openRepository(link)
                case .blocked:
                    break
                }
                return true
            },
            onNativeCopyMessage: { itemID in
                rowActions.copyMessage(itemID: itemID, fallback: "")
            },
            makeRow: { row, isFirst, isLast in
                AnyView(
                    macRowView(
                        row,
                        isFirst: isFirst,
                        isLast: isLast
                    )
                )
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("conversation.transcript")
        .accessibilityValue(store.isNearBottom ? "latest" : "history")
        .environment(\.chatRowActions, rowActions)
        .overlay(alignment: .bottomTrailing) {
            if !store.isNearBottom {
                Button {
                    store.jumpToLatest()
                    macTableCommandHandle.performJump?()
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                        .background(.regularMaterial, in: Circle())
                        .overlay { Circle().strokeBorder(Color.secondary.opacity(0.16)) }
                        .frame(
                            width: ChatInteractionTargetLayout.jumpButtonDimension,
                            height: ChatInteractionTargetLayout.jumpButtonDimension
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation.jump-to-latest")
                .padding(ChatInteractionTargetLayout.jumpButtonOuterPadding)
                .accessibilityLabel(
                    store.unreadCount > 0
                        ? "\(store.unreadCount) new messages. Jump to latest"
                        : "Jump to latest"
                )
            }
        }
        .overlay {
            if isConversationEmpty {
                emptyConversation
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.chatCanvas)
                    .allowsHitTesting(false)
            } else if !isTranscriptAnchored {
                anchoringCurtain
            }
        }
    }

    @ViewBuilder
    private func macRowView(
        _ row: MacTranscriptRow,
        isFirst: Bool,
        isLast: Bool
    ) -> some View {
        let beginsItem: Bool = {
            if case .item(let projection, _, _) = row {
                return projection.isFirstInItem
            }
            return true
        }()
        let endsItem: Bool = {
            if case .item(let projection, let isExpanded, _) = row {
                if case .message(let message) = projection.displayItem,
                   !message.isStreaming,
                   message.hasText {
                    // The copy/timestamp footer is its own following row, so
                    // the final native text tile must not add item spacing.
                    return false
                }
                return projection.isLastInItem
                    || (projection.kind.isDisclosure && !isExpanded)
            }
            return true
        }()
        // Activity rows (tool lines, group summaries, reasoning and diff
        // headers) sit tight like a list; messages keep the roomier spacing.
        let itemSpacing: CGFloat = {
            switch row {
            case .toolGroupHeader, .toolGroupLive, .pendingTurn:
                return ChatTypography.activityLinePadding
            case .item(let projection, _, _):
                return projection.kind.isDisclosure
                    ? ChatTypography.activityLinePadding
                    : 7
            default:
                return 7
            }
        }()
        VStack(alignment: .leading, spacing: 0) {
            switch row {
            case .history:
                historyControl
            case .item(let projection, _, _):
                timelineView(for: projection)
                    .accessibilityIdentifier(
                        projection.isFirstInItem
                            ? "conversation.item.\(projection.sourceItemID)"
                            : "conversation.item.\(projection.sourceItemID).segment.\(projection.id)"
                    )
            case .messageFooter(let footer, _):
                MacMessageFooterView(footer: footer)
                    .accessibilityIdentifier(
                        "conversation.item.\(footer.itemID).footer"
                    )
            case .toolGroupHeader(let header, _):
                ToolGroupHeaderRow(header: header)
                    .accessibilityIdentifier(
                        "conversation.toolgroup.\(header.groupID)"
                    )
            case .toolGroupLive(let live, _):
                ToolGroupLiveRow(headline: live.headline)
                    .accessibilityIdentifier(
                        "conversation.toolgroup.\(live.groupID).live"
                    )
            case .pendingTurn:
                PendingTurnIndicator()
                    .accessibilityIdentifier("conversation.pending-turn")
            case .approval(let approval, _):
                ApprovalCard(
                    approval: approval,
                    store: store,
                    coordinator: coordinator,
                    isReadOnly: isReadOnly
                )
            case .question(let question, _):
                QuestionCard(
                    question: question,
                    store: store,
                    coordinator: coordinator,
                    isReadOnly: isReadOnly
                )
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(.horizontal, horizontalTranscriptPadding)
        .padding(.top, isFirst ? 22 : (beginsItem ? itemSpacing : 0))
        .padding(.bottom, isLast ? 16 : (endsItem ? itemSpacing : 0))
        .frame(maxWidth: .infinity)
        .environment(\.chatRowActions, rowActions)
    }
    #endif

    #if os(iOS)
    private var iosTranscript: some View {
        // The scroller's anchor identities must come from the same filtered
        // entry list the ForEach renders; a hidden noise row or a grouped
        // tool would otherwise become an anchor no view carries and prepends
        // would lose the reading position.
        let renderedItems = self.visibleItems.filter { !$0.isTranscriptNoise }
        let entries = TranscriptEntry.entries(of: renderedItems)
        return ConversationTranscriptScroller(
            isConversationEmpty: store.state.items.isEmpty,
            firstItemID: entries.first?.id,
            contentRevision: transcriptContentRevision,
            isNearBottom: store.isNearBottom,
            unreadCount: store.unreadCount,
            itemExists: { id in
                entries.contains(where: { $0.id == id })
            },
            onNearBottomChange: { store.setNearBottom($0) },
            onAnchoredChange: { _ in },
            onJump: { store.jumpToLatest() }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                earlierContent

                ForEach(entries) { entry in
                    switch entry {
                    case .item(let item):
                        timelineView(for: item)
                            .id(item.id)
                            .accessibilityIdentifier("conversation.item.\(item.id)")
                    case .toolGroup(let group):
                        ToolGroupCard(group: group, store: store)
                            .id(group.id)
                    }
                }

                if showsPendingTurnIndicator {
                    PendingTurnIndicator()
                        .id("pending-turn")
                        .accessibilityIdentifier("conversation.pending-turn")
                }

                ForEach(store.state.approvals) { approval in
                    ApprovalCard(
                        approval: approval,
                        store: store,
                        coordinator: coordinator,
                        isReadOnly: isReadOnly
                    )
                    .id("approval:\(approval.id)")
                }

                ForEach(store.state.questions) { question in
                    QuestionCard(
                        question: question,
                        store: store,
                        coordinator: coordinator,
                        isReadOnly: isReadOnly
                    )
                    .id("question:\(question.id)")
                }
            }
            .scrollTargetLayout()
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, horizontalTranscriptPadding)
            .padding(.top, 22)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .environment(\.chatRowActions, rowActions)
        .onChange(of: store.state.items.first?.id) { oldValue, newValue in
            let items = store.state.items
            if let oldValue, items.contains(where: { $0.id == oldValue }) {
                // A history page prepended: reveal it. Prepends only happen
                // when the user asked for earlier content.
                firstVisibleItemID = newValue
            } else if let firstVisibleItemID,
                      !items.contains(where: { $0.id == firstVisibleItemID }) {
                // The window anchor was trimmed away; fall back to the tail.
                self.firstVisibleItemID = nil
            }
        }
        .overlay {
            if isConversationEmpty {
                emptyConversation
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.chatCanvas)
                    .allowsHitTesting(false)
            }
        }
    }
    #endif

    #if os(macOS)
    /// Covers the transcript between content arriving and the open anchor
    /// landing, so a slow first layout reads as loading instead of a bare
    /// black pane.
    private var anchoringCurtain: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading conversation…")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.chatCanvas)
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading conversation")
    }
    #endif

    /// One control at the top of the transcript: reveal older already-loaded
    /// rows first, and only once everything local is visible offer the
    /// worker-side "Load earlier" page.
    @ViewBuilder
    private var earlierContent: some View {
        if hasHiddenLocalItems {
            HStack {
                Spacer()
                Button("Show earlier messages") {
                    revealEarlierItems()
                }
                .buttonStyle(.plain)
                .chatMinimumInteractionTarget()
                .font(.caption)
                .foregroundStyle(.secondary)
                .controlSize(.small)
                .accessibilityHint("Shows earlier loaded messages without moving your reading position.")
                Spacer()
            }
            .id("history:\(visibleItems.first?.id ?? "window")")
        } else {
            historyControl
        }
    }

    private func revealEarlierItems() {
        let items = store.state.items
        guard let currentFirstID = visibleItems.first?.id,
              let currentIndex = items.firstIndex(where: { $0.id == currentFirstID }) else {
            return
        }
        let newIndex = max(
            items.startIndex,
            currentIndex - Self.transcriptWindowStep
        )
        firstVisibleItemID = items[newIndex].id
    }

    @ViewBuilder
    private var historyControl: some View {
        if store.state.hasOlderHistory {
            HStack {
                Spacer()
                Button {
                    Task {
                        await coordinator.loadOlderHistory()
                    }
                } label: {
                    if store.isLoadingOlderHistory {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(store.state.didTruncateHistory ? "Load earlier content" : "Load earlier")
                    }
                }
                .buttonStyle(.plain)
                .chatMinimumInteractionTarget()
                .font(.caption)
                .foregroundStyle(.secondary)
                .controlSize(.small)
                .disabled(store.isLoadingOlderHistory || isReadOnly)
                .accessibilityHint("Loads up to 50 earlier messages without moving your reading position.")
                Spacer()
            }
            .id("history:\(store.state.oldestItemID ?? "start")")
        }
    }

    @ViewBuilder
    private func timelineView(for item: ConversationItem) -> some View {
        switch item {
        case .message(let message):
            ChatMessageView(message: message)
        case .reasoning(let reasoning):
            ReasoningCard(
                reasoning: reasoning,
                isExpanded: store.expandedItemIDs.contains(reasoning.id)
            )
        case .tool(let tool):
            ToolActivityCard(
                tool: tool,
                isExpanded: store.expandedItemIDs.contains(tool.id),
                copiedItemID: store.copiedItemID
            )
        case .diff(let diff):
            DiffCard(
                diff: diff,
                isExpanded: store.expandedItemIDs.contains(diff.id)
            )
        case .plan(let plan):
            PlanCard(plan: plan)
        case .generic(let generic):
            GenericActivityCard(
                item: generic,
                isExpanded: store.expandedItemIDs.contains(generic.id)
            )
        }
    }

    #if os(macOS)
    @ViewBuilder
    private func timelineView(for projection: TranscriptRowProjection) -> some View {
        switch projection.displayItem {
        case .message(let message):
            ChatMessageView(
                message: message,
                segment: projection,
                showsFooter: false
            )
        case .reasoning(let reasoning):
            ReasoningCard(
                reasoning: reasoning,
                isExpanded: store.expandedItemIDs.contains(reasoning.id),
                segment: projection
            )
        case .tool(let tool):
            ToolActivityCard(
                tool: tool,
                isExpanded: store.expandedItemIDs.contains(tool.id),
                copiedItemID: store.copiedItemID,
                segment: projection
            )
        case .diff(let diff):
            DiffCard(
                diff: diff,
                isExpanded: store.expandedItemIDs.contains(diff.id),
                segment: projection
            )
        case .plan(let plan):
            PlanCard(plan: plan, segment: projection)
        case .generic(let generic):
            GenericActivityCard(
                item: generic,
                isExpanded: store.expandedItemIDs.contains(generic.id),
                segment: projection
            )
        }
    }
    #endif

    private var emptyConversation: some View {
        VStack(spacing: 8) {
            if isAwaitingInitialSnapshot {
                ProgressView()
                    .controlSize(.small)
                Text(
                    coordinator.identity.providerThreadID == nil
                        ? "Starting conversation…"
                        : "Loading conversation…"
                )
                    .font(.headline)
                Text("Retrieving the latest history from your worker")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(isReadOnly ? "No messages" : "What can I help you build?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 52)
        .accessibilityElement(children: .combine)
    }

    private var isConversationEmpty: Bool {
        store.state.items.isEmpty
            && store.state.approvals.isEmpty
            && store.state.questions.isEmpty
    }

    private var isAwaitingInitialSnapshot: Bool {
        switch store.state.connectionState {
        case .failed, .offlineAgentRunning, .unsupportedWorker, .stopped:
            return false
        case .connecting:
            // The worker admits attaches while the provider is still
            // resuming; an empty snapshot in this state is a placeholder
            // for history that is still streaming in, not an empty
            // conversation.
            return true
        default:
            return store.lastAppliedSequence == 0
        }
    }

    /// Shown when cached content is on screen but the live attach hasn't
    /// caught up yet, so instant-from-disk transcripts are honest about
    /// possibly trailing the worker.
    @ViewBuilder
    private var syncingNotice: some View {
        if !store.state.items.isEmpty,
           store.state.connectionState == .connecting {
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Syncing latest…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 10)
            .allowsHitTesting(false)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var compactNotice: some View {
        if let notice = compactNoticeContent {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle")
                Text(notice.message)
                    .lineLimit(2)
                if notice.canRetry {
                    Button("Retry") {
                        coordinator.retry()
                    }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                if store.state.lastErrorMessage != nil {
                    Button {
                        store.clearLastError()
                    } label: {
                        Image(systemName: "xmark")
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, horizontalTranscriptPadding)
            .padding(.vertical, 2)
        }
    }

    private var composer: some View {
        ConversationComposer(
            store: store,
            coordinator: coordinator,
            attachmentActions: attachmentActions
        )
            .frame(maxWidth: 760)
            .padding(.horizontal, horizontalTranscriptPadding)
            .padding(.top, 6)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
    }

    private var horizontalTranscriptPadding: CGFloat {
        #if os(iOS)
        16
        #else
        28
        #endif
    }

    private var compactNoticeContent: (message: String, canRetry: Bool)? {
        if let message = store.state.lastErrorMessage {
            let canRetry = store.state.connectionState == .failed
                || store.state.connectionState == .offlineAgentRunning
                || store.state.connectionState == .unsupportedWorker
            return (message, canRetry)
        }
        switch store.state.connectionState {
        case .offlineAgentRunning:
            return ("Connection interrupted.", true)
        case .unsupportedWorker:
            return ("Native chat is unavailable on this worker.", true)
        case .failed:
            return ("Unable to connect.", true)
        case .stopped:
            return ("Session ended.", false)
        default:
            return nil
        }
    }

}

/// Owns every piece of scroll-tracking state for the transcript, isolated in
/// its own view so scroll-driven invalidations (the ScrollPosition binding
/// updates on every user scroll) re-evaluate only this thin container. The
/// transcript content is passed in as a stored value, so its rows and their
/// environment are untouched by scroll frames.
#if os(iOS)
private struct ConversationTranscriptScroller<Content: View>: View {
    let isConversationEmpty: Bool
    let firstItemID: String?
    let contentRevision: Int
    let isNearBottom: Bool
    let unreadCount: Int
    let itemExists: (String) -> Bool
    let onNearBottomChange: (Bool) -> Void
    let onAnchoredChange: (Bool) -> Void
    let onJump: () -> Void
    let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrollController: ConversationScrollController
    @State private var scrollPosition = ScrollPosition()
    @State private var scratch = ConversationScrollScratch()

    init(
        isConversationEmpty: Bool,
        firstItemID: String?,
        contentRevision: Int,
        isNearBottom: Bool,
        unreadCount: Int,
        itemExists: @escaping (String) -> Bool,
        onNearBottomChange: @escaping (Bool) -> Void,
        onAnchoredChange: @escaping (Bool) -> Void = { _ in },
        onJump: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isConversationEmpty = isConversationEmpty
        self.firstItemID = firstItemID
        self.contentRevision = contentRevision
        self.isNearBottom = isNearBottom
        self.unreadCount = unreadCount
        self.itemExists = itemExists
        self.onNearBottomChange = onNearBottomChange
        self.onAnchoredChange = onAnchoredChange
        self.onJump = onJump
        self.content = content()
        _scrollController = State(
            wrappedValue: ConversationScrollController(
                startsAnchored: isConversationEmpty
            )
        )
    }

    var body: some View {
        iosBody
    }

    private var iosBody: some View {
        ScrollView {
            content
        }
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: ConversationScrollGeometrySample.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height
                - geometry.visibleRect.maxY
            return ConversationScrollGeometrySample(
                isAtBottom: distanceFromBottom
                    <= ConversationScrollController.atBottomTolerance,
                isNearBottom: distanceFromBottom <= 180,
                contentHeightBucket: Int((geometry.contentSize.height / 8).rounded())
            )
        } action: { _, sample in
            handleGeometryChange(sample)
        }
        .onScrollPhaseChange { oldPhase, newPhase, context in
            handleScrollPhaseChange(from: oldPhase, to: newPhase, context: context)
        }
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("conversation.transcript")
        .accessibilityValue(scrollController.accessibilityValue)
        .task(id: isAnchoringContent) {
            // Failsafe: never leave the transcript hidden if geometry never
            // confirms the bottom while anchoring.
            guard isAnchoringContent else { return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            scrollController.completeAnchor()
        }
        .onChange(of: isConversationEmpty) { wasEmpty, isEmpty in
            if wasEmpty, !isEmpty {
                execute(scrollController.contentLoaded())
            }
        }
        .onChange(of: firstItemID) { oldValue, newValue in
            preserveReadingPositionAfterPrepend(
                oldFirstID: oldValue,
                newFirstID: newValue
            )
        }
        .overlay(alignment: .bottomTrailing) {
            jumpToLatestOverlay
        }
        .overlay {
            if isAnchoringContent {
                // Curtain while freshly loaded content anchors at the latest
                // item. Conditional so the settled transcript carries no
                // extra hit-testing or compositing layer.
                Color.chatCanvas
                    .allowsHitTesting(false)
            }
        }
    }
    @ViewBuilder
    private func jumpButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.16))
                }
                .frame(
                    width: ChatInteractionTargetLayout.jumpButtonDimension,
                    height: ChatInteractionTargetLayout.jumpButtonDimension
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("conversation.jump-to-latest")
        .padding(ChatInteractionTargetLayout.jumpButtonOuterPadding)
        .accessibilityLabel(
            unreadCount > 0
                ? "\(unreadCount) new messages. Jump to latest"
                : "Jump to latest"
        )
        .accessibilityHint("Moves to the newest conversation update.")
        .transition(.scale.combined(with: .opacity))
    }

    private var jumpToLatestOverlay: some View {
        ZStack(alignment: .bottomTrailing) {
            if !isNearBottom {
                jumpButton {
                    onJump()
                    execute(scrollController.jumpRequested())
                }
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.16),
            value: isNearBottom
        )
    }

    private var isAnchoringContent: Bool {
        scrollController.isAnchoring && !isConversationEmpty
    }

    private func handleGeometryChange(_ sample: ConversationScrollGeometrySample) {
        scratch.lastSample = sample
        if isNearBottom != sample.isNearBottom {
            onNearBottomChange(sample.isNearBottom)
        }
        execute(scrollController.geometryChanged(isAtBottom: sample.isAtBottom))
    }

    private func handleScrollPhaseChange(
        from oldPhase: ScrollPhase,
        to newPhase: ScrollPhase,
        context: ScrollPhaseChangeContext
    ) {
        let distance = context.geometry.contentSize.height
            - context.geometry.visibleRect.maxY
        switch newPhase {
        case .tracking, .interacting, .decelerating:
            scrollController.userScrollBegan()
        case .idle:
            if oldPhase == .animating {
                execute(scrollController.animationEnded(distanceFromBottom: distance))
            } else {
                execute(scrollController.userScrollEnded(distanceFromBottom: distance))
            }
        case .animating:
            break
        @unknown default:
            break
        }
    }

    private func execute(_ command: ConversationPinCommand?) {
        guard let command else { return }
        conversationScrollLogger.debug(
            "Pin \(String(describing: command), privacy: .public) in state \(String(describing: scrollController.state), privacy: .public)"
        )
        switch command {
        case .instant:
            pinToBottomInstantly()
        case .animatedSettle, .animatedJump:
            if reduceMotion {
                pinToBottomInstantly()
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    scrollPosition.scrollTo(edge: .bottom)
                }
            }
        }
    }

    private func pinToBottomInstantly() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(edge: .bottom)
        }
    }

    /// After a history page prepends above the viewport, keep the row the
    /// user was reading in place by re-anchoring the previous first item to
    /// the top. Only applies to real prepends while the user owns the
    /// viewport; a memory trim changes the first ID without keeping the old
    /// one, and stays untouched.
    private func preserveReadingPositionAfterPrepend(
        oldFirstID: String?,
        newFirstID: String?
    ) {
        guard let oldFirstID,
              let newFirstID,
              oldFirstID != newFirstID,
              scrollController.state == .browsing,
              itemExists(oldFirstID) else {
            return
        }
        conversationScrollLogger.debug("Prepend position preserved")
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollPosition.scrollTo(id: oldFirstID, anchor: .top)
        }
    }
}
#endif

struct ChatMessageView: View {
    let message: ChatMessage
    var segment: TranscriptRowProjection?
    var showsFooter: Bool

    init(
        message: ChatMessage,
        segment: TranscriptRowProjection? = nil,
        showsFooter: Bool = true
    ) {
        self.message = message
        self.segment = segment
        self.showsFooter = showsFooter
    }

    @Environment(\.chatRowActions) private var actions
    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 7) {
                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
                    ForEach(message.contents) { content in
                        contentView(content)
                    }
                    if message.isStreaming {
                        StreamingIndicator()
                    }
                }
                .padding(.horizontal, message.role == .user ? 12 : 0)
                .padding(.top, messageTopPadding)
                .padding(.bottom, messageBottomPadding)
                .background {
                    if message.role == .user {
                        UnevenRoundedRectangle(
                            cornerRadii: RectangleCornerRadii(
                                topLeading: isFirstSegment ? 16 : 0,
                                bottomLeading: isLastSegment ? 16 : 0,
                                bottomTrailing: isLastSegment ? 16 : 0,
                                topTrailing: isFirstSegment ? 16 : 0
                            ),
                            style: .continuous
                        )
                            .fill(Color.secondary.opacity(0.12))
                    }
                }

                if showsFooter,
                   isLastSegment,
                   !message.isStreaming,
                   message.hasText {
                    messageFooter
                }
            }
            .frame(maxWidth: message.role == .user ? 640 : .infinity, alignment: message.role == .user ? .trailing : .leading)

            if message.role != .user {
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message.role == .user ? "You" : "Assistant")
    }

    private var isFirstSegment: Bool { segment?.isFirstInItem ?? true }
    private var isLastSegment: Bool { segment?.isLastInItem ?? true }

    private var messageTopPadding: CGFloat {
        guard message.role == .user else { return 0 }
        return isFirstSegment ? 12 : (segment?.isFirstInSection == true ? 10 : 0)
    }

    private var messageBottomPadding: CGFloat {
        guard message.role == .user else { return 0 }
        return isLastSegment ? 12 : 0
    }

    private var messageFooter: some View {
        HStack(spacing: 9) {
            Button {
                actions.copyMessage(itemID: message.id, fallback: message.text)
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .chatMinimumInteractionTarget(includesWidth: true)
            .accessibilityLabel(didCopy ? "Message copied" : "Copy message")

            if let date = ChatTimestamp.date(
                milliseconds: message.occurredAt,
                fallbackUUIDv7s: [message.turnID, message.id]
            ) {
                Text(ChatTimestamp.label(for: date))
                    .accessibilityLabel(date.formatted(date: .complete, time: .shortened))
            }
        }
        .font(ChatTypography.timestamp)
        .foregroundStyle(.secondary)
        .padding(.horizontal, message.role == .user ? 4 : 0)
        .opacity(showsMessageFooter ? 1 : 0)
        .allowsHitTesting(showsMessageFooter)
    }

    private var showsMessageFooter: Bool {
        true
    }

    @ViewBuilder
    private func contentView(_ content: MessageContent) -> some View {
        switch content.kind {
        case .code:
            CodeBlockView(
                id: content.id,
                code: content.text,
                language: content.language,
                isStreaming: !content.isComplete,
                showsCopyButton: false
            )
        case .imagePlaceholder:
            Label(content.text, systemImage: "photo")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .plainText where message.role == .user:
            Text(content.text)
                .transcriptTextSelection()
                .fixedSize(horizontal: false, vertical: true)
        case .generic where message.role == .user:
            Text(content.text)
                .transcriptTextSelection()
                .fixedSize(horizontal: false, vertical: true)
        default:
            RichMarkdownView(
                text: content.text,
                exactFallbackText: segment?.sourceText,
                isStreaming: !content.isComplete
            )
        }
    }
}

#if os(macOS)
private struct MacMessageFooterView: View {
    let footer: MacMessageFooter

    @Environment(\.chatRowActions) private var actions
    @State private var didCopy = false

    var body: some View {
        HStack(spacing: 0) {
            if footer.role == .user {
                Spacer(minLength: 44)
            }
            HStack(spacing: 9) {
                Button {
                    actions.copyMessage(itemID: footer.itemID, fallback: "")
                    didCopy = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }
                } label: {
                    Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .chatMinimumInteractionTarget(includesWidth: true)
                .accessibilityLabel(didCopy ? "Message copied" : "Copy message")

                if let date = ChatTimestamp.date(
                    milliseconds: footer.occurredAt,
                    fallbackUUIDv7s: [footer.turnID, footer.itemID]
                ) {
                    Text(ChatTimestamp.label(for: date))
                        .accessibilityLabel(
                            date.formatted(date: .complete, time: .shortened)
                        )
                }
            }
            .padding(.horizontal, footer.role == .user ? 4 : 0)
            if footer.role != .user {
                Spacer(minLength: 0)
            }
        }
        .font(ChatTypography.timestamp)
        .foregroundStyle(.secondary)
    }
}
#endif

enum ChatTimestamp {
    static func date(
        milliseconds: Int64?,
        fallbackUUIDv7s: [String?] = []
    ) -> Date? {
        let resolvedMilliseconds = milliseconds
            ?? fallbackUUIDv7s.lazy.compactMap(uuidV7Milliseconds).first
        guard let resolvedMilliseconds, resolvedMilliseconds >= 0 else {
            return nil
        }
        return Date(
            timeIntervalSince1970: TimeInterval(resolvedMilliseconds) / 1_000
        )
    }

    private static func uuidV7Milliseconds(_ value: String?) -> Int64? {
        guard let value, let uuid = UUID(uuidString: value) else { return nil }
        let bytes = uuid.uuid
        guard bytes.6 >> 4 == 7 else { return nil }
        return Int64(bytes.0) << 40
            | Int64(bytes.1) << 32
            | Int64(bytes.2) << 24
            | Int64(bytes.3) << 16
            | Int64(bytes.4) << 8
            | Int64(bytes.5)
    }

    static func label(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let time = date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
        guard !calendar.isDate(date, inSameDayAs: now) else {
            return time
        }
        let weekday = date.formatted(
            Date.FormatStyle(
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
                .weekday(.wide)
        )
        return "\(weekday) \(time)"
    }
}

private struct StreamingIndicator: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Working")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Assistant is responding")
    }
}

/// Shown at the transcript tail while a turn is running but nothing is
/// visibly streaming yet — the model is thinking (Claude emits no events
/// during extended thinking) or between tool results and its next text.
struct PendingTurnIndicator: View {
    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16)
            Text("Thinking…")
                .font(ChatTypography.activityLine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(minHeight: ChatTypography.activityLineHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Assistant is thinking")
    }

    /// The indicator fills only the gaps where no transcript row shows
    /// activity: an active turn whose tail item is neither streaming text or
    /// reasoning nor a running tool. A completed assistant message at the
    /// tail means the reply just landed and the turn is sealing — showing
    /// "Thinking…" there would flash on every turn end.
    static func showsPendingTurn(
        turnState: TurnState,
        lastItem: ConversationItem?
    ) -> Bool {
        guard turnState == .running else { return false }
        switch lastItem {
        case .message(let message):
            return message.role == .user && !message.isStreaming
        case .reasoning(let reasoning):
            return !reasoning.isStreaming
        case .tool(let tool):
            return tool.status != .running && tool.status != .pending
        case .diff, .plan, .generic, nil:
            return true
        }
    }
}

private struct ReasoningCard: View {
    let reasoning: ChatReasoning
    let isExpanded: Bool
    var segment: TranscriptRowProjection?

    init(
        reasoning: ChatReasoning,
        isExpanded: Bool,
        segment: TranscriptRowProjection? = nil
    ) {
        self.reasoning = reasoning
        self.isExpanded = isExpanded
        self.segment = segment
    }

    @Environment(\.chatRowActions) private var actions

    private var displayText: String? {
        reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : reasoning.text
    }

    @ViewBuilder
    var body: some View {
        if segment?.isFirstInItem == false {
            if isExpanded, let displayText {
                reasoningText(displayText)
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else if let displayText {
            DisclosureCard(
                title: reasoning.isStreaming ? "Thinking…" : "Reasoning summary",
                symbol: "brain.head.profile",
                statusColor: reasoning.isStreaming ? .blue : .secondary,
                isExpanded: isExpanded,
                toggle: { actions.toggleExpanded(itemID: reasoning.id) }
            ) {
                reasoningText(displayText)
            }
        } else if reasoning.isStreaming {
            HStack(spacing: 7) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: 16)
                Text("Thinking…")
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minHeight: ChatTypography.activityLineHeight)
            .accessibilityElement(children: .combine)
        }
    }

    private func reasoningText(_ text: String) -> some View {
        Text(text)
            .font(ChatTypography.activityLine)
            .foregroundStyle(.secondary)
            .transcriptTextSelection()
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ToolActivityCard: View {
    let tool: ToolActivity
    let isExpanded: Bool
    let copiedItemID: String?
    var segment: TranscriptRowProjection?

    init(
        tool: ToolActivity,
        isExpanded: Bool,
        copiedItemID: String?,
        segment: TranscriptRowProjection? = nil
    ) {
        self.tool = tool
        self.isExpanded = isExpanded
        self.copiedItemID = copiedItemID
        self.segment = segment
    }

    @Environment(\.chatRowActions) private var actions

    @ViewBuilder
    var body: some View {
        if segment?.section == .toolTitle,
           segment?.isFirstInItem == false,
           let metadataText = segment?.metadataText {
            if isExpanded {
                Text(verbatim: metadataText)
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.secondary)
                    .transcriptTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else if segment?.isFirstInItem == false {
            if isExpanded {
                toolContent
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else {
            compactLine
            if isExpanded, segment?.section != .toolTitle {
                toolContent
                    .padding(.leading, 23)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }

    /// One fixed-height line: status glyph, single-line headline, inline
    /// chevron. Status flips and streaming never change its height.
    private var compactLine: some View {
        Button {
            actions.toggleExpanded(itemID: tool.id)
        } label: {
            HStack(spacing: 7) {
                if tool.status == .running || tool.status == .pending {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 16)
                } else {
                    Image(systemName: tool.kind.symbolName)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .frame(width: 16)
                }
                Text(headline)
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
                Spacer(minLength: 0)
            }
            .frame(minHeight: ChatTypography.activityLineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMinimumInteractionTarget()
        .accessibilityLabel(
            "\(headline), \(isExpanded ? "expanded" : "collapsed")"
        )
        .accessibilityHint(isExpanded ? "Collapses details." : "Expands details.")
    }

    private var headline: String {
        tool.composedHeadline(compactLine: segment?.compactLine)
    }

    @ViewBuilder
    private var toolContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let input = tool.input, !input.isEmpty {
                ToolSection(
                    title: "Input",
                    content: input,
                    itemID: "\(tool.id):input",
                    copiedItemID: copiedItemID,
                    showsHeader: segment?.isFirstInSection ?? true,
                    renderID: segment?.id
                )
            }
            if let output = tool.output, !output.isEmpty {
                ToolSection(
                    title: "Output",
                    content: output,
                    itemID: "\(tool.id):output",
                    copiedItemID: copiedItemID,
                    showsHeader: segment?.isFirstInSection ?? true,
                    renderID: segment?.id
                )
            }
            if let error = tool.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.red)
                    .transcriptTextSelection()
            }
            if tool.input == nil, tool.output == nil, tool.errorMessage == nil {
                Text(tool.status == .running ? "Waiting for output…" : "No additional output")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch tool.status {
        case .running, .pending: .secondary
        case .completed: .secondary
        case .failed: .red
        case .cancelled: .orange
        }
    }
}

/// Collapsed summary line for a run of tool calls: "Read files, ran
/// commands". Hosted on both platforms; a fixed single-line height keeps the
/// transcript still while member tools stream underneath.
struct ToolGroupHeaderRow: View {
    let header: ToolGroupHeaderModel

    @Environment(\.chatRowActions) private var actions

    var body: some View {
        Button {
            actions.toggleExpanded(itemID: header.groupID)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: header.symbol)
                    .font(.caption)
                    .foregroundStyle(header.hasFailure ? Color.red : Color.secondary)
                    .frame(width: 16)
                Text(header.summary)
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(header.isExpanded ? .degrees(90) : .zero)
                Spacer(minLength: 0)
            }
            .frame(minHeight: ChatTypography.activityLineHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .chatMinimumInteractionTarget()
        .accessibilityLabel(
            "\(header.summary), \(header.isExpanded ? "expanded" : "collapsed")"
        )
        .accessibilityHint(
            header.isExpanded ? "Collapses the tool list." : "Expands the tool list."
        )
    }
}

/// The live line under a collapsed tool group: a spinner and the running
/// tool's headline. Text swaps in place; the row height never changes.
struct ToolGroupLiveRow: View {
    let headline: String

    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16)
            Text(headline)
                .font(ChatTypography.activityLine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(minHeight: ChatTypography.activityLineHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(headline)
    }
}

/// iOS renders a tool group as one stacked view; macOS projects the same
/// model into individual table rows.
struct ToolGroupCard: View {
    let group: ToolGroup
    @ObservedObject var store: ConversationStore

    var body: some View {
        let isExpanded = store.expandedItemIDs.contains(group.id)
        VStack(alignment: .leading, spacing: 4) {
            ToolGroupHeaderRow(header: group.headerModel(isExpanded: isExpanded))
                .accessibilityIdentifier("conversation.toolgroup.\(group.id)")
            if isExpanded {
                ForEach(group.items, id: \.id) { item in
                    if case .tool(let tool) = item {
                        ToolActivityCard(
                            tool: tool,
                            isExpanded: store.expandedItemIDs.contains(tool.id),
                            copiedItemID: store.copiedItemID
                        )
                        .accessibilityIdentifier("conversation.item.\(item.id)")
                    }
                }
            } else if let runningTool = group.runningTool {
                ToolGroupLiveRow(headline: runningTool.compactHeadline)
            }
        }
    }
}

private struct ToolSection: View {
    let title: String
    let content: String
    let itemID: String
    let copiedItemID: String?
    var showsHeader = true
    var renderID: String?

    @Environment(\.chatRowActions) private var actions

    private var isCopied: Bool { copiedItemID == itemID }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsHeader {
                HStack {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        actions.copyToolSection(identifier: itemID, fallback: content)
                        actions.markCopied(itemID: itemID)
                    } label: {
                        Label(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .chatMinimumInteractionTarget(includesWidth: true)
                    .accessibilityLabel(isCopied ? "\(title) copied" : "Copy \(title.lowercased())")
                }
            }
            // Plain monospaced text, identical to the native TextKit tiles
            // that replace these rows once the tool completes — the swap must
            // not change layout. Boxed code chrome would re-measure taller.
            Text(verbatim: content)
                .font(ChatTypography.monospacedDetail)
                .transcriptTextSelection()
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DiffCard: View {
    let diff: ChatDiff
    let isExpanded: Bool
    var segment: TranscriptRowProjection?

    init(
        diff: ChatDiff,
        isExpanded: Bool,
        segment: TranscriptRowProjection? = nil
    ) {
        self.diff = diff
        self.isExpanded = isExpanded
        self.segment = segment
    }

    @Environment(\.chatRowActions) private var actions

    @ViewBuilder
    var body: some View {
        if segment?.section == .diffPath,
           segment?.isFirstInItem == false,
           let metadataText = segment?.metadataText {
            if isExpanded {
                Text(verbatim: metadataText)
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.secondary)
                    .transcriptTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else if segment?.isFirstInItem == false {
            if isExpanded {
                DiffTextView(diff: diff.unifiedDiff)
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else {
            DisclosureCard(
                title: diff.path ?? "File changes",
                subtitle: diff.isTruncated ? "Source truncated" : nil,
                symbol: "doc.badge.gearshape",
                statusColor: .blue,
                isExpanded: isExpanded,
                toggle: { actions.toggleExpanded(itemID: diff.id) }
            ) {
                if segment?.section != .diffPath {
                    DiffTextView(diff: diff.unifiedDiff)
                }
            }
        }
    }
}

private struct DiffTextView: View {
    private struct Line: Identifiable {
        enum Kind {
            case addition
            case removal
            case context
        }

        let id: Int
        let text: String
        let kind: Kind
    }

    private let lines: [Line]
    #if os(macOS)
    private let attributedText: AttributedString
    #endif

    init(diff: String) {
        let lines = diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, substring in
                let text = String(substring)
                let kind: Line.Kind
                if text.hasPrefix("+"), !text.hasPrefix("+++") {
                    kind = .addition
                } else if text.hasPrefix("-"), !text.hasPrefix("---") {
                    kind = .removal
                } else {
                    kind = .context
                }
                return Line(id: index, text: text, kind: kind)
            }
        self.lines = lines
        #if os(macOS)
        var attributed = AttributedString()
        if lines.count > 32 {
            // A color/background run per source line makes TextKit's cold
            // fitting pass exceed a scroll frame for newline-dense diffs.
            // Keep the exact selectable text and trade decoration for bounded
            // layout complexity on those pathological tiles.
            attributed = AttributedString(diff)
        } else {
            for (index, line) in lines.enumerated() {
                var value = AttributedString(line.text)
                switch line.kind {
                case .addition:
                    value.foregroundColor = .green
                    value.backgroundColor = .green.opacity(0.1)
                case .removal:
                    value.foregroundColor = .red
                    value.backgroundColor = .red.opacity(0.1)
                case .context:
                    value.foregroundColor = .primary
                }
                attributed.append(value)
                if index < lines.count - 1 {
                    attributed.append(AttributedString("\n"))
                }
            }
        }
        attributedText = attributed
        #endif
    }

    var body: some View {
        // On macOS diff lines wrap rather than nesting a live NSScrollView
        // per diff card inside the transcript.
        #if os(macOS)
        Text(attributedText)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transcriptTextSelection()
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        #else
        ScrollView(.horizontal) {
            diffLines
                .fixedSize(horizontal: true, vertical: false)
        }
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        #endif
    }

    private var diffLines: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines) { line in
                Text(verbatim: line.text)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(lineColor(line.kind))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(lineBackground(line.kind))
            }
        }
        .transcriptTextSelection()
    }

    private func lineColor(_ kind: Line.Kind) -> Color {
        switch kind {
        case .addition: .green
        case .removal: .red
        case .context: .primary
        }
    }

    private func lineBackground(_ kind: Line.Kind) -> Color {
        switch kind {
        case .addition: .green.opacity(0.1)
        case .removal: .red.opacity(0.1)
        case .context: .clear
        }
    }
}

private struct PlanCard: View {
    let plan: ChatPlan
    var segment: TranscriptRowProjection?

    init(plan: ChatPlan, segment: TranscriptRowProjection? = nil) {
        self.plan = plan
        self.segment = segment
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if segment == nil || segment?.section == .planTitle {
                Text(plan.title ?? "Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .transcriptTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
            } else if segment?.isFirstInItem == true {
                Text("Plan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.steps) { step in
                Label(
                    step.title,
                    systemImage: step.isCompleted ? "checkmark.circle.fill" : "circle"
                )
                .font(.callout)
                .foregroundStyle(step.isCompleted ? .secondary : .primary)
                .accessibilityLabel("\(step.isCompleted ? "Completed" : "Pending"): \(step.title)")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct GenericActivityCard: View {
    let item: ChatGenericItem
    let isExpanded: Bool
    var segment: TranscriptRowProjection?

    init(
        item: ChatGenericItem,
        isExpanded: Bool,
        segment: TranscriptRowProjection? = nil
    ) {
        self.item = item
        self.isExpanded = isExpanded
        self.segment = segment
    }

    @Environment(\.chatRowActions) private var actions

    @ViewBuilder
    var body: some View {
        if (segment?.section == .genericTitle
                || segment?.section == .genericType),
           segment?.isFirstInItem == false,
           let metadataText = segment?.metadataText {
            if isExpanded {
                Text(verbatim: metadataText)
                    .font(ChatTypography.activityLine)
                    .foregroundStyle(.secondary)
                    .transcriptTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else if segment?.isFirstInItem == false {
            if isExpanded {
                detailContent
                    .padding(.leading, 23)
                    .padding(.bottom, 4)
            }
        } else {
            DisclosureCard(
                title: item.title,
                subtitle: item.type,
                symbol: "square.stack.3d.up",
                statusColor: .secondary,
                isExpanded: isExpanded,
                toggle: { actions.toggleExpanded(itemID: item.id) }
            ) {
                if segment?.section != .genericTitle
                    && segment?.section != .genericType {
                    detailContent
                }
            }
        }
    }

    @ViewBuilder
    private var detailContent: some View {
            if let detail = item.detail {
                Text(detail)
                    .font(ChatTypography.monospacedDetail)
                    .transcriptTextSelection()
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No additional details")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
    }
}

private struct DisclosureCard<Content: View>: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let statusColor: Color
    let isExpanded: Bool
    let toggle: () -> Void
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        statusColor: Color,
        isExpanded: Bool,
        toggle: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.statusColor = statusColor
        self.isExpanded = isExpanded
        self.toggle = toggle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 7) {
                    Image(systemName: symbol)
                        .foregroundStyle(statusColor)
                        .font(.caption)
                        .frame(width: 16)
                    Text(title)
                        .font(ChatTypography.activityLine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: ChatTypography.activityLineHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .chatMinimumInteractionTarget()
            .accessibilityLabel("\(title), \(isExpanded ? "expanded" : "collapsed")")
            .accessibilityHint(isExpanded ? "Collapses details." : "Expands details.")

            if isExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    content()
                }
                .padding(.leading, 23)
                .padding(.top, 6)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
    }
}

private struct ApprovalCard: View {
    let approval: ApprovalRequest
    @ObservedObject var store: ConversationStore
    let coordinator: ConversationCoordinator
    let isReadOnly: Bool

    private var isResponding: Bool {
        store.respondingInteractionIDs.contains(approval.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: approval.status == .pending ? "hand.raised.fill" : "checkmark.shield")
                    .foregroundStyle(approval.status == .pending ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(approval.title)
                        .font(.headline)
                    Text(approvalStatusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let reason = approval.reason {
                Text(reason)
                    .font(.callout)
                    .transcriptTextSelection()
            }
            if let context = approval.context {
                CodeBlockView(
                    id: "\(approval.id):context",
                    code: context,
                    language: nil,
                    isStreaming: false
                )
            }

            if approval.status == .pending, !isReadOnly {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        ForEach(approval.decisions) { decision in
                            approvalButton(for: decision)
                        }
                    }

                    VStack(spacing: 8) {
                        ForEach(approval.decisions) { decision in
                            approvalButton(for: decision)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.orange.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.24))
        }
        .accessibilityElement(children: .contain)
        .onDisappear {
            store.clearDestructiveApprovalConfirmation(approvalID: approval.id)
        }
    }

    @ViewBuilder
    private func approvalButton(for decision: ApprovalDecision) -> some View {
        Button {
            Task {
                await coordinator.respond(
                    to: approval.id,
                    decisionID: decision.id
                )
            }
        } label: {
            if isResponding {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(buttonLabel(for: decision))
            }
        }
        .buttonStyle(.borderedProminent)
        .chatMinimumInteractionTarget()
        .tint(decision.id.lowercased().contains("deny") ? Color.red : Color.accentColor)
        .disabled(isResponding)
        .accessibilityHint(
            decision.isDestructive
                ? "Requires a second confirmation."
                : "Responds once to this approval request."
        )
    }

    private var approvalStatusLabel: String {
        switch approval.status {
        case .pending: "Your approval is required"
        case .approved: "Approved"
        case .denied: "Denied"
        case .expired: "Request expired"
        }
    }

    private func buttonLabel(for decision: ApprovalDecision) -> String {
        if decision.isDestructive,
           store.pendingDestructiveApprovalConfirmation
            == DestructiveApprovalConfirmation(
                approvalID: approval.id,
                decisionID: decision.id
            ) {
            return "Confirm \(decision.label)"
        }
        return decision.label
    }
}

enum ComposerReturnAction: Equatable {
    case insertNewline
    case send
    case ignore
}

enum ComposerInputPolicy {
    static func returnAction(
        commandKeyPressed: Bool,
        canSend: Bool
    ) -> ComposerReturnAction {
        guard commandKeyPressed else { return .insertNewline }
        return canSend ? .send : .ignore
    }
}

enum ComposerEscapeAction: Equatable {
    case ignored
    case armed
    case interrupt
}

struct ComposerEscapePolicy: Equatable, Sendable {
    let maximumInterval: TimeInterval
    let minimumInterval: TimeInterval

    private var trackedTurnID: String?
    private var firstEscapeTimestamp: TimeInterval?
    private var lastInterruptTimestamp: TimeInterval?

    init(
        maximumInterval: TimeInterval = 0.8,
        minimumInterval: TimeInterval = 0.05
    ) {
        self.maximumInterval = maximumInterval
        self.minimumInterval = minimumInterval
    }

    mutating func action(
        activeTurnID: String?,
        timestamp: TimeInterval,
        isRepeat: Bool
    ) -> ComposerEscapeAction {
        guard let activeTurnID, timestamp.isFinite else {
            reset()
            return .ignored
        }

        if trackedTurnID != activeTurnID {
            trackedTurnID = activeTurnID
            firstEscapeTimestamp = nil
            lastInterruptTimestamp = nil
        }

        guard !isRepeat else {
            return .ignored
        }

        if let lastInterruptTimestamp {
            let interval = timestamp - lastInterruptTimestamp
            if interval >= 0, interval < minimumInterval {
                return .ignored
            }
            self.lastInterruptTimestamp = nil
        }

        guard let firstEscapeTimestamp else {
            self.firstEscapeTimestamp = timestamp
            return .armed
        }

        let interval = timestamp - firstEscapeTimestamp
        if interval < 0 || interval > maximumInterval {
            self.firstEscapeTimestamp = timestamp
            return .armed
        }
        guard interval >= minimumInterval else {
            return .ignored
        }

        self.firstEscapeTimestamp = nil
        lastInterruptTimestamp = timestamp
        return .interrupt
    }

    private mutating func reset() {
        trackedTurnID = nil
        firstEscapeTimestamp = nil
        lastInterruptTimestamp = nil
    }
}

enum ComposerEscapeRoute: Equatable {
    case passThrough
    case consume
    case interrupt
}

struct ComposerEscapeRouter: Equatable, Sendable {
    private var policy = ComposerEscapePolicy()

    mutating func route(
        activeTurnID: String?,
        timestamp: TimeInterval,
        isRepeat: Bool
    ) -> ComposerEscapeRoute {
        guard activeTurnID != nil else {
            _ = policy.action(
                activeTurnID: nil,
                timestamp: timestamp,
                isRepeat: isRepeat
            )
            return .passThrough
        }

        switch policy.action(
            activeTurnID: activeTurnID,
            timestamp: timestamp,
            isRepeat: isRepeat
        ) {
        case .ignored, .armed:
            return .consume
        case .interrupt:
            return .interrupt
        }
    }
}

enum QuestionResponsePresentation {
    static func canSubmit(
        request: QuestionRequest,
        selectedOptions: [String: Set<String>],
        text: [String: String],
        secretTextByField: [String: String]
    ) -> Bool {
        request.resolvedFields.allSatisfy { field in
            let key = request.draftKey(for: field)
            switch field.kind {
            case .singleChoice, .multipleChoice:
                return !(selectedOptions[key] ?? []).isEmpty
                    || (field.allowsOther
                        && !(text[key] ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty)
            case .freeText:
                return !(text[key] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
            case .secret:
                return !(secretTextByField[field.id] ?? "").isEmpty
            }
        }
    }

    static func answers(
        request: QuestionRequest,
        selectedOptions: [String: Set<String>],
        text: [String: String],
        secretTextByField: [String: String]
    ) -> [ChatQuestionAnswer] {
        request.resolvedFields.map { field in
            let key = request.draftKey(for: field)
            return ChatQuestionAnswer(
                questionID: field.id,
                selectedOptionIDs: (selectedOptions[key] ?? []).sorted(),
                text: field.kind == .secret
                    ? secretTextByField[field.id]
                    : text[key]
            )
        }
    }
}

private struct QuestionCard: View {
    let question: QuestionRequest
    @ObservedObject var store: ConversationStore
    let coordinator: ConversationCoordinator
    let isReadOnly: Bool

    @State private var secretTextByField: [String: String] = [:]

    private var isResponding: Bool {
        store.respondingInteractionIDs.contains(question.id)
    }

    private var fields: [QuestionField] {
        question.resolvedFields
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: question.status == .pending ? "questionmark.bubble.fill" : "checkmark.bubble")
                    .foregroundStyle(question.status == .pending ? .blue : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(fields.count == 1 ? fields[0].prompt : question.prompt)
                        .font(.headline)
                    if fields.count > 1, question.status == .pending {
                        Text("\(fields.count) answers required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if question.status != .pending {
                        Text(question.status == .answered ? "Answered" : "Request expired")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if question.status == .pending, !isReadOnly {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { index, field in
                        if index > 0 {
                            Divider()
                        }
                        questionField(field, showsPrompt: fields.count > 1)
                    }
                }

                Button {
                    let answers = answerPayload
                    secretTextByField.removeAll()
                    Task {
                        await coordinator.answer(
                            questionID: question.id,
                            answers: answers
                        )
                    }
                } label: {
                    if isResponding {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Submit Answer")
                    }
                }
                .buttonStyle(.borderedProminent)
                .chatMinimumInteractionTarget()
                .disabled(!canSubmit || isResponding)
                .accessibilityHint("Submits this answer once.")
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.2))
        }
        .accessibilityElement(children: .contain)
        .onChange(of: question.status) { _, status in
            if status != .pending {
                secretTextByField.removeAll()
            }
        }
        .onDisappear {
            secretTextByField.removeAll()
        }
    }

    private var canSubmit: Bool {
        QuestionResponsePresentation.canSubmit(
            request: question,
            selectedOptions: store.selectedQuestionOptions,
            text: store.questionText,
            secretTextByField: secretTextByField
        )
    }

    private var answerPayload: [ChatQuestionAnswer] {
        QuestionResponsePresentation.answers(
            request: question,
            selectedOptions: store.selectedQuestionOptions,
            text: store.questionText,
            secretTextByField: secretTextByField
        )
    }

    @ViewBuilder
    private func questionField(_ field: QuestionField, showsPrompt: Bool) -> some View {
        let key = question.draftKey(for: field)
        let selectedOptions = store.selectedQuestionOptions[key] ?? []

        VStack(alignment: .leading, spacing: 9) {
            if showsPrompt {
                Text(field.prompt)
                    .font(.subheadline.weight(.semibold))
            }

            if !field.options.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(field.options) { option in
                        Button {
                            store.toggleQuestionOption(
                                questionID: key,
                                optionID: option.id,
                                allowsMultiple: field.kind == .multipleChoice
                            )
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Image(
                                    systemName: selectedOptions.contains(option.id)
                                        ? (field.kind == .multipleChoice
                                            ? "checkmark.square.fill"
                                            : "largecircle.fill.circle")
                                        : (field.kind == .multipleChoice ? "square" : "circle")
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .foregroundStyle(.primary)
                                    if let detail = option.detail {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .chatMinimumInteractionTarget()
                        .accessibilityLabel(
                            "\(option.label), \(selectedOptions.contains(option.id) ? "selected" : "not selected")"
                        )
                    }
                }
            }

            if field.kind == .freeText || field.allowsOther {
                TextField(
                    field.allowsOther ? "Or type another answer" : "Type your answer",
                    text: Binding(
                        get: { store.questionText[key] ?? "" },
                        set: { store.updateQuestionText(questionID: key, text: $0) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            } else if field.kind == .secret {
                SecureField(
                    "Enter securely",
                    text: Binding(
                        get: { secretTextByField[field.id] ?? "" },
                        set: { secretTextByField[field.id] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .privacySensitive()
                .accessibilityHint(
                    "This answer is sent directly and is not retained in conversation state."
                )
            }
        }
    }
}

#if os(iOS)
struct MobileComposerModelOption: Equatable, Identifiable {
    let id: String
    let name: String
    let supportsUltra: Bool
}

enum MobileComposerLaunchPolicy {
    static let codexModels = [
        MobileComposerModelOption(
            id: "gpt-5.6-sol",
            name: "5.6 Sol",
            supportsUltra: true
        ),
        MobileComposerModelOption(
            id: "gpt-5.6-terra",
            name: "5.6 Terra",
            supportsUltra: true
        ),
        MobileComposerModelOption(
            id: "gpt-5.6-luna",
            name: "5.6 Luna",
            supportsUltra: false
        ),
    ]

    static let claudeModels = [
        MobileComposerModelOption(
            id: "fable",
            name: "Fable",
            supportsUltra: false
        ),
        MobileComposerModelOption(
            id: "opus",
            name: "Opus",
            supportsUltra: false
        ),
        MobileComposerModelOption(
            id: "sonnet",
            name: "Sonnet",
            supportsUltra: false
        ),
    ]

    static func models(for provider: ChatProvider) -> [MobileComposerModelOption] {
        provider == .codex ? codexModels : claudeModels
    }

    static func availableEfforts(
        provider: ChatProvider,
        model: String
    ) -> [AgentReasoningEffort] {
        let supportsUltra = models(for: provider)
            .first(where: { $0.id == model })?
            .supportsUltra == true
        return AgentReasoningEffort.allCases.filter {
            $0 != .ultra || supportsUltra
        }
    }

    static func normalizedEffort(
        _ effort: AgentReasoningEffort,
        provider: ChatProvider,
        model: String
    ) -> AgentReasoningEffort {
        availableEfforts(provider: provider, model: model).contains(effort)
            ? effort
            : .max
    }
}
#endif

private struct ConversationComposer: View {
    @ObservedObject var store: ConversationStore
    let coordinator: ConversationCoordinator
    let attachmentActions: ChatAttachmentActions?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var attachmentDrafts: [ChatAttachmentDraft] = []
    @State private var attachmentMessage: String?
    @State private var isImportingAttachments = false
    @State private var isSubmittingAttachments = false
    @State private var pendingAttachmentSubmission: ChatAttachmentSubmission?

    #if os(iOS)
    @AppStorage(AgentLaunchDefaults.StorageKey.codexModel)
    private var codexModel = AgentLaunchDefaults.standard.codexModel
    @AppStorage(AgentLaunchDefaults.StorageKey.codexReasoningEffort)
    private var codexReasoningEffort = AgentLaunchDefaults.standard.codexReasoningEffort
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeModel)
    private var claudeModel = AgentLaunchDefaults.standard.claudeModel
    @AppStorage(AgentLaunchDefaults.StorageKey.claudeReasoningEffort)
    private var claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort
    #endif

    private var canSend: Bool {
        (!store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !attachmentDrafts.isEmpty)
            && !store.state.turnState.isActive
            && !isSubmittingAttachments
            && (store.state.connectionState == .streaming
                || store.state.connectionState == .interrupted)
    }

    private var canAttachFiles: Bool {
        attachmentActions != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachmentDrafts.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 7) {
                        ForEach(attachmentDrafts) { attachment in
                            HStack(spacing: 6) {
                                Image(
                                    systemName: attachment.kind == .image
                                        ? "photo" : "doc"
                                )
                                Text(attachment.displayName)
                                    .lineLimit(1)
                                Button {
                                    attachmentDrafts.removeAll {
                                        $0.id == attachment.id
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .chatMinimumInteractionTarget(includesWidth: true)
                                .accessibilityLabel("Remove \(attachment.displayName)")
                            }
                            .font(.caption)
                            .padding(.horizontal, 9)
                            .padding(.vertical, ChatInteractionTargetLayout.attachmentChipVerticalPadding)
                            .background(Color.secondary.opacity(0.09), in: Capsule())
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            if isSubmittingAttachments {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Uploading attachments…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if let attachmentMessage {
                Text(attachmentMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            composerInput
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(Color.chatComposer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.12))
            }
        }
        #if os(iOS)
        .onAppear {
            synchronizeMobileLaunchOptions()
        }
        .fileImporter(
            isPresented: $isImportingAttachments,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importAttachments
        )
        .onChange(of: store.attachments) { _, _ in
            reconcileAttachmentSubmission()
        }
        .onChange(of: store.state.activeTurnID) { _, _ in
            reconcileAttachmentSubmission()
        }
        .onChange(of: store.state.turnState) { _, _ in
            reconcileAttachmentSubmission()
        }
        #endif
    }

    @ViewBuilder
    private var composerInput: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: 0) {
            promptEditor
            HStack(spacing: 4) {
                if canAttachFiles {
                    Button {
                        isImportingAttachments = true
                    } label: {
                        Image(systemName: "paperclip")
                            .frame(
                                width: actionHitTargetSize,
                                height: actionHitTargetSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmittingAttachments)
                    .accessibilityLabel("Attach files")
                }
                mobileModelControl
                mobileEffortControl
                Spacer(minLength: 8)
                turnActionButton
            }
        }
        #else
        HStack(alignment: .bottom, spacing: 10) {
            promptEditor
            turnActionButton
        }
        #endif
    }

    private var promptEditor: some View {
        ZStack(alignment: .topLeading) {
            if store.draft.isEmpty {
                Text("Ask anything")
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $store.draft)
                .font(.body)
                .tint(.primary)
                .scrollContentBackground(.hidden)
                .frame(
                    minHeight: dynamicTypeSize.isAccessibilitySize ? 74 : 42,
                    maxHeight: 150
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Message")
                .accessibilityHint("Command Return sends. Return inserts a new line.")
                .onKeyPress(.return, phases: .down) { keyPress in
                    switch ComposerInputPolicy.returnAction(
                        commandKeyPressed: keyPress.modifiers.contains(.command),
                        canSend: canSend
                    ) {
                    case .insertNewline:
                        return .ignored
                    case .send:
                        Task {
                            await submit()
                        }
                        return .handled
                    case .ignore:
                        return .handled
                    }
                }
        }
    }

    @MainActor
    private func submit() async {
        guard canSend else { return }
        guard !attachmentDrafts.isEmpty else {
            await coordinator.sendDraft()
            return
        }
        guard let attachmentActions else {
            attachmentMessage = "This worker does not support file attachments."
            return
        }

        let requestID = UUID().uuidString.lowercased()
        let submittedDraft = store.draft
        let submittedAttachments = attachmentDrafts
        store.draft = ""
        attachmentDrafts.removeAll()
        attachmentMessage = nil
        isSubmittingAttachments = true

        var references: [ChatAttachmentReference] = []
        do {
            for attachment in submittedAttachments {
                references.append(
                    try await attachmentActions.upload(attachment, requestID)
                )
            }
        } catch {
            await attachmentActions.discard(requestID)
            restoreAttachmentDraft(
                text: submittedDraft,
                attachments: submittedAttachments
            )
            attachmentMessage = error.localizedDescription
            isSubmittingAttachments = false
            return
        }

        let trimmed = submittedDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let prompt = trimmed.isEmpty
            ? "Please review the attached \(references.count == 1 ? "file" : "files")."
            : trimmed
        pendingAttachmentSubmission = ChatAttachmentSubmission(
            requestID: requestID,
            prompt: prompt,
            draft: submittedDraft,
            attachments: submittedAttachments,
            references: references
        )
        let wasSent = await coordinator.send(
            text: prompt,
            attachments: references,
            requestID: requestID
        )
        guard wasSent else {
            for reference in references {
                store.removeAttachment(id: reference.id)
            }
            store.draft = ""
            restoreAttachmentDraft(
                text: submittedDraft,
                attachments: submittedAttachments
            )
            pendingAttachmentSubmission = nil
            isSubmittingAttachments = false
            attachmentMessage = "The attachments were not added. Retry to upload them again."
            await attachmentActions.discard(requestID)
            return
        }
        reconcileAttachmentSubmission()
    }

    @MainActor
    private func reconcileAttachmentSubmission() {
        guard let pending = pendingAttachmentSubmission else { return }
        if store.state.activeTurnID != nil || store.state.turnState.isActive {
            pendingAttachmentSubmission = nil
            isSubmittingAttachments = false
            return
        }

        let restoredIDs = store.attachments.map(\.id)
        let expectedIDs = pending.references.map(\.id)
        let connectionEnded: Bool
        switch store.state.connectionState {
        case .offlineAgentRunning, .failed, .stopped, .unsupportedWorker:
            connectionEnded = true
        case .connecting, .streaming, .awaitingApproval, .interrupted, .unknown:
            connectionEnded = false
        }
        guard restoredIDs == expectedIDs || connectionEnded else { return }

        let typedAfterSubmission: String
        if store.draft == pending.prompt {
            typedAfterSubmission = ""
        } else if store.draft.hasPrefix(pending.prompt + "\n\n") {
            typedAfterSubmission = String(
                store.draft.dropFirst(pending.prompt.count + 2)
            )
        } else {
            typedAfterSubmission = store.draft
        }
        for reference in pending.references {
            store.removeAttachment(id: reference.id)
        }
        store.draft = typedAfterSubmission
        restoreAttachmentDraft(
            text: pending.draft,
            attachments: pending.attachments
        )
        pendingAttachmentSubmission = nil
        isSubmittingAttachments = false
        attachmentMessage = "The attachments were not added. Retry to upload them again."
        Task {
            await attachmentActions?.discard(pending.requestID)
        }
    }

    private func restoreAttachmentDraft(
        text: String,
        attachments: [ChatAttachmentDraft]
    ) {
        if store.draft.isEmpty {
            store.draft = text
        } else if !text.isEmpty, store.draft != text {
            store.draft = "\(text)\n\n\(store.draft)"
        }
        let existingIDs = Set(attachmentDrafts.map(\.id))
        attachmentDrafts.insert(
            contentsOf: attachments.filter { !existingIDs.contains($0.id) },
            at: 0
        )
    }

    #if os(iOS)
    @MainActor
    private func importAttachments(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            attachmentMessage = error.localizedDescription
        case .success(let urls):
            attachmentMessage = nil
            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let values = try url.resourceValues(forKeys: [
                        .contentTypeKey,
                        .fileSizeKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ])
                    guard values.isRegularFile == true,
                          values.isSymbolicLink != true else {
                        attachmentMessage = "Only regular files can be attached."
                        break
                    }
                    if let size = values.fileSize,
                       size > ChatAttachmentPolicy.maximumFileBytes {
                        attachmentMessage = "Attachments are limited to 25 MiB each."
                        break
                    }
                    let loaded = try Data(contentsOf: url, options: .mappedIfSafe)
                    let type = values.contentType
                    let draft: ChatAttachmentDraft
                    if let type, type.conforms(to: .image),
                       let pngData = UIImage(data: loaded)?.pngData() {
                        draft = ChatAttachmentDraft(
                            displayName: attachmentDisplayName(url.lastPathComponent),
                            mediaType: "image/png",
                            kind: .image,
                            fileExtension: "png",
                            data: pngData
                        )
                    } else {
                        draft = ChatAttachmentDraft(
                            displayName: attachmentDisplayName(url.lastPathComponent),
                            mediaType: type?.preferredMIMEType
                                ?? "application/octet-stream",
                            kind: .file,
                            fileExtension: type?.preferredFilenameExtension
                                ?? url.pathExtension,
                            data: Data(loaded)
                        )
                    }
                    let existingBytes = attachmentDrafts.reduce(0) {
                        $0 + $1.byteCount
                    }
                    guard ChatAttachmentPolicy.accepts(
                        byteCount: draft.byteCount,
                        existingCount: attachmentDrafts.count,
                        existingBytes: existingBytes
                    ) else {
                        attachmentMessage = "Attach at most 32 files, 25 MiB each and 100 MiB total."
                        break
                    }
                    attachmentDrafts.append(draft)
                } catch {
                    attachmentMessage = error.localizedDescription
                    break
                }
            }
        }
    }

    private func attachmentDisplayName(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let replacement = CharacterSet.controlCharacters.contains(scalar)
                ? "_" : String(scalar)
            guard result.utf8.count + replacement.utf8.count <= 512 else { break }
            result.append(contentsOf: replacement)
        }
        return result.isEmpty ? "Attachment" : result
    }
    #endif

    @ViewBuilder
    private var turnActionButton: some View {
        if store.state.turnState.isActive {
            Button {
                Task {
                    await coordinator.interrupt()
                }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.caption2.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(Color.primary, in: Circle())
                    .foregroundStyle(Color.chatButtonForeground)
                    .frame(width: actionHitTargetSize, height: actionHitTargetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop current turn")
            .accessibilityHint("Stops the current turn. Press Escape twice to stop from the keyboard.")
        } else {
            Button {
                Task {
                    await submit()
                }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.callout.weight(.bold))
                    .frame(width: 30, height: 30)
                    .background(
                        canSend ? Color.primary : Color.secondary.opacity(0.14),
                        in: Circle()
                    )
                    .foregroundStyle(
                        canSend ? Color.chatButtonForeground : Color.secondary
                    )
                    .frame(width: actionHitTargetSize, height: actionHitTargetSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityHint("Sends the message and any ready attachments.")
        }
    }

    private var actionHitTargetSize: CGFloat {
        #if os(iOS)
        44
        #else
        30
        #endif
    }

    #if os(iOS)
    private var mobileModelControl: some View {
        Menu {
            ForEach(
                MobileComposerLaunchPolicy.models(for: coordinator.identity.provider)
            ) { model in
                Button {
                    selectMobileModel(model.id)
                } label: {
                    if selectedMobileModel == model.id {
                        Label(model.name, systemImage: "checkmark")
                    } else {
                        Text(model.name)
                    }
                }
            }
        } label: {
            compactMenuLabel(mobileModelDisplayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Model")
        .accessibilityValue(mobileModelDisplayName)
    }

    private var mobileEffortControl: some View {
        Menu {
            ForEach(availableMobileEfforts) { effort in
                Button {
                    selectMobileEffort(effort)
                } label: {
                    if selectedMobileEffort == effort {
                        Label(effort.displayName, systemImage: "checkmark")
                    } else {
                        Text(effort.displayName)
                    }
                }
            }
        } label: {
            compactMenuLabel(selectedMobileEffort.displayName)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(selectedMobileEffort.displayName)
    }

    private func compactMenuLabel(_ title: String) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }

    private var selectedMobileModel: String {
        coordinator.identity.provider == .codex ? codexModel : claudeModel
    }

    private var selectedMobileEffort: AgentReasoningEffort {
        let effort = coordinator.identity.provider == .codex
            ? codexReasoningEffort
            : claudeReasoningEffort
        return MobileComposerLaunchPolicy.normalizedEffort(
            effort,
            provider: coordinator.identity.provider,
            model: selectedMobileModel
        )
    }

    private var availableMobileEfforts: [AgentReasoningEffort] {
        MobileComposerLaunchPolicy.availableEfforts(
            provider: coordinator.identity.provider,
            model: selectedMobileModel
        )
    }

    private var mobileModelDisplayName: String {
        MobileComposerLaunchPolicy.models(for: coordinator.identity.provider)
            .first(where: { $0.id == selectedMobileModel })?
            .name
            ?? selectedMobileModel
    }

    private func selectMobileModel(_ model: String) {
        if coordinator.identity.provider == .codex {
            codexModel = model
            codexReasoningEffort = MobileComposerLaunchPolicy.normalizedEffort(
                codexReasoningEffort,
                provider: .codex,
                model: model
            )
        } else {
            claudeModel = model
            claudeReasoningEffort = MobileComposerLaunchPolicy.normalizedEffort(
                claudeReasoningEffort,
                provider: .claude,
                model: model
            )
        }
        synchronizeMobileLaunchOptions()
    }

    private func selectMobileEffort(_ effort: AgentReasoningEffort) {
        if coordinator.identity.provider == .codex {
            codexReasoningEffort = effort
        } else {
            claudeReasoningEffort = effort
        }
        synchronizeMobileLaunchOptions()
    }

    private func synchronizeMobileLaunchOptions() {
        coordinator.updateLaunchOptions(
            model: selectedMobileModel,
            reasoningEffort: selectedMobileEffort.rawValue,
            fastMode: nil
        )
    }
    #endif
}

private struct ChatAttachmentSubmission {
    let requestID: String
    let prompt: String
    let draft: String
    let attachments: [ChatAttachmentDraft]
    let references: [ChatAttachmentReference]
}

private struct FilePreviewSheet: View {
    let preview: ChatFilePreview
    let dismiss: () -> Void

    var body: some View {
        NavigationStack {
            CodeBlockView(
                id: "preview:\(preview.id)",
                code: preview.content,
                language: URL(fileURLWithPath: preview.path).pathExtension,
                isStreaming: false
            )
            .padding()
            .navigationTitle(preview.path)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if preview.isTruncated {
                    Label(
                        "Preview truncated\(preview.originalByteCount.map { " from \($0.formatted()) bytes" } ?? "")",
                        systemImage: "scissors"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 320)
    }
}

private extension Color {
    static var chatCanvas: Color {
        #if os(macOS)
        Color(
            red: 23.0 / 255.0,
            green: 24.0 / 255.0,
            blue: 24.0 / 255.0
        )
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var chatComposer: Color {
        #if os(macOS)
        Color(
            red: 43.0 / 255.0,
            green: 43.0 / 255.0,
            blue: 43.0 / 255.0
        )
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }

    static var chatButtonForeground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
