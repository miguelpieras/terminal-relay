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

    /// Cheap GFM table screen: a pipe-bearing header line directly above a
    /// delimiter line. Rows that pass stay on the SwiftUI Markdown path so
    /// tables keep their grid rendering; a false positive only routes one
    /// bounded row through the heavier-but-correct renderer.
    static func containsTableCandidate(_ source: String) -> Bool {
        var previousLineHasPipe = false
        for substring in source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            let trimmed = substring.trimmingCharacters(in: .whitespaces)
            if previousLineHasPipe,
               trimmed.contains("-"),
               !trimmed.isEmpty,
               trimmed.allSatisfy({ "|-: ".contains($0) }) {
                return true
            }
            previousLineHasPipe = trimmed.contains("|")
        }
        return false
    }

    private static func neutralizingImages(in source: String) -> String {
        guard source.contains("![") else { return source }
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

    func copyMessage(itemID: String, fallback: String) {
        store?.copyRetainedMessage(itemID: itemID, fallback: fallback)
    }

    func copyToolSection(identifier: String, fallback: String) {
        store?.copyRetainedToolSection(identifier: identifier, fallback: fallback)
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

#if os(macOS)
private struct PreparedMarkdownNativeStyle: Hashable, Sendable {
    enum SyntaxColor: Hashable, Sendable {
        case keyword
        case string
        case comment
        case number
    }

    var headingLevel: Int?
    var isBold: Bool
    var isItalic: Bool
    var isStrikethrough: Bool
    var isCode: Bool
    var isQuote: Bool
    var syntaxColor: SyntaxColor?
}

private enum PreparedMarkdownNativeStyleAttribute: AttributedStringKey {
    typealias Value = PreparedMarkdownNativeStyle
    static let name = "TerminalRelay.PreparedMarkdownNativeStyle"
}

private extension AttributeScopes {
    struct TerminalRelayPreparedMarkdownAttributes: AttributeScope {
        let nativeStyle: PreparedMarkdownNativeStyleAttribute
    }

    var terminalRelayPreparedMarkdown: TerminalRelayPreparedMarkdownAttributes.Type {
        TerminalRelayPreparedMarkdownAttributes.self
    }
}

private extension AttributeDynamicLookup {
    subscript<T>(
        dynamicMember keyPath: KeyPath<
            AttributeScopes.TerminalRelayPreparedMarkdownAttributes,
            T
        >
    ) -> T where T: AttributedStringKey {
        self[T.self]
    }
}

private final class PreparedMarkdownNativeTextCache: @unchecked Sendable {
    private struct StyleKey: Equatable {
        let fontScale: Int
        let isDark: Bool
    }

    @MainActor private var styleKey: StyleKey?
    @MainActor private var value: NSAttributedString?

    @MainActor
    func lookup(
        fontScale: CGFloat,
        colorScheme: ColorScheme
    ) -> NSAttributedString? {
        styleKey == Self.key(for: fontScale, colorScheme: colorScheme) ? value : nil
    }

    @MainActor
    func resolve(
        fontScale: CGFloat,
        colorScheme: ColorScheme,
        _ makeValue: () -> NSAttributedString
    ) -> NSAttributedString {
        let requestedKey = Self.key(
            for: fontScale,
            colorScheme: colorScheme
        )
        if styleKey == requestedKey, let value { return value }
        let prepared = makeValue()
        styleKey = requestedKey
        value = prepared
        return prepared
    }

    private static func key(
        for fontScale: CGFloat,
        colorScheme: ColorScheme
    ) -> StyleKey {
        StyleKey(
            fontScale: Int((max(0.5, min(fontScale, 4)) * 1_000).rounded()),
            isDark: colorScheme == .dark
        )
    }
}

/// The final, immutable representation used by completed transcript rows on
/// macOS. Markdown parsing, sanitization, link classification, and inline
/// styling all happen before this value reaches SwiftUI, so mounting a cached
/// row only creates one `Text` view.
struct PreparedMarkdown: Sendable {
    let attributedText: AttributedString
    let sanitizedSource: String
    let plainText: String
    let linkURLs: [URL]
    let performedOnMainThread: Bool
    let requestedPriority: TaskPriority
    private let nativeTextCache = PreparedMarkdownNativeTextCache()

    var estimatedCacheCost: Int {
        // NSCache costs are approximate bytes. Account for the raw prepared
        // characters, UTF-16-ish attributed backing storage, and run metadata.
        sanitizedSource.utf8.count
            + plainText.utf8.count * 2
            + attributedText.runs.count * 160
            + 256
    }

    /// Immutable TextKit artifact used by reusable AppKit transcript cells.
    /// The Markdown parse remains off-main; this bounded run translation is
    /// cached once so revisiting a row does no SwiftUI graph construction and
    /// no repeated attributed-string conversion.
    @MainActor
    func cachedAppKitAttributedText(
        fontScale: CGFloat = 1,
        colorScheme: ColorScheme = .light
    ) -> NSAttributedString? {
        nativeTextCache.lookup(
            fontScale: fontScale,
            colorScheme: colorScheme
        )
    }

    @MainActor
    func appKitAttributedText(
        fontScale: CGFloat = 1,
        colorScheme: ColorScheme = .light
    ) -> NSAttributedString {
        nativeTextCache.resolve(
            fontScale: fontScale,
            colorScheme: colorScheme
        ) {
            let result = NSMutableAttributedString()
            for run in attributedText.runs {
                let text = String(attributedText[run.range].characters)
                let style = run.terminalRelayPreparedMarkdown.nativeStyle
                    ?? PreparedMarkdownNativeStyle(
                        headingLevel: nil,
                        isBold: false,
                        isItalic: false,
                        isStrikethrough: false,
                        isCode: false,
                        isQuote: false,
                        syntaxColor: nil
                )
                var attributes: [NSAttributedString.Key: Any] = [
                    .font: Self.appKitFont(for: style, fontScale: fontScale),
                    .foregroundColor: Self.appKitColor(for: style),
                ]
                if style.isStrikethrough {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                }
                if style.isCode && style.headingLevel == nil {
                    attributes[.backgroundColor] = NSColor(
                        white: colorScheme == .dark ? 1 : 0,
                        alpha: 0.07
                    )
                }
                if let link = run.link {
                    attributes[.link] = link
                    attributes[.foregroundColor] = NSColor.linkColor
                    attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
                }
                result.append(
                    NSAttributedString(string: text, attributes: attributes)
                )
            }
            return NSAttributedString(attributedString: result)
        }
    }

    @MainActor
    private static func appKitFont(
        for style: PreparedMarkdownNativeStyle,
        fontScale: CGFloat
    ) -> NSFont {
        let baseSize: CGFloat
        let weight: NSFont.Weight
        switch style.headingLevel {
        case 1:
            baseSize = 20
            weight = .bold
        case 2:
            baseSize = 17
            weight = .bold
        case 3:
            baseSize = 15
            weight = .semibold
        case .some:
            baseSize = NSFont.systemFontSize
            weight = .semibold
        case nil:
            baseSize = NSFont.systemFontSize
            weight = style.isBold ? .semibold : .regular
        }
        let size = baseSize * max(0.5, min(fontScale, 4))
        var font = style.isCode
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        if style.isItalic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    private static func appKitColor(
        for style: PreparedMarkdownNativeStyle
    ) -> NSColor {
        switch style.syntaxColor {
        case .keyword:
            return .systemPurple
        case .string:
            return .systemGreen
        case .comment:
            return .secondaryLabelColor
        case .number:
            return .systemBlue
        case nil:
            return style.isQuote ? .secondaryLabelColor : .labelColor
        }
    }
}

/// Process-wide permit pool for Markdown preparation. Restores, multiple open
/// conversations, and cold visible rows all share these two slots instead of
/// each creating their own parser fan-out. Waiters are priority ordered so a
/// visible tile can run before queued utility warming work.
actor MarkdownPreparationGate {
    static let shared = MarkdownPreparationGate(maxConcurrent: 2)

    nonisolated let maximumConcurrent: Int

    private struct Waiter {
        let id: UUID
        let priority: TaskPriority
        let sequence: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var active = 0
    private var nextSequence: UInt64 = 0
    private var waiters: [Waiter] = []

    init(maxConcurrent: Int) {
        precondition(maxConcurrent > 0)
        self.maximumConcurrent = maxConcurrent
    }

    nonisolated func run<Value: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        guard await acquire(priority: priority) else {
            return nil
        }
        guard !Task.isCancelled else {
            await release()
            return nil
        }
        let value = await operation()
        await release()
        return Task.isCancelled ? nil : value
    }

    private func acquire(priority: TaskPriority) async -> Bool {
        guard !Task.isCancelled else { return false }
        if active < maximumConcurrent {
            active += 1
            return true
        }
        let id = UUID()
        let sequence = nextSequence
        nextSequence &+= 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                waiters.append(
                    Waiter(
                        id: id,
                        priority: priority,
                        sequence: sequence,
                        continuation: continuation
                    )
                )
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(returning: false)
    }

    private func release() {
        guard !waiters.isEmpty else {
            active -= 1
            return
        }
        var selected = waiters.startIndex
        for index in waiters.indices.dropFirst() {
            let candidate = waiters[index]
            let current = waiters[selected]
            if candidate.priority.rawValue > current.priority.rawValue
                || (candidate.priority == current.priority && candidate.sequence < current.sequence) {
                selected = index
            }
        }
        let waiter = waiters.remove(at: selected)
        // The released permit transfers directly to this waiter, so `active`
        // remains unchanged.
        waiter.continuation.resume(returning: true)
    }
}

enum PreparedMarkdownRenderer {
    static func prepareOffMain(
        _ source: String,
        priority: TaskPriority = .userInitiated
    ) async -> PreparedMarkdown? {
        await MarkdownPreparationGate.shared.run(priority: priority) {
            let task = Task.detached(priority: priority) {
                prepare(source, requestedPriority: priority)
            }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    private static func prepare(
        _ source: String,
        requestedPriority: TaskPriority
    ) -> PreparedMarkdown {
        let sanitized = MarkdownSafety.sanitizedSource(source)
        let document = Document(parsing: sanitized)
        let rendered = renderBlocks(Array(document.children), context: .init())
        let logicalLines = sanitized.utf8.reduce(into: 1) { count, byte in
            if byte == 0x0A { count += 1 }
        }
        // SwiftUI Text layout scales sharply with attributed-run density.
        // Preserve full styling for ordinary tiles, but collapse pathological
        // dense formatting to the exact rendered characters so a cold mount
        // stays bounded even when the source contains many short rich lines.
        let maximumRuns = logicalLines > 32 ? 16 : 64
        let links = rendered.runs.compactMap(\.link)
        // Link attributes are interaction, not decoration. A link-dense tile
        // is already bounded to 1 KiB, so keep those runs clickable; collapse
        // only non-interactive formatting whose loss cannot change behavior.
        let attributed = rendered.runs.count > maximumRuns && links.isEmpty
            ? AttributedString(String(rendered.characters))
            : rendered
        return PreparedMarkdown(
            attributedText: attributed,
            sanitizedSource: sanitized,
            plainText: String(attributed.characters),
            linkURLs: links,
            performedOnMainThread: Thread.isMainThread,
            requestedPriority: requestedPriority
        )
    }

    private struct RenderContext {
        var intents: InlinePresentationIntent = []
        var headingLevel: Int?
        var link: URL?
        var isCode = false
        var isQuote = false

        func adding(_ intent: InlinePresentationIntent) -> Self {
            var copy = self
            copy.intents.formUnion(intent)
            return copy
        }

        func nativeStyle(
            syntaxColor: PreparedMarkdownNativeStyle.SyntaxColor? = nil
        ) -> PreparedMarkdownNativeStyle {
            PreparedMarkdownNativeStyle(
                headingLevel: headingLevel,
                isBold: intents.contains(.stronglyEmphasized),
                isItalic: intents.contains(.emphasized),
                isStrikethrough: intents.contains(.strikethrough),
                isCode: isCode || intents.contains(.code),
                isQuote: isQuote,
                syntaxColor: syntaxColor
            )
        }
    }

    private static func renderBlocks(
        _ blocks: [Markup],
        context: RenderContext,
        separator: String = "\n\n"
    ) -> AttributedString {
        joined(
            blocks.map { renderBlock($0, context: context) },
            separator: separator
        )
    }

    private static func renderBlock(
        _ markup: Markup,
        context: RenderContext
    ) -> AttributedString {
        switch markup {
        case let paragraph as Paragraph:
            return renderInlines(Array(paragraph.children), context: context)

        case let heading as Heading:
            var headingContext = context.adding(.stronglyEmphasized)
            headingContext.headingLevel = heading.level
            return renderInlines(Array(heading.children), context: headingContext)

        case let codeBlock as Markdown.CodeBlock:
            var codeContext = context.adding(.code)
            codeContext.isCode = true
            var result = AttributedString()
            if let language = codeBlock.language, !language.isEmpty {
                // The label is chrome, not content: styling it with the code
                // context painted the info string as the block's first line.
                var labelContext = context.adding(.stronglyEmphasized)
                labelContext.isCode = false
                result.append(styled(language, context: labelContext))
                result.append(AttributedString("\n"))
            }
            result.append(
                highlightedCode(
                    codeBlock.code,
                    language: codeBlock.language,
                    context: codeContext
                )
            )
            return result

        case let quote as BlockQuote:
            var quoteContext = context
            quoteContext.isQuote = true
            let body = renderBlocks(Array(quote.children), context: quoteContext)
            return prefixingLines(body, first: "│ ", continuation: "│ ")

        case let list as UnorderedList:
            return renderList(
                items: Array(list.children).compactMap { $0 as? ListItem },
                start: nil,
                context: context
            )

        case let list as OrderedList:
            return renderList(
                items: Array(list.children).compactMap { $0 as? ListItem },
                start: Int(list.startIndex),
                context: context
            )

        case let table as Markdown.Table:
            return renderTable(table, context: context)

        case is ThematicBreak:
            return styled("────────────────", context: context)

        case let html as HTMLBlock:
            return styled(html.rawHTML, context: context)

        default:
            return renderBlocks(Array(markup.children), context: context, separator: "\n")
        }
    }

    private static func renderList(
        items: [ListItem],
        start: Int?,
        context: RenderContext
    ) -> AttributedString {
        let rendered = items.enumerated().map { offset, item -> AttributedString in
            let checkbox: String
            switch item.checkbox {
            case .checked:
                checkbox = "[x] "
            case .unchecked:
                checkbox = "[ ] "
            case nil:
                checkbox = ""
            }
            let marker = start.map { "\($0 + offset). " } ?? "• "
            let body = renderBlocks(
                Array(item.children),
                context: context,
                separator: "\n"
            )
            return prefixingLines(
                body,
                first: marker + checkbox,
                continuation: String(repeating: " ", count: marker.count + checkbox.count)
            )
        }
        return joined(rendered, separator: "\n")
    }

    private static func renderTable(
        _ table: Markdown.Table,
        context: RenderContext
    ) -> AttributedString {
        let headerContext = context.adding(.stronglyEmphasized)
        let header = renderTableRow(
            Array(table.head.cells),
            context: headerContext
        )
        let body = Array(table.body.rows).map {
            renderTableRow(Array($0.cells), context: context)
        }
        var rows = [header]
        if !body.isEmpty {
            rows.append(styled("────────", context: context))
            rows.append(contentsOf: body)
        }
        return joined(rows, separator: "\n")
    }

    private static func renderTableRow(
        _ cells: [Markdown.Table.Cell],
        context: RenderContext
    ) -> AttributedString {
        joined(
            cells.map { renderInlines(Array($0.children), context: context) },
            separator: "  │  "
        )
    }

    private static func renderInlines(
        _ inlines: [Markup],
        context: RenderContext
    ) -> AttributedString {
        inlines.reduce(into: AttributedString()) { result, inline in
            result.append(renderInline(inline, context: context))
        }
    }

    private static func renderInline(
        _ markup: Markup,
        context: RenderContext
    ) -> AttributedString {
        switch markup {
        case let text as Markdown.Text:
            return styled(text.string, context: context)

        case is SoftBreak:
            return styled(" ", context: context)

        case is LineBreak:
            return styled("\n", context: context)

        case let code as InlineCode:
            var codeContext = context.adding(.code)
            codeContext.isCode = true
            return styled(code.code, context: codeContext)

        case let emphasis as Emphasis:
            return renderInlines(
                Array(emphasis.children),
                context: context.adding(.emphasized)
            )

        case let strong as Strong:
            return renderInlines(
                Array(strong.children),
                context: context.adding(.stronglyEmphasized)
            )

        case let strike as Strikethrough:
            return renderInlines(
                Array(strike.children),
                context: context.adding(.strikethrough)
            )

        case let link as Markdown.Link:
            var linkContext = context
            linkContext.link = link.destination.flatMap(safeLinkURL)
            return renderInlines(Array(link.children), context: linkContext)

        case let image as Markdown.Image:
            // MarkdownSafety normally rewrites every image before this parse.
            // Keep this defensive path textual so no renderer can fetch it.
            return styled("Image: \(image.plainText)", context: context)

        case let html as InlineHTML:
            return styled(html.rawHTML, context: context)

        default:
            return renderInlines(Array(markup.children), context: context)
        }
    }

    private static func safeLinkURL(_ destination: String) -> URL? {
        if let direct = URL(string: destination), direct.scheme != nil {
            switch ChatURLPolicy.classify(direct) {
            case .external, .repository:
                return direct
            case .blocked:
                return nil
            }
        }

        guard ChatURLPolicy.repositoryLink(from: destination) != nil,
              let base = URL(string: "\(ChatURLPolicy.repositoryScheme):///") else {
            return nil
        }
        let resolved = URL(string: destination, relativeTo: base)?.absoluteURL
        guard let resolved else { return nil }
        if case .repository = ChatURLPolicy.classify(resolved) {
            return resolved
        }
        return nil
    }

    private static func styled(
        _ string: String,
        context: RenderContext
    ) -> AttributedString {
        var result = AttributedString(string)
        if !context.intents.isEmpty {
            result.inlinePresentationIntent = context.intents
        }
        if let headingLevel = context.headingLevel {
            switch headingLevel {
            case 1:
                result.font = .title2.bold()
            case 2:
                result.font = .title3.bold()
            case 3:
                result.font = .headline.bold()
            default:
                result.font = .body.bold()
            }
        } else if context.isCode {
            result.font = .system(.body, design: .monospaced)
        }
        if context.isQuote {
            result.foregroundColor = .secondary
        }
        if let link = context.link {
            result.link = link
        }
        result.terminalRelayPreparedMarkdown.nativeStyle = context.nativeStyle()
        return result
    }

    /// Tokenization runs inside the same detached preparation task as the
    /// Markdown parse. The viewport still receives one immutable `Text` node,
    /// while completed fenced code keeps the syntax colors used elsewhere in
    /// the app.
    private static func highlightedCode(
        _ code: String,
        language: String?,
        context: RenderContext
    ) -> AttributedString {
        let tokens = ChatSyntaxHighlighter.tokens(for: code, language: language)
        guard tokens.count <= ChatSyntaxHighlighter.maximumHighlightedRuns else {
            return styled(code, context: context)
        }
        return tokens.reduce(
            into: AttributedString()
        ) { result, token in
            var piece = styled(token.text, context: context)
            let syntaxColor: PreparedMarkdownNativeStyle.SyntaxColor?
            switch token.kind {
            case .plain:
                syntaxColor = nil
            case .keyword:
                syntaxColor = .keyword
                piece.foregroundColor = .purple
            case .string:
                syntaxColor = .string
                piece.foregroundColor = .green
            case .comment:
                syntaxColor = .comment
                piece.foregroundColor = .secondary
            case .number:
                syntaxColor = .number
                piece.foregroundColor = .blue
            }
            piece.terminalRelayPreparedMarkdown.nativeStyle = context.nativeStyle(
                syntaxColor: syntaxColor
            )
            result.append(piece)
        }
    }

    private static func joined(
        _ values: [AttributedString],
        separator: String
    ) -> AttributedString {
        values.enumerated().reduce(into: AttributedString()) { result, pair in
            if pair.offset > 0 {
                result.append(AttributedString(separator))
            }
            result.append(pair.element)
        }
    }

    private static func prefixingLines(
        _ value: AttributedString,
        first: String,
        continuation: String
    ) -> AttributedString {
        guard !value.characters.isEmpty else { return AttributedString(first) }
        var result = AttributedString(first)
        var lineStart = value.startIndex
        while let newline = value.characters[lineStart...].firstIndex(of: "\n") {
            result.append(AttributedString(value[lineStart...newline]))
            lineStart = value.index(afterCharacter: newline)
            if lineStart < value.endIndex {
                result.append(AttributedString(continuation))
            }
        }
        if lineStart < value.endIndex {
            result.append(AttributedString(value[lineStart..<value.endIndex]))
        }
        return result
    }
}
#endif

struct RichMarkdownView: View {
    let text: String
    var exactFallbackText: String? = nil
    let isStreaming: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.chatRowActions) private var actions

    @State private var source = StreamingMarkdownSource()
    @State private var didFinishStreaming = false

    @ViewBuilder
    var body: some View {
        let onOpenExternal: (URL) -> Void = { openURL($0) }
        let onOpenRepository: (ChatRepositoryLink) -> Void = { actions.openRepository($0) }

        #if os(macOS)
        if !isStreaming, !MarkdownSafety.containsTableCandidate(text) {
            // A completed macOS row is already one prepared attributed Text.
            // Do not wrap it in the MarkdownView renderer/style environment;
            // those modifiers cannot affect it and add cold-host graph work.
            // Rows carrying a table stay on the styled MarkdownView path so
            // the table renders as a grid rather than flattened text.
            PreparedMarkdownText(
                source: text,
                fallbackText: exactFallbackText ?? text,
                cached: SanitizedMarkdownCache.shared.lookupPrepared(raw: text)
            )
                .environment(
                    \.openURL,
                    safeOpenURLAction(
                        onOpenExternal: onOpenExternal,
                        onOpenRepository: onOpenRepository
                    )
                )
        } else {
            configuredMarkdownContent(
                onOpenExternal: onOpenExternal,
                onOpenRepository: onOpenRepository
            )
        }
        #else
        configuredMarkdownContent(
            onOpenExternal: onOpenExternal,
            onOpenRepository: onOpenRepository
        )
        #endif
    }

    private func configuredMarkdownContent(
        onOpenExternal: @escaping (URL) -> Void,
        onOpenRepository: @escaping (ChatRepositoryLink) -> Void
    ) -> some View {
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
                safeOpenURLAction(
                    onOpenExternal: onOpenExternal,
                    onOpenRepository: onOpenRepository
                )
            )
            .textSelection(.enabled)
    }

    private func safeOpenURLAction(
        onOpenExternal: @escaping (URL) -> Void,
        onOpenRepository: @escaping (ChatRepositoryLink) -> Void
    ) -> OpenURLAction {
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
    }

    /// Completed macOS rows bind a prepared attributed artifact and never
    /// parse Markdown while entering the viewport. iOS retains its existing
    /// sanitized Markdown path.
    @ViewBuilder
    private var markdownContent: some View {
        #if os(macOS)
        streamingMarkdownContent
        #else
        if !isStreaming,
           let sanitized = SanitizedMarkdownCache.shared.lookup(raw: text) {
            SegmentedMarkdownContent(sanitized: sanitized)
        } else {
            streamingMarkdownContent
        }
        #endif
    }

    private var streamingMarkdownContent: some View {
        StreamingMarkdownReader(source) { parseResult in
            MarkdownView(parseResult)
        }
        .markdownStreamingRenderThrottle(.milliseconds(33))
        .task(id: MarkdownRenderInput(text: text, isStreaming: isStreaming)) {
            await synchronizeSource()
        }
    }

    private func synchronizeSource() async {
        let result = await MarkdownSafety.sanitizedSourceOffMain(text)
        guard !Task.isCancelled else { return }
        if !isStreaming {
            SanitizedMarkdownCache.shared.insert(raw: text, sanitized: result.source)
        }
        let displayed = result.source
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

#if os(macOS)
private struct PreparedMarkdownText: View {
    let source: String
    let fallbackText: String

    @State private var prepared: PreparedMarkdown?
    @State private var preparedSource: String?
    @Environment(\.macTranscriptScrollActivity) private var scrollActivity

    init(
        source: String,
        fallbackText: String,
        cached: PreparedMarkdown?
    ) {
        self.source = source
        self.fallbackText = fallbackText
        _prepared = State(initialValue: cached)
        _preparedSource = State(initialValue: cached == nil ? nil : source)
    }

    var body: some View {
        Group {
            if let prepared = resolvedPrepared {
                Text(prepared.attributedText)
            } else {
                // A cold live-completion miss remains fully visible while its
                // final artifact is prepared. This is verbatim text only: it
                // cannot parse Markdown or load an image on the main thread.
                Text(verbatim: fallbackText)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
        .task(id: source) {
            guard preparedSource != source || prepared == nil else {
                return
            }
            let result = await SanitizedMarkdownCache.shared.preparedMarkdown(raw: source)
            guard let result, !Task.isCancelled else { return }
            await scrollActivity.adoptHeightChangingContentWhenIdle {
                prepared = result
                preparedSource = source
            }
        }
    }

    private var resolvedPrepared: PreparedMarkdown? {
        if preparedSource == source {
            return prepared
        }
        return nil
    }
}
#endif

/// Completed iOS Markdown rendered in bounded parsing units so an individual
/// hierarchy remains shallow. macOS uses `PreparedMarkdownText` instead.
private struct SegmentedMarkdownContent: View {
    let sanitized: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(
                Array(
                    MarkdownSegmentation.segments(of: sanitized)
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
                usesHighlighting: !isStreaming && language?.isEmpty == false
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
    #if os(macOS)
    @Environment(\.macTranscriptScrollActivity) private var scrollActivity
    #endif

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
            #if os(macOS)
            await scrollActivity.adoptHeightChangingContentWhenIdle {
                highlighted = Self.attributedText(result.tokens)
            }
            #else
            highlighted = Self.attributedText(result.tokens)
            #endif
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
    // Styling is optional but text is not. A bounded tile with hundreds of
    // alternating attributes still makes TextKit shape hundreds of runs on
    // the main thread, so preserve the exact code as one plain token above a
    // small density budget.
    static let maximumHighlightedRuns = 64

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
                let plain = source.substring(
                    with: NSRange(
                        location: location,
                        length: match.range.location - location
                    )
                )
                guard appendBounded(plain, kind: .plain, to: &tokens) else {
                    return [ChatCodeToken(text: code, kind: .plain)]
                }
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
            guard appendBounded(value, kind: kind, to: &tokens) else {
                return [ChatCodeToken(text: code, kind: .plain)]
            }
            location = NSMaxRange(match.range)
        }
        if location < source.length {
            guard appendBounded(
                source.substring(from: location),
                kind: .plain,
                to: &tokens
            ) else {
                return [ChatCodeToken(text: code, kind: .plain)]
            }
        }
        return tokens
    }

    private static func appendBounded(
        _ text: String,
        kind: ChatCodeToken.Kind,
        to tokens: inout [ChatCodeToken]
    ) -> Bool {
        guard !text.isEmpty else { return true }
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1] = ChatCodeToken(
                text: last.text + text,
                kind: kind
            )
        } else {
            tokens.append(ChatCodeToken(text: text, kind: kind))
        }
        return tokens.count <= maximumHighlightedRuns
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
