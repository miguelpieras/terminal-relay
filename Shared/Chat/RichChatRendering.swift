import Foundation
import Markdown
import MarkdownView
import SwiftUI

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

enum ChatInteractionTargetLayout {
    static let minimumIOSDimension: CGFloat = 44

    static var appliesMinimumDimension: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    static var jumpButtonDimension: CGFloat {
        appliesMinimumDimension ? minimumIOSDimension : 28
    }

    static var jumpButtonOuterPadding: CGFloat {
        appliesMinimumDimension ? 8 : 16
    }

    static var codeHeaderVerticalPadding: CGFloat {
        appliesMinimumDimension ? 0 : 9
    }

    static var compactControlVerticalPadding: CGFloat {
        appliesMinimumDimension ? 0 : 3
    }

    static var attachmentChipVerticalPadding: CGFloat {
        appliesMinimumDimension ? 0 : 6
    }
}

extension View {
    @ViewBuilder
    func chatMinimumInteractionTarget(includesWidth: Bool = false) -> some View {
        #if os(iOS)
        frame(
            minWidth: includesWidth ? ChatInteractionTargetLayout.minimumIOSDimension : nil,
            minHeight: ChatInteractionTargetLayout.minimumIOSDimension
        )
        .contentShape(Rectangle())
        #else
        self
        #endif
    }
}

enum ChatURLPolicy {
    static let repositoryScheme = "terminal-relay-file"

    static func classify(_ url: URL) -> ChatLinkDestination {
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" {
            guard url.user == nil,
                  url.password == nil,
                  let host = url.host,
                  !host.isEmpty else {
                return .blocked
            }
            return .external(url)
        }

        if scheme == repositoryScheme {
            guard let link = repositoryLink(from: url) else { return .blocked }
            return .repository(link)
        }
        return .blocked
    }

    static func repositoryLink(from rawValue: String) -> ChatRepositoryLink? {
        if let url = URL(string: rawValue), url.scheme != nil {
            return repositoryLink(from: url)
        }
        return parseRepositoryPath(rawValue)
    }

    static func repositoryLink(from url: URL) -> ChatRepositoryLink? {
        guard url.scheme?.lowercased() == repositoryScheme,
              url.host == nil,
              url.user == nil,
              url.password == nil,
              url.query == nil else {
            return nil
        }
        var path = url.path.removingPercentEncoding ?? url.path
        if path.hasPrefix("/"), !path.hasPrefix("/workspace/") {
            path.removeFirst()
        }
        let fragmentLine = parseFragmentLine(url.fragment)
        guard var link = parseRepositoryPath(path) else { return nil }
        if link.line == nil, let fragmentLine {
            link = ChatRepositoryLink(path: link.path, line: fragmentLine, column: nil)
        }
        return link
    }

    private static func parseRepositoryPath(_ rawPath: String) -> ChatRepositoryLink? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\0"),
              !trimmed.contains("\\"),
              !trimmed.hasSuffix("/") else {
            return nil
        }

        let isCanonicalWorkspacePath = trimmed.hasPrefix("/workspace/")
        let isRelativePath = !trimmed.hasPrefix("/")
        guard isCanonicalWorkspacePath || isRelativePath else { return nil }

        var path = trimmed
        var line: Int?
        var column: Int?
        let components = path.split(separator: ":", omittingEmptySubsequences: false)
        if components.count >= 2, let last = components.last.flatMap({ Int($0) }), last > 0 {
            if components.count >= 3,
               let secondLast = Int(components[components.count - 2]),
               secondLast > 0 {
                line = secondLast
                column = last
                path = components.dropLast(2).joined(separator: ":")
            } else {
                line = last
                path = components.dropLast().joined(separator: ":")
            }
        }

        let pathComponents = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !pathComponents.isEmpty,
              !pathComponents.contains("."),
              !pathComponents.contains(".."),
              path.utf8.count <= 4_096 else {
            return nil
        }
        if isCanonicalWorkspacePath {
            guard pathComponents.count >= 3, pathComponents.first == "workspace" else {
                return nil
            }
        }
        return ChatRepositoryLink(path: path, line: line, column: column)
    }

    private static func parseFragmentLine(_ fragment: String?) -> Int? {
        guard let fragment else { return nil }
        let value = fragment.hasPrefix("L") ? String(fragment.dropFirst()) : fragment
        return Int(value).flatMap { $0 > 0 ? $0 : nil }
    }
}

