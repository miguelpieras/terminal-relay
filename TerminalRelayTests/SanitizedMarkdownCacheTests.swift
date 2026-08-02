import XCTest
@testable import TerminalRelay

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
    }

    func testWarmSkipsEmptyAndAlreadyCachedTexts() async {
        let cache = SanitizedMarkdownCache()
        cache.insert(raw: "cached", sanitized: "already sanitized")

        await cache.warm(texts: ["", "cached", "fresh **text**"], budget: .seconds(5))

        XCTAssertEqual(cache.lookup(raw: "cached"), "already sanitized")
        XCTAssertEqual(
            cache.lookup(raw: "fresh **text**"),
            MarkdownSafety.sanitizedSource("fresh **text**")
        )
        XCTAssertNil(cache.lookup(raw: ""))
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
