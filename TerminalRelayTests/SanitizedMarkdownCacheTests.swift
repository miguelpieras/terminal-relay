import AppKit
import XCTest
@testable import TerminalRelay

private actor PreparationConcurrencyProbe {
    private var active = 0
    private var peak = 0

    func begin() {
        active += 1
        peak = max(peak, active)
    }

    func end() {
        active -= 1
    }

    func peakValue() -> Int {
        peak
    }

    func activeValue() -> Int {
        active
    }
}

@MainActor
final class SanitizedMarkdownCacheTests: XCTestCase {
    func testWarmSanitizesBeforeInsertionAndLookupReturnsSanitizedText() async {
        let cache = SanitizedMarkdownCache()
        let hostile = "Before <script>alert(1)</script> ![x](javascript:alert(2)) after"

        XCTAssertNil(cache.lookup(raw: hostile))
        await cache.warm(texts: [hostile], budget: .seconds(5))

        let sanitized = cache.lookup(raw: hostile)
        XCTAssertNotNil(sanitized)
        XCTAssertEqual(sanitized, MarkdownSafety.sanitizedSource(hostile))
        XCTAssertFalse(sanitized?.contains("<script>") ?? true)
        XCTAssertNotNil(cache.lookupPrepared(raw: hostile))
        XCTAssertFalse(cache.lookupPrepared(raw: hostile)?.performedOnMainThread ?? true)
    }

    func testWarmSkipsEmptyAndAlreadyPreparedTexts() async {
        let cache = SanitizedMarkdownCache()
        _ = await cache.preparedMarkdown(raw: "cached")
        let initialPreparations = cache.preparationCount

        await cache.warm(
            texts: ["", "cached", "fresh **text**", "fresh **text**", "cached"],
            budget: .seconds(5)
        )

        XCTAssertEqual(cache.lookup(raw: "cached"), "cached")
        XCTAssertEqual(
            cache.lookup(raw: "fresh **text**"),
            MarkdownSafety.sanitizedSource("fresh **text**")
        )
        XCTAssertNil(cache.lookup(raw: ""))
        XCTAssertEqual(
            cache.preparationCount,
            initialPreparations + 1,
            "Warming must deduplicate before starting detached preparation work."
        )
    }