enum MarkdownSafety {
    static func sanitizedSource(_ source: String) -> String {
        neutralizingImages(in: escapedRawHTML(source))
    }

    static func sanitizedSourceOffMain(
        _ source: String
    ) async -> MarkdownSanitizationResult {
        let task = Task.detached(priority: .userInitiated) {
            sanitizationResult(source)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func sanitizationResult(
        _ source: String
    ) -> MarkdownSanitizationResult {
        MarkdownSanitizationResult(
            source: sanitizedSource(source),
            performedOnMainThread: Thread.isMainThread
        )
    }

    static func escapedRawHTML(_ source: String) -> String {
        var insideFence = false
        return source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { substring -> String in
                let line = String(substring)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                    || line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                    insideFence.toggle()
                    return line
                }
                guard !insideFence else { return line }
                return escapeOpeningAnglesOutsideInlineCode(line)
            }
            .joined(separator: "\n")
    }

    static func containsRenderableImage(in source: String) -> Bool {
        var collector = MarkdownImageCollector()
        collector.visit(Document(parsing: source))
        return !collector.images.isEmpty
    }

    private static func neutralizingImages(in source: String) -> String {
        var collector = MarkdownImageCollector()
        collector.visit(Document(parsing: source))
        guard !collector.images.isEmpty else { return source }

        let lineStarts = utf8LineStartOffsets(in: source)
        var bytes = Array(source.utf8)
        let replacements = collector.images.compactMap { image -> (Range<Int>, [UInt8])? in
            guard let lowerBound = utf8Offset(
                for: image.range.lowerBound,
                lineStarts: lineStarts,
                byteCount: bytes.count
            ),
            let upperBound = utf8Offset(
                for: image.range.upperBound,
                lineStarts: lineStarts,
                byteCount: bytes.count
            ),
            lowerBound < upperBound else {
                return nil
            }
            let replacement = imageAffordance(
                alternativeText: image.alternativeText,
                source: image.source,
                isInsideLink: image.isInsideLink
            )
            return (lowerBound..<upperBound, Array(replacement.utf8))
        }
        .sorted { $0.0.lowerBound > $1.0.lowerBound }

        for (range, replacement) in replacements {
            bytes.replaceSubrange(range, with: replacement)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func imageAffordance(
        alternativeText: String,
        source: String?,
        isInsideLink: Bool
    ) -> String {
        let trimmedAlternative = alternativeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = "Image: \(trimmedAlternative.isEmpty ? "external image" : trimmedAlternative)"
        let escapedLabel = label
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "]", with: "\\]")

        guard !isInsideLink,
              let source,
              isAllowedImageAffordanceDestination(source) else {
            return escapedLabel
        }
        let escapedDestination = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ">", with: "%3E")
        return "[\(escapedLabel)](<\(escapedDestination)>)"
    }

    private static func isAllowedImageAffordanceDestination(_ source: String) -> Bool {
        if let url = URL(string: source), url.scheme != nil {
            switch ChatURLPolicy.classify(url) {
            case .external, .repository:
                return true
            case .blocked:
                return false
            }
        }
        return ChatURLPolicy.repositoryLink(from: source) != nil
    }

    private static func utf8LineStartOffsets(in source: String) -> [Int] {
        let bytes = Array(source.utf8)
        var starts = [0]
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A {
                starts.append(index + 1)
            } else if bytes[index] == 0x0D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
                starts.append(index + 1)
            }
            index += 1
        }
        return starts
    }

    private static func utf8Offset(
        for location: SourceLocation,
        lineStarts: [Int],
        byteCount: Int
    ) -> Int? {
        guard location.line > 0,
              location.line <= lineStarts.count,
              location.column > 0 else {
            return nil
        }
        let offset = lineStarts[location.line - 1] + location.column - 1
        return offset <= byteCount ? offset : nil
    }

    private static func escapeOpeningAnglesOutsideInlineCode(_ line: String) -> String {
        var output = ""
        var insideCode = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "`" {
                insideCode.toggle()
                output.append(character)
            } else if character == "<", !insideCode {
                output.append("&lt;")
            } else {
                output.append(character)
            }
            index = line.index(after: index)
        }
        return output
    }
}

