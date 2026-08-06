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

        await cache.warm(texts: ["", "cached", "fresh **text**"], budget: .seconds(5))

        XCTAssertEqual(cache.lookup(raw: "cached"), "cached")
        XCTAssertEqual(
            cache.lookup(raw: "fresh **text**"),
            MarkdownSafety.sanitizedSource("fresh **text**")
        )
        XCTAssertNil(cache.lookup(raw: ""))
        XCTAssertEqual(cache.preparationCount, initialPreparations + 1)
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

    func testWarmUsesUtilityPriorityWhileVisibleMissUsesUserInitiated() async {
        let cache = SanitizedMarkdownCache()

        await cache.warm(texts: ["background"], budget: .seconds(5))
        let visible = await cache.preparedMarkdown(raw: "visible")

        XCTAssertEqual(
            cache.lookupPrepared(raw: "background")?.requestedPriority,
            .utility
        )
        XCTAssertEqual(visible.requestedPriority, .userInitiated)
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

        let prepared = await PreparedMarkdownRenderer.prepareOffMain(source)

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

        let prepared = await PreparedMarkdownRenderer.prepareOffMain(source)

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
        XCTAssertEqual(second.plainText, first.plainText)
        XCTAssertNotNil(cache.lookupPrepared(raw: source))
    }

    func testPreparedMarkdownHandlesLargeBoundedChunkWithoutLosingText() async {
        let lines = (1...80).map { "bounded-line-\($0)" }
        let source = lines.joined(separator: "\n")
        XCTAssertLessThan(source.utf8.count, 4_096)

        let prepared = await PreparedMarkdownRenderer.prepareOffMain(source)

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
            "More than 512 styled runs must collapse to one exact plain token."
        )

        let safeURL = URL(string: "https://example.com/dense")!
        let source = "```swift\n\(code)\n```\n\n[safe](\(safeURL.absoluteString))"
        let prepared = await PreparedMarkdownRenderer.prepareOffMain(source)

        XCTAssertTrue(prepared.plainText.contains(code))
        XCTAssertEqual(prepared.linkURLs, [safeURL])
        XCTAssertLessThanOrEqual(
            prepared.attributedText.runs.count,
            8,
            "The prepared artifact must not recreate token-density as attributed runs."
        )
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

    func testDefaultCacheRetainsMoreThanEightMiBOfFourKiBTilesWithoutReparse() async {
        let cache = SanitizedMarkdownCache()
        let tileCount = 2_100
        let tileBytes = 4_096
        let tiles = (0..<tileCount).map { index -> String in
            let prefix = "tile-\(index)-"
            return prefix + String(repeating: "x", count: tileBytes - prefix.utf8.count)
        }
        XCTAssertGreaterThan(tiles.reduce(0) { $0 + $1.utf8.count }, 8 * 1_024 * 1_024)

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
}