    func testPreparationGateDeterministicallyLimitsConcurrentWorkToTwo() async {
        let gate = MarkdownPreparationGate(maxConcurrent: 2)
        let probe = PreparationConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    await gate.run(
                        priority: index.isMultiple(of: 3) ? .userInitiated : .utility
                    ) {
                        await probe.begin()
                        try? await Task.sleep(for: .milliseconds(20))
                        await probe.end()
                    }
                }
            }
        }

        let peak = await probe.peakValue()
        XCTAssertEqual(MarkdownPreparationGate.shared.maximumConcurrent, 2)
        XCTAssertEqual(peak, 2)
    }

    func testCancelledQueuedPreparationNeverConsumesAPermit() async {
        let gate = MarkdownPreparationGate(maxConcurrent: 1)
        let probe = PreparationConcurrencyProbe()
        let blocker = Task {
            await gate.run(priority: .utility) {
                await probe.begin()
                try? await Task.sleep(for: .seconds(5))
                await probe.end()
                return true
            }
        }
        while await probe.activeValue() == 0 {
            await Task.yield()
        }

        let queuedRan = PreparationConcurrencyProbe()
        let queued = Task {
            await gate.run(priority: .userInitiated) {
                await queuedRan.begin()
                await queuedRan.end()
                return true
            }
        }
        await Task.yield()
        queued.cancel()
        let queuedResult = await queued.value
        blocker.cancel()
        _ = await blocker.value

        XCTAssertNil(queuedResult)
        let queuedPeak = await queuedRan.peakValue()
        XCTAssertEqual(queuedPeak, 0)
    }

    func testWarmUsesUtilityPriorityWhileVisibleMissUsesUserInitiated() async {
        let cache = SanitizedMarkdownCache()

        await cache.warm(texts: ["background"], budget: .seconds(5))
        let visible = await cache.preparedMarkdown(raw: "visible")

        XCTAssertEqual(
            cache.lookupPrepared(raw: "background")?.requestedPriority,
            .utility
        )
        XCTAssertEqual(visible?.requestedPriority, .userInitiated)
    }

    func testPreparedMarkdownPreservesCommonSemanticsAsOneCompleteTextArtifact() async {
        let source = """
        # Primary heading

        Paragraph with *emphasis*, **strong**, ~~removed~~, and `inlineCode`.

        - first bullet
        - second bullet

        3. ordered three
        4. ordered four

        > quoted words

        ---

        ```swift
        let complete = true
        ```

        | Name | Value |
        | --- | --- |
        | alpha | beta |

        ![diagram](https://example.com/diagram.png)
        """

        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        XCTAssertFalse(prepared.performedOnMainThread)
        for expected in [
            "Primary heading", "emphasis", "strong", "removed", "inlineCode",
            "• first bullet", "• second bullet", "3. ordered three", "4. ordered four",
            "│ quoted words", "swift", "let complete = true", "Name", "Value",
            "alpha", "beta", "Image: diagram",
        ] {
            XCTAssertTrue(
                prepared.plainText.contains(expected),
                "Prepared text omitted semantic content: \(expected)"
            )
        }
        XCTAssertTrue(prepared.plainText.contains("────────────────"))
        XCTAssertTrue(prepared.plainText.contains("│"), "Tables remain readable as delimited text.")
        XCTAssertFalse(prepared.sanitizedSource.contains("!["), "Images must become text/link affordances.")

        let intents = prepared.attributedText.runs.compactMap(\.inlinePresentationIntent)
        XCTAssertTrue(intents.contains { $0.contains(.emphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.stronglyEmphasized) })
        XCTAssertTrue(intents.contains { $0.contains(.strikethrough) })
        XCTAssertTrue(intents.contains { $0.contains(.code) })
    }

    func testPreparedMarkdownOnlyActivatesLinksAcceptedByChatPolicy() async {
        let source = """
        [web](https://example.com/path)
        [repository](Sources/App.swift:9)
        [credentials](https://user:pass@example.com/private)
        [script](javascript:alert(1))
        [traversal](../Secrets.swift)
        """

        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        XCTAssertEqual(prepared.linkURLs.count, 2)
        XCTAssertTrue(prepared.linkURLs.contains(URL(string: "https://example.com/path")!))
        XCTAssertTrue(
            prepared.linkURLs.contains {
                if case .repository(let link) = ChatURLPolicy.classify($0) {
                    return link == ChatRepositoryLink(path: "Sources/App.swift", line: 9, column: nil)
                }
                return false
            }
        )
        XCTAssertTrue(prepared.linkURLs.allSatisfy {
            if case .blocked = ChatURLPolicy.classify($0) { return false }
            return true
        })
    }

    func testPreparedMarkdownCacheHitDoesNotReparse() async {
        let cache = SanitizedMarkdownCache()
        let source = "# Cached\n\nA **prepared** row."

        let first = await cache.preparedMarkdown(raw: source)
        let countAfterMiss = cache.preparationCount
        let second = await cache.preparedMarkdown(raw: source)

        XCTAssertEqual(countAfterMiss, 1)
        XCTAssertEqual(cache.preparationCount, countAfterMiss)
        XCTAssertEqual(second?.plainText, first?.plainText)
        XCTAssertNotNil(cache.lookupPrepared(raw: source))
    }

    func testConcurrentVisibleAndPrefetchMissesShareOnePreparation() async {
        let cache = SanitizedMarkdownCache()
        let source = "# Shared miss\n\n" + String(repeating: "bounded text ", count: 40)

        let values = await withTaskGroup(
            of: PreparedMarkdown?.self,
            returning: [PreparedMarkdown?].self
        ) { group in
            for priority in [TaskPriority.utility, .userInitiated, .utility] {
                group.addTask {
                    await cache.preparedMarkdown(raw: source, priority: priority)
                }
            }
            var results: [PreparedMarkdown?] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(values.count, 3)
        let expected = values.compactMap { $0?.plainText }.first
        XCTAssertNotNil(expected)
        XCTAssertTrue(values.allSatisfy { $0?.plainText == expected })
        XCTAssertEqual(
            cache.preparationCount,
            1,
            "A cell miss must join viewport prefetch instead of occupying a second parser permit."
        )
    }

    func testPreparedMarkdownCachesOneNativeTextKitArtifactWithNativeAttributes() async {
        let source = "# Heading\n\nText with **bold**, `code`, and [link](https://example.com)."
        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        let first = prepared.appKitAttributedText()
        let second = prepared.appKitAttributedText()

        XCTAssertTrue(
            first === second,
            "Revisiting a native row must reuse the immutable TextKit artifact."
        )
        XCTAssertEqual(first.string, prepared.plainText)
        XCTAssertNotNil(first.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertNil(
            first.attribute(
                NSAttributedString.Key("SwiftUI.Font"),
                at: 0,
                effectiveRange: nil
            ),
            "Native rows must not pass SwiftUI-only font attributes into TextKit."
        )
        let linkRange = (first.string as NSString).range(of: "link")
        XCTAssertEqual(
            first.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL,
            URL(string: "https://example.com")
        )
    }

    func testPreparedNativeArtifactCacheTracksDynamicTypeScale() async {
        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(
            "# Heading\n\nScaled body text"
        ) else {
            return XCTFail("Expected prepared Markdown")
        }

        let regular = prepared.appKitAttributedText(fontScale: 1)
        let regularFont = regular.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont
        let accessibility = prepared.appKitAttributedText(fontScale: 2)
        let repeatedAccessibility = prepared.appKitAttributedText(fontScale: 2)
        let accessibilityFont = accessibility.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? NSFont

        XCTAssertFalse(regular === accessibility)
        XCTAssertTrue(accessibility === repeatedAccessibility)
        XCTAssertGreaterThan(
            accessibilityFont?.pointSize ?? 0,
            regularFont?.pointSize ?? .infinity
        )
        XCTAssertNil(
            prepared.cachedAppKitAttributedText(fontScale: 1),
            "A stale font-scale artifact must never survive a Dynamic Type reconfiguration."
        )
    }

    func testPreparedMarkdownHandlesLargeBoundedChunkWithoutLosingText() async {
        let lines = (1...80).map { "bounded-line-\($0)" }
        let source = lines.joined(separator: "\n")
        XCTAssertLessThan(source.utf8.count, 4_096)

        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        for line in lines {
            XCTAssertTrue(prepared.plainText.contains(line))
        }
        XCTAssertLessThan(prepared.estimatedCacheCost, 64 * 1_024)
    }

    func testHighTokenDensityFallsBackToOnePlainCodeRunWithoutLosingTextOrLinks() async {
        let code = String(repeating: "let value = 42; ", count: 180)
        let tokens = ChatSyntaxHighlighter.tokens(for: code, language: "swift")

        XCTAssertEqual(
            tokens,
            [ChatCodeToken(text: code, kind: .plain)],
            "More than the bounded styled-run budget must collapse to one exact plain token."
        )

        let safeURL = URL(string: "https://example.com/dense")!
        let source = "```swift\n\(code)\n```\n\n[safe](\(safeURL.absoluteString))"
        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        XCTAssertTrue(prepared.plainText.contains(code))
        XCTAssertEqual(prepared.linkURLs, [safeURL])
        XCTAssertLessThanOrEqual(
            prepared.attributedText.runs.count,
            8,
            "The prepared artifact must not recreate token-density as attributed runs."
        )
    }

    func testLineDenseRichMarkdownCollapsesRunsWithoutLosingRenderedText() async {
        let source = (0..<120)
            .map { $0.isMultiple(of: 2) ? "**bold-\($0)**" : "plain-\($0)" }
            .joined(separator: "\n")
        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        for index in 0..<120 {
            XCTAssertTrue(prepared.plainText.contains("\(index)"))
        }
        XCTAssertLessThanOrEqual(
            prepared.attributedText.runs.count,
            16,
            "Line-dense formatting must not recreate a cold-layout hitch."
        )
    }

    func testLineDenseMarkdownKeepsEverySafeLinkInteractive() async {
        let source = (0..<40)
            .map { "[f\($0)](https://e.co/\($0))" }
            .joined(separator: "\n")
        XCTAssertLessThanOrEqual(
            source.utf8.count,
            TranscriptRowProjection.maximumDisplayBytes
        )
        guard let prepared = await PreparedMarkdownRenderer.prepareOffMain(source) else {
            return XCTFail("Expected prepared Markdown")
        }

        XCTAssertEqual(prepared.linkURLs.count, 40)
        XCTAssertEqual(prepared.attributedText.runs.compactMap(\.link).count, 40)
        for index in 0..<40 {
            XCTAssertTrue(prepared.plainText.contains("f\(index)"))
        }
    }

    func testDefaultCacheEntryLimitCoversWorstCaseLineBoundedTranscript() {
        let retainedTextBudget = 8 * 1_048_576
        // Markdown projection reserves two rendered lines for fence
        // continuation. A full all-newline source tile therefore contains
        // `maximumDisplayLines - 3` retained bytes.
        let sourceBytesPerFullLineBoundedTile =
            TranscriptRowProjection.maximumDisplayLines - 3
        let worstCaseTileCount = (
            retainedTextBudget + sourceBytesPerFullLineBoundedTile - 1
        ) / sourceBytesPerFullLineBoundedTile

        XCTAssertGreaterThanOrEqual(
            SanitizedMarkdownCache.defaultCountLimit,
            worstCaseTileCount
        )
        XCTAssertEqual(
            SanitizedMarkdownCache.defaultTotalCostLimit,
            96 * 1_024 * 1_024,
            "Entry capacity must not weaken the independent memory-cost ceiling."
        )
    }

    func testDefaultCacheRetainsMoreThanEightMiBOfProductionTilesWithoutReparse() async {
        let cache = SanitizedMarkdownCache()
        let retainedTextBudget = 8 * 1_024 * 1_024
        let tileBytes = TranscriptRowProjection.maximumDisplayBytes
        let tileCount = (retainedTextBudget / tileBytes) + 64
        let tiles = (0..<tileCount).map { index -> String in
            let prefix = "tile-\(index)-"
            return prefix + String(repeating: "x", count: tileBytes - prefix.utf8.count)
        }
        XCTAssertGreaterThan(tiles.reduce(0) { $0 + $1.utf8.count }, retainedTextBudget)

        await cache.warm(texts: tiles, budget: .seconds(60))
        let countAfterWarm = cache.preparationCount

        XCTAssertEqual(countAfterWarm, tileCount)
        XCTAssertTrue(tiles.allSatisfy { cache.lookupPrepared(raw: $0) != nil })
        for tile in tiles {
            _ = await cache.preparedMarkdown(raw: tile)
        }
        XCTAssertEqual(
            cache.preparationCount,
            countAfterWarm,
            "A full-budget back-scroll must hit prepared artifacts instead of parsing again."
        )
    }

    func testWarmableTextsMirrorsTranscriptMarkdownRouting() {
        var userMessage = ChatMessage(
            id: "user-1",
            role: .user,
            text: "user plain text"
        )
        userMessage.contents[0].kind = .plainText

        let items: [ConversationItem] = [
            .message(
                ChatMessage(
                    id: "assistant-1",
                    role: .assistant,
                    text: "assistant markdown"
                )
            ),
            .message(userMessage),
            .message(
                ChatMessage(
                    id: "assistant-streaming",
                    role: .assistant,
                    text: "still streaming",
                    isStreaming: true
                )
            ),
            .tool(
                ToolActivity(
                    id: "tool-1",
                    turnID: nil,
                    kind: .shell,
                    title: "Run",
                    status: .completed,
                    input: "ls",
                    output: "ok",
                    errorMessage: nil,
                    durationMilliseconds: 1,
                    exitCode: 0,
                    occurredAt: 0,
                    isTruncated: false,
                    originalByteCount: nil
                )
            ),
        ]

        XCTAssertEqual(
            SanitizedMarkdownCache.warmableTexts(items: items),
            ["assistant markdown"],
            "Only completed non-user rich-markdown content should warm."
        )
    }

    func testWarmableTextSuffixMatchesFullProjectionWithoutRetainingEveryTile() {
        let source = (0..<2_000).map { "line-\($0)" }.joined(separator: "\n")
        let items: [ConversationItem] = [
            .message(ChatMessage(id: "older", role: .assistant, text: "older")),
            .message(ChatMessage(id: "recent", role: .assistant, text: source)),
        ]
        let all = SanitizedMarkdownCache.warmableTexts(items: items)
        let suffix = SanitizedMarkdownCache.warmableTexts(
            items: items,
            suffixLimit: 5
        )

        XCTAssertEqual(suffix, Array(all.suffix(5)))
        XCTAssertEqual(suffix.count, 5)
    }
}