struct MarkdownSanitizationResult: Equatable, Sendable {
    let source: String
    let performedOnMainThread: Bool
}

private struct MarkdownImageRecord {
    let range: SourceRange
    let alternativeText: String
    let source: String?
    let isInsideLink: Bool
}

private struct MarkdownImageCollector: MarkupWalker {
    var images: [MarkdownImageRecord] = []

    mutating func visitImage(_ image: Markdown.Image) {
        guard let range = image.range else { return }
        images.append(
            MarkdownImageRecord(
                range: range,
                alternativeText: image.plainText,
                source: image.source,
                isInsideLink: image.parent is Markdown.Link
            )
        )
    }
}

private struct TerminalRelayImageRenderer: MarkdownImageRenderer {
    let onOpenExternal: (URL) -> Void

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        let label = Label(
            configuration.alternativeText ?? "External image",
            systemImage: "photo.badge.arrow.down"
        )
        .font(.callout)
        .foregroundStyle(.secondary)

        switch ChatURLPolicy.classify(configuration.url) {
        case .external(let url):
            Button {
                onOpenExternal(url)
            } label: {
                label
            }
            .buttonStyle(.plain)
            .chatMinimumInteractionTarget()
            .accessibilityHint("Opens the image in your browser. It is not loaded inside Terminal Relay.")
        case .repository, .blocked:
            label
                .accessibilityHint("This image link is blocked.")
        }
    }
}

private struct TerminalRelayLinkRenderer: MarkdownLinkRenderer {
    let onOpenExternal: (URL) -> Void
    let onOpenRepository: (ChatRepositoryLink) -> Void

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        switch ChatURLPolicy.classify(configuration.url) {
        case .external(let url):
            Button {
                onOpenExternal(url)
            } label: {
                configuration.label
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .underline()
            .accessibilityHint("Opens in your browser.")
        case .repository(let link):
            Button {
                onOpenRepository(link)
            } label: {
                configuration.label
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .underline()
            .accessibilityHint("Opens a read-only repository preview.")
        case .blocked:
            configuration.label
                .foregroundStyle(.secondary)
                .accessibilityHint("This link is blocked.")
        }
    }
}

struct TerminalRelayMarkdownCodeBlockStyle: MarkdownCodeBlockStyle {
    let isStreaming: Bool

    func makeBody(configuration: Configuration) -> some View {
        CodeBlockView(
            id: "markdown-code:\(configuration.code.hashValue)",
            code: configuration.code,
            language: configuration.language,
            isStreaming: isStreaming,
            showsCopyButton: false
        )
    }
}

struct TerminalRelayMarkdownTableStyle: MarkdownTableStyle {
    func makeBody(configuration: Configuration) -> some View {
        TerminalRelayMarkdownTable(configuration: configuration)
    }
}

private struct TerminalRelayMarkdownTable: View {
    let configuration: MarkdownTableStyleConfiguration
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Grid { configuration.table.header }
                    ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { index, row in
                        Grid { row }
                            .background(index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06))
                    }
                }
            } else {
                ScrollView(.horizontal) {
                    tableGrid
                        .fixedSize(horizontal: true, vertical: false)
                }
                .scrollIndicators(.visible)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Scrollable table")
                .accessibilityHint("Swipe horizontally to read every table column.")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        }
        .textSelection(.enabled)
    }

    private var tableGrid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            configuration.table.header
                .markdownTableRowBackgroundStyle(Color.accentColor.opacity(0.08))
            ForEach(Array(configuration.table.rows.enumerated()), id: \.offset) { index, row in
                row.markdownTableRowBackgroundStyle(
                    index.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.06)
                )
            }
        }
        .markdownTableCellPadding(.horizontal, 12)
        .markdownTableCellPadding(.vertical, 8)
        .markdownTableCellOverlay {
            Rectangle().strokeBorder(Color.secondary.opacity(0.18))
        }
    }
}

/// Reference-stable bridge from value-driven transcript rows to the store and
/// coordinator. Injected through the environment so row view values stay
/// closure-free and cheap to diff; identity is stable for the life of a
/// ConversationView, so it never invalidates rows on its own.
@MainActor
final class ChatRowActions {
    private weak var store: ConversationStore?
    private weak var coordinator: ConversationCoordinator?

    nonisolated init() {}

    init(store: ConversationStore, coordinator: ConversationCoordinator) {
        self.store = store
        self.coordinator = coordinator
    }

    func toggleExpanded(itemID: String) {
        store?.toggleExpanded(itemID: itemID)
    }

    func markCopied(itemID: String?) {
        store?.markCopied(itemID: itemID)
    }

    func openRepository(_ link: ChatRepositoryLink) {
        guard let coordinator else { return }
        Task {
            await coordinator.previewFile(link)
        }
    }
}

extension ChatRowActions: Equatable {
    nonisolated static func == (lhs: ChatRowActions, rhs: ChatRowActions) -> Bool {
        lhs === rhs
    }
}

private struct ChatRowActionsKey: EnvironmentKey {
    static let defaultValue = ChatRowActions()
}

extension EnvironmentValues {
    var chatRowActions: ChatRowActions {
        get { self[ChatRowActionsKey.self] }
        set { self[ChatRowActionsKey.self] = newValue }
    }
}

/// Splits sanitized markdown into bounded segments so no single rendered
/// stack ever holds hundreds of children. A 1000-line agent output rendered
/// as one markdown view is a 1000-child layout stack whose sizing dominates
/// every scroll-time layout pass; bounded segments keep each pass cheap.
enum MarkdownSegmentation {
    static let segmentLineLimit = 60
    static let clampThresholdLines = 160
    static let clampedTailLines = 120

    /// Lines where a new segment may begin: blank lines, top-level list
    /// items (tight lists have no blank lines at all), and headings.
    /// Never splits inside a code fence.
    static func segments(
        of text: String,
        maximumLines: Int = segmentLineLimit
    ) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maximumLines else { return [text] }

        var result: [String] = []
        var current: [Substring] = []
        var insideFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            }
            if !insideFence,
               current.count >= maximumLines,
               isSegmentBoundary(trimmed) {
                result.append(current.joined(separator: "\n"))
                current = []
            }
            current.append(line)
        }
        if !current.isEmpty {
            result.append(current.joined(separator: "\n"))
        }
        return result
    }

    /// The tail of an over-long text at a safe boundary, or nil when the
    /// text is short enough to show in full.
    static func clampedTail(
        of text: String,
        thresholdLines: Int = clampThresholdLines,
        tailLines: Int = clampedTailLines
    ) -> (tail: String, hiddenLineCount: Int)? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > thresholdLines else { return nil }

        var start = lines.count - tailLines
        var insideFence = false
        for line in lines.prefix(start) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
            }
        }
        // Move the cut forward to the next safe boundary; if the cut landed
        // inside a fence, skip to just past its closing line.
        while start < lines.count {
            let trimmed = lines[start].trimmingCharacters(in: .whitespaces)
            if insideFence {
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    insideFence = false
                }
                start += 1
                continue
            }
            if isSegmentBoundary(trimmed) {
                break
            }
            start += 1
        }
        guard start > 0, start < lines.count else { return nil }
        return (
            tail: lines[start...].joined(separator: "\n"),
            hiddenLineCount: start
        )
    }

    private static func isSegmentBoundary(_ trimmedLine: String) -> Bool {
        if trimmedLine.isEmpty { return true }
        if trimmedLine.hasPrefix("#") { return true }
        if trimmedLine.hasPrefix("- ") || trimmedLine.hasPrefix("* ") || trimmedLine.hasPrefix("+ ") {
            return true
        }
        var digits = 0
        for character in trimmedLine {
            if character.isNumber {
                digits += 1
                if digits > 9 { return false }
                continue
            }
            return (character == "." || character == ")") && digits > 0
        }
        return false
    }
}

struct RichMarkdownView: View {
    let text: String
    let isStreaming: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.chatRowActions) private var actions

    @State private var source = StreamingMarkdownSource()
    @State private var didFinishStreaming = false

    var body: some View {
        let onOpenExternal: (URL) -> Void = { openURL($0) }
        let onOpenRepository: (ChatRepositoryLink) -> Void = { actions.openRepository($0) }

        markdownContent
            .markdownCodeBlockStyle(TerminalRelayMarkdownCodeBlockStyle(isStreaming: isStreaming))
            .markdownTableStyle(TerminalRelayMarkdownTableStyle())
            .markdownBaseURL(URL(string: "\(ChatURLPolicy.repositoryScheme):///")!)
            .markdownElementRenderer(
                .image(TerminalRelayImageRenderer(onOpenExternal: onOpenExternal), urlScheme: "http")
            )
            .markdownElementRenderer(
                .image(TerminalRelayImageRenderer(onOpenExternal: onOpenExternal), urlScheme: "https")
            )
            .markdownElementRenderer(
                .image(TerminalRelayImageRenderer(onOpenExternal: onOpenExternal), urlScheme: ChatURLPolicy.repositoryScheme)
            )
            .markdownElementRenderer(
                .link(
                    TerminalRelayLinkRenderer(
                        onOpenExternal: onOpenExternal,
                        onOpenRepository: onOpenRepository
                    ),
                    urlScheme: "http"
                )
            )
            .markdownElementRenderer(
                .link(
                    TerminalRelayLinkRenderer(
                        onOpenExternal: onOpenExternal,
                        onOpenRepository: onOpenRepository
                    ),
                    urlScheme: "https"
                )
            )
            .markdownElementRenderer(
                .link(
                    TerminalRelayLinkRenderer(
                        onOpenExternal: onOpenExternal,
                        onOpenRepository: onOpenRepository
                    ),
                    urlScheme: ChatURLPolicy.repositoryScheme
                )
            )
            .environment(
                \.openURL,
                OpenURLAction { url in
                    switch ChatURLPolicy.classify(url) {
                    case .external(let externalURL):
                        onOpenExternal(externalURL)
                    case .repository(let link):
                        onOpenRepository(link)
                    case .blocked:
                        break
                    }
                    return .handled
                }
            )
            .textSelection(.enabled)
    }

    /// Completed rows whose sanitized source is already cached parse
    /// synchronously on their first body pass, so they lay out at final height
    /// on the first frame — split into bounded segments, and clamped to a
    /// tail with a reveal control when very long. Everything else streams
    /// through the incremental reader (tail-clamped while live) and enters
    /// the cache on completion.
    @ViewBuilder
    private var markdownContent: some View {
        if !isStreaming,
           let sanitized = SanitizedMarkdownCache.shared.lookup(raw: text) {
            SegmentedMarkdownContent(sanitized: sanitized)
        } else {
            StreamingMarkdownReader(source) { parseResult in
                MarkdownView(parseResult)
            }
            .markdownStreamingRenderThrottle(.milliseconds(33))
            .task(id: MarkdownRenderInput(text: text, isStreaming: isStreaming)) {
                await synchronizeSource()
            }
        }
    }

    private func synchronizeSource() async {
        let result = await MarkdownSafety.sanitizedSourceOffMain(text)
        guard !Task.isCancelled else { return }
        if !isStreaming {
            SanitizedMarkdownCache.shared.insert(raw: text, sanitized: result.source)
        }
        // While live, only the tail re-renders: a 1000-line output must not
        // become a 1000-child layout stack mid-stream.
        let displayed: String
        if isStreaming,
           let clamped = MarkdownSegmentation.clampedTail(of: result.source) {
            displayed = clamped.tail
        } else {
            displayed = result.source
        }
        if didFinishStreaming || (isStreaming && source.text.count > displayed.count) {
            source = StreamingMarkdownSource(displayed)
            didFinishStreaming = false
        } else {
            source.text = displayed
        }
        if !isStreaming {
            source.finishStreaming()
            didFinishStreaming = true
        }
    }
}

/// Completed markdown, rendered as bounded segments with an optional
/// show-everything control for very long outputs. Numbering survives the
/// splits because ordered-list segments start at their own first number.
private struct SegmentedMarkdownContent: View {
    let sanitized: String

    @State private var showsFullMessage = false

    var body: some View {
        let clamp = showsFullMessage
            ? nil
            : MarkdownSegmentation.clampedTail(of: sanitized)
        VStack(alignment: .leading, spacing: 8) {
            if let clamp {
                Button {
                    showsFullMessage = true
                } label: {
                    Label(
                        "Show \(clamp.hiddenLineCount) earlier lines",
                        systemImage: "ellipsis.rectangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .chatMinimumInteractionTarget()
                .accessibilityHint("Shows the whole message.")
            }
            ForEach(
                Array(
                    MarkdownSegmentation.segments(of: clamp?.tail ?? sanitized)
                        .enumerated()
                ),
                id: \.offset
            ) { _, segment in
                MarkdownReader(segment) { parseResult in
                    MarkdownView(parseResult)
                }
            }
        }
    }
}

private struct MarkdownRenderInput: Hashable {
    let text: String
    let isStreaming: Bool
}

struct CodeBlockView: View {
    let id: String
    let code: String
    let language: String?
    let isStreaming: Bool
    var showsCopyButton = true

    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.isEmpty == false ? language! : "Code")
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if showsCopyButton {
                    Button {
                        ChatClipboard.copy(code)
                        didCopy = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            didCopy = false
                        }
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .chatMinimumInteractionTarget(includesWidth: true)
                    .accessibilityLabel(didCopy ? "Code copied" : "Copy code")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, ChatInteractionTargetLayout.codeHeaderVerticalPadding)

            Divider()

            // On macOS long lines wrap: a scroll view per code block means a
            // live NSScrollView per block, each maintaining tracking areas on
            // every scrolled frame and competing for wheel events.
            #if os(macOS)
            HighlightedCodeText(
                code: code,
                language: language,
                usesHighlighting: !isStreaming
            )
            .font(.system(.callout, design: .monospaced))
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            #else
            ScrollView(.horizontal) {
                HighlightedCodeText(
                    code: code,
                    language: language,
                    usesHighlighting: !isStreaming
                )
                .font(.system(.callout, design: .monospaced))
                .lineSpacing(3)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
                .padding(12)
            }
            .scrollIndicators(.visible)
            #endif
        }
        .background(Color.secondary.opacity(0.065))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
        }
        .accessibilityElement(children: .contain)
    }
}

enum ChatClipboard {
    static func copy(_ value: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = value
        #endif
    }
}

private struct HighlightedCodeText: View {
    let code: String
    let language: String?
    let usesHighlighting: Bool
    @State private var highlighted: AttributedString?

    var body: some View {
        Group {
            if let highlighted {
                Text(highlighted)
            } else {
                Text(verbatim: code)
            }
        }
        .task(id: HighlightConfiguration(code: code, language: language, enabled: usesHighlighting)) {
            highlighted = nil
            guard usesHighlighting else { return }
            let result = await ChatSyntaxHighlighter.tokensOffMain(
                for: code,
                language: language
            )
            guard !Task.isCancelled else { return }
            highlighted = Self.attributedText(result.tokens)
        }
    }

    private static func attributedText(_ tokens: [ChatCodeToken]) -> AttributedString {
        var output = AttributedString()
        for token in tokens {
            var piece = AttributedString(token.text)
            piece.foregroundColor = token.kind.color
            output += piece
        }
        return output
    }

    private struct HighlightConfiguration: Hashable {
        let code: String
        let language: String?
        let enabled: Bool
    }
}

struct ChatCodeToken: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case plain
        case keyword
        case string
        case comment
        case number

        @MainActor
        var color: Color {
            switch self {
            case .plain: .primary
            case .keyword: .purple
            case .string: .green
            case .comment: .secondary
            case .number: .blue
            }
        }
    }

    let text: String
    let kind: Kind
}

struct ChatSyntaxHighlightingResult: Equatable, Sendable {
    let tokens: [ChatCodeToken]
    let performedOnMainThread: Bool
}

enum ChatSyntaxHighlighter {
    private static let supportedLanguages: Set<String> = [
        "bash", "c", "cpp", "css", "go", "html", "javascript", "js", "json",
        "kotlin", "objective-c", "python", "ruby", "rust", "sh", "shell", "sql",
        "swift", "typescript", "ts", "xml", "yaml", "yml",
    ]

    private static let keywords = [
        "actor", "async", "await", "break", "case", "catch", "class", "const",
        "continue", "default", "defer", "do", "else", "enum", "extension", "false",
        "finally", "for", "func", "function", "guard", "if", "import", "in", "interface",
        "let", "nil", "null", "private", "protocol", "public", "return", "static",
        "struct", "switch", "throw", "throws", "true", "try", "typealias", "var", "while",
    ]

    static func tokens(for code: String, language: String?) -> [ChatCodeToken] {
        guard let language = language?.lowercased(),
              supportedLanguages.contains(language),
              code.utf8.count <= 200_000 else {
            return [ChatCodeToken(text: code, kind: .plain)]
        }

        let escapedKeywords = keywords.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let pattern = #"(//[^\n]*|#[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|\b(?:\#(escapedKeywords))\b|\b\d+(?:\.\d+)?\b)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return [ChatCodeToken(text: code, kind: .plain)]
        }

        let source = code as NSString
        let matches = expression.matches(in: code, range: NSRange(location: 0, length: source.length))
        var tokens: [ChatCodeToken] = []
        var location = 0
        for match in matches {
            if match.range.location > location {
                tokens.append(
                    ChatCodeToken(
                        text: source.substring(with: NSRange(location: location, length: match.range.location - location)),
                        kind: .plain
                    )
                )
            }
            let value = source.substring(with: match.range)
            let kind: ChatCodeToken.Kind
            if value.hasPrefix("//") || value.hasPrefix("#") || value.hasPrefix("/*") {
                kind = .comment
            } else if value.hasPrefix("\"") || value.hasPrefix("'") {
                kind = .string
            } else if Double(value) != nil {
                kind = .number
            } else {
                kind = .keyword
            }
            tokens.append(ChatCodeToken(text: value, kind: kind))
            location = NSMaxRange(match.range)
        }
        if location < source.length {
            tokens.append(
                ChatCodeToken(
                    text: source.substring(from: location),
                    kind: .plain
                )
            )
        }
        return tokens
    }

    static func tokensOffMain(
        for code: String,
        language: String?
    ) async -> ChatSyntaxHighlightingResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(
                    returning: ChatSyntaxHighlightingResult(
                        tokens: tokens(for: code, language: language),
                        performedOnMainThread: Thread.isMainThread
                    )
                )
            }
        }
    }
}
