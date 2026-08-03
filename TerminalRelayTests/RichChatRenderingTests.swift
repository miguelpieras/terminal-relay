import XCTest
@testable import TerminalRelay

final class RichChatRenderingTests: XCTestCase {
    func testSharedInteractionTargetPolicyPreservesCompactMacLayout() {
        XCTAssertEqual(ChatInteractionTargetLayout.minimumIOSDimension, 44)
        XCTAssertFalse(ChatInteractionTargetLayout.appliesMinimumDimension)
        XCTAssertEqual(ChatInteractionTargetLayout.jumpButtonDimension, 28)
        XCTAssertEqual(ChatInteractionTargetLayout.jumpButtonOuterPadding, 16)
        XCTAssertEqual(ChatInteractionTargetLayout.codeHeaderVerticalPadding, 9)
        XCTAssertEqual(ChatInteractionTargetLayout.compactControlVerticalPadding, 3)
        XCTAssertEqual(ChatInteractionTargetLayout.attachmentChipVerticalPadding, 6)
    }

    func testScrollControllerAnchorsUntilGeometryConfirmsBottomThenFollows() {
        var controller = ConversationScrollController()
        XCTAssertTrue(controller.isAnchoring)
        XCTAssertEqual(controller.accessibilityValue, "latest")

        XCTAssertEqual(
            controller.geometryChanged(isAtBottom: false),
            .instant,
            "Anchoring must keep correcting while layout settles off-bottom."
        )
        XCTAssertEqual(
            controller.geometryChanged(isAtBottom: false),
            .instant,
            "Corrections repeat for every off-bottom geometry change."
        )
        XCTAssertNil(controller.geometryChanged(isAtBottom: true))
        XCTAssertFalse(controller.isAnchoring)
        XCTAssertEqual(controller.state, .following)

        XCTAssertNil(
            controller.geometryChanged(isAtBottom: true),
            "No scroll writes while measurably at the bottom, so the system anchor stays engaged."
        )
        XCTAssertEqual(
            controller.geometryChanged(isAtBottom: false),
            .instant,
            "Follow mode corrects drift while pinned."
        )
    }

    func testScrollControllerStartsFollowingWhenContentAlreadyLoaded() {
        var controller = ConversationScrollController(startsAnchored: false)
        XCTAssertFalse(controller.isAnchoring)
        XCTAssertEqual(
            controller.state,
            .following,
            "A transcript restored with items positions on its first layout and must never hide behind an anchoring curtain."
        )
        XCTAssertNil(controller.geometryChanged(isAtBottom: true))
    }

    func testScrollControllerGivesUsersTheViewportAndNeverStealsItBack() {
        var controller = ConversationScrollController()
        _ = controller.geometryChanged(isAtBottom: true)
        XCTAssertEqual(controller.state, .following)

        controller.userScrollBegan()
        XCTAssertEqual(controller.state, .browsing)
        XCTAssertEqual(controller.accessibilityValue, "history")

        XCTAssertNil(
            controller.geometryChanged(isAtBottom: false),
            "Browsing must emit nothing for any geometry input."
        )
        XCTAssertNil(controller.geometryChanged(isAtBottom: true))

        XCTAssertNil(
            controller.userScrollEnded(distanceFromBottom: 500),
            "Releasing far from the bottom keeps the user in control."
        )
        XCTAssertEqual(controller.state, .browsing)

        XCTAssertEqual(
            controller.userScrollEnded(distanceFromBottom: 30),
            .animatedSettle,
            "Releasing just short of the bottom settles once, with animation."
        )
        XCTAssertEqual(controller.state, .animating)

        XCTAssertNil(controller.animationEnded(distanceFromBottom: 0))
        XCTAssertEqual(controller.state, .following)

        controller.userScrollBegan()
        XCTAssertNil(
            controller.userScrollEnded(distanceFromBottom: 4),
            "Releasing at the bottom re-engages following without a scroll write."
        )
        XCTAssertEqual(controller.state, .following)
    }

    func testScrollControllerWheelPausesNeverPullTheViewport() {
        var controller = ConversationScrollController()
        _ = controller.geometryChanged(isAtBottom: true)

        controller.userScrollBegan()
        controller.wheelScrollEnded(isAtBottom: false)
        XCTAssertEqual(
            controller.state,
            .browsing,
            "A wheel pause near the bottom must not drag the user back down."
        )

        controller.wheelScrollEnded(isAtBottom: true)
        XCTAssertEqual(
            controller.state,
            .following,
            "Resting exactly at the bottom re-engages following silently."
        )
    }

    func testScrollControllerJumpSuppressesCorrectionsUntilTheAnimationEnds() {
        var controller = ConversationScrollController()
        _ = controller.geometryChanged(isAtBottom: true)
        controller.userScrollBegan()
        _ = controller.userScrollEnded(distanceFromBottom: 700)

        XCTAssertEqual(controller.jumpRequested(), .animatedJump)
        XCTAssertEqual(controller.state, .animating)
        XCTAssertEqual(controller.accessibilityValue, "latest")

        XCTAssertNil(
            controller.geometryChanged(isAtBottom: false),
            "Mid-animation geometry must not stomp the eased scroll."
        )

        XCTAssertEqual(
            controller.animationEnded(distanceFromBottom: 24),
            .instant,
            "A short landing gets exactly one instant correction."
        )
        XCTAssertEqual(controller.state, .following)

        _ = controller.jumpRequested()
        controller.userScrollBegan()
        XCTAssertEqual(
            controller.state,
            .browsing,
            "A user gesture cancels an in-flight jump immediately."
        )
    }

    func testScrollControllerSelfHealsWhenAnimationPhasesNeverReport() {
        var controller = ConversationScrollController()
        _ = controller.geometryChanged(isAtBottom: true)
        controller.userScrollBegan()
        _ = controller.userScrollEnded(distanceFromBottom: 30)
        XCTAssertEqual(controller.state, .animating)

        XCTAssertNil(controller.geometryChanged(isAtBottom: false))
        XCTAssertNil(
            controller.geometryChanged(isAtBottom: true),
            "Reaching the bottom completes the animation state without a phase callback."
        )
        XCTAssertEqual(controller.state, .following)
    }

    func testScrollControllerReanchorsWhenContentLoadsUnlessUserIsBrowsing() {
        var controller = ConversationScrollController()
        _ = controller.geometryChanged(isAtBottom: true)
        XCTAssertEqual(controller.state, .following)

        XCTAssertEqual(
            controller.contentLoaded(),
            .instant,
            "Fresh content gets one deterministic backstop pin."
        )
        XCTAssertTrue(controller.isAnchoring)

        controller.userScrollBegan()
        XCTAssertNil(
            controller.contentLoaded(),
            "Content arriving mid-gesture must not re-anchor."
        )
        XCTAssertEqual(controller.state, .browsing)

        _ = controller.userScrollEnded(distanceFromBottom: 0)
        _ = controller.contentLoaded()
        controller.completeAnchor()
        XCTAssertEqual(
            controller.state,
            .following,
            "The anchoring failsafe always lands in following."
        )
    }

    func testComposerReturnPolicyKeepsPlainReturnAsNewlineAndCommandReturnAsSend() {
        XCTAssertEqual(
            ComposerInputPolicy.returnAction(
                commandKeyPressed: false,
                canSend: true
            ),
            .insertNewline
        )
        XCTAssertEqual(
            ComposerInputPolicy.returnAction(
                commandKeyPressed: true,
                canSend: true
            ),
            .send
        )
        XCTAssertEqual(
            ComposerInputPolicy.returnAction(
                commandKeyPressed: true,
                canSend: false
            ),
            .ignore
        )
    }

    func testDoubleEscapePolicyIsTurnAwareAndSuppressesDuplicates() {
        var policy = ComposerEscapePolicy()

        XCTAssertEqual(
            policy.action(activeTurnID: nil, timestamp: 10, isRepeat: false),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11, isRepeat: false),
            .armed
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11.2, isRepeat: true),
            .ignored
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11.02, isRepeat: false),
            .ignored,
            "A duplicate delivery from the same physical press must not interrupt."
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11.3, isRepeat: false),
            .interrupt
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11.32, isRepeat: false),
            .ignored,
            "Duplicate delivery immediately after dispatch must not rearm."
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11.5, isRepeat: false),
            .armed,
            "A rejected interrupt can be retried with a fresh deliberate sequence."
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-1", timestamp: 11.8, isRepeat: false),
            .interrupt
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-2", timestamp: 12, isRepeat: false),
            .armed,
            "A different active turn starts a fresh double-Escape sequence."
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-2", timestamp: 12.9, isRepeat: false),
            .armed,
            "An expired sequence rearms instead of interrupting."
        )
        XCTAssertEqual(
            policy.action(activeTurnID: "turn-2", timestamp: 13.1, isRepeat: false),
            .interrupt
        )
    }

    func testEscapeRouterConsumesOnlyActiveTurnEscapesAndRoutesOneInterruptPerSequence() {
        var router = ComposerEscapeRouter()

        XCTAssertEqual(
            router.route(activeTurnID: nil, timestamp: 30, isRepeat: false),
            .passThrough
        )
        XCTAssertEqual(
            router.route(activeTurnID: "turn-1", timestamp: 31, isRepeat: false),
            .consume
        )
        XCTAssertEqual(
            router.route(activeTurnID: "turn-1", timestamp: 31.01, isRepeat: false),
            .consume,
            "Duplicate ancestor delivery remains consumed without interrupting."
        )
        XCTAssertEqual(
            router.route(activeTurnID: "turn-1", timestamp: 31.3, isRepeat: false),
            .interrupt
        )
        XCTAssertEqual(
            router.route(activeTurnID: "turn-1", timestamp: 31.31, isRepeat: false),
            .consume
        )
        XCTAssertEqual(
            router.route(activeTurnID: "turn-1", timestamp: 31.6, isRepeat: false),
            .consume
        )
        XCTAssertEqual(
            router.route(activeTurnID: "turn-1", timestamp: 31.9, isRepeat: false),
            .interrupt,
            "The same active turn can retry after a rejected interrupt."
        )
    }

    func testExternalLinksAllowOnlyExplicitCredentialFreeHTTPDestinations() throws {
        let safeHTTP = try XCTUnwrap(URL(string: "http://example.com/docs?q=chat#streaming"))
        let safeHTTPS = try XCTUnwrap(URL(string: "https://example.com/docs"))
        XCTAssertEqual(ChatURLPolicy.classify(safeHTTP), .external(safeHTTP))
        XCTAssertEqual(ChatURLPolicy.classify(safeHTTPS), .external(safeHTTPS))

        let blockedValues = [
            "javascript:alert(1)",
            "data:text/html,<script>alert(1)</script>",
            "file:///etc/passwd",
            "mailto:hello@example.com",
            "https://user:password@example.com/private",
            "custom://example.com/action",
        ]
        for rawValue in blockedValues {
            let url = try XCTUnwrap(URL(string: rawValue))
            XCTAssertEqual(
                ChatURLPolicy.classify(url),
                .blocked,
                "Expected \(rawValue) to be blocked"
            )
        }
    }

    func testRepositoryLinksAcceptCanonicalAndRelativePathsWithLocations() throws {
        XCTAssertEqual(
            ChatURLPolicy.repositoryLink(
                from: "/workspace/example/Sources/App.swift:12:3"
            ),
            ChatRepositoryLink(
                path: "/workspace/example/Sources/App.swift",
                line: 12,
                column: 3
            )
        )
        XCTAssertEqual(
            ChatURLPolicy.repositoryLink(from: "Sources/App.swift:9"),
            ChatRepositoryLink(path: "Sources/App.swift", line: 9, column: nil)
        )

        let fragmentURL = try XCTUnwrap(
            URL(string: "terminal-relay-file:///Sources/App.swift#L22")
        )
        XCTAssertEqual(
            ChatURLPolicy.classify(fragmentURL),
            .repository(
                ChatRepositoryLink(path: "Sources/App.swift", line: 22, column: nil)
            )
        )
    }

    func testRepositoryLinksRejectTraversalAmbiguousHostsAndNonWorkspaceAbsolutePaths() throws {
        let rejectedStrings = [
            "../Secrets.txt",
            "Sources/../Secrets.txt",
            "Sources/./App.swift",
            "/private/etc/passwd",
            "Sources/",
            "",
        ]
        for rawValue in rejectedStrings {
            XCTAssertNil(
                ChatURLPolicy.repositoryLink(from: rawValue),
                "Expected \(rawValue) to be rejected"
            )
        }

        let rejectedURLs = [
            "terminal-relay-file://untrusted-host/Sources/App.swift",
            "terminal-relay-file:///Sources/%2E%2E/Secrets.txt",
            "terminal-relay-file:///Sources/App.swift?redirect=Secrets.txt",
        ]
        for rawValue in rejectedURLs {
            let url = try XCTUnwrap(URL(string: rawValue))
            XCTAssertEqual(
                ChatURLPolicy.classify(url),
                .blocked,
                "Expected \(rawValue) to be blocked"
            )
        }
    }

    func testRawHTMLIsEscapedWithoutDamagingInlineOrFencedCode() {
        let source = """
        Before <script>alert("x")</script>
        Inline: `let tag = <value>`
        ```html
        <div>code sample</div>
        ```
        After <img src="https://example.com/pixel.png">
        """

        let escaped = MarkdownSafety.escapedRawHTML(source)

        XCTAssertTrue(escaped.contains("Before &lt;script>alert"))
        XCTAssertTrue(escaped.contains("&lt;/script>"))
        XCTAssertTrue(escaped.contains("`let tag = <value>`"))
        XCTAssertTrue(escaped.contains("<div>code sample</div>"))
        XCTAssertTrue(escaped.contains("After &lt;img"))
        XCTAssertFalse(escaped.contains("After <img"))
    }

    func testMarkdownSanitizationNeutralizesEveryRenderableImageWithoutChangingCode() {
        let source = """
        | Name | Value |
        | --- | ---: |
        | Streaming | 50 ms |

        [Docs](https://example.com/docs)
        [Source](Sources/App.swift:12)
        ![HTTP](http://example.com/http.png)
        ![HTTPS](https://example.com/https.png)
        ![File](file:///etc/passwd)
        ![Data](data:image/png;base64,AAAA)
        ![FTP](ftp://example.com/image.png)
        ![Custom](arbitrary-scheme://example.com/image.png)
        ![Relative](Assets/diagram.png)
        ![Reference][diagram]
        ![Collapsed][]
        ![Shortcut]

        [diagram]: https://example.com/reference.png
        [collapsed]: Assets/collapsed.png
        [shortcut]: https://example.com/shortcut.png

        Inline code: `![Code image](https://example.com/code.png)`
        ```markdown
        ![Fenced image](https://example.com/fenced.png)
        ```
        """

        XCTAssertTrue(MarkdownSafety.containsRenderableImage(in: source))
        let sanitized = MarkdownSafety.sanitizedSource(source)

        XCTAssertFalse(MarkdownSafety.containsRenderableImage(in: sanitized))
        XCTAssertTrue(sanitized.contains("| Name | Value |"))
        XCTAssertTrue(sanitized.contains("[Docs](https://example.com/docs)"))
        XCTAssertTrue(sanitized.contains("[Source](Sources/App.swift:12)"))
        XCTAssertTrue(sanitized.contains("[Image: HTTP](<http://example.com/http.png>)"))
        XCTAssertTrue(sanitized.contains("[Image: HTTPS](<https://example.com/https.png>)"))
        XCTAssertTrue(sanitized.contains("[Image: Relative](<Assets/diagram.png>)"))
        XCTAssertTrue(sanitized.contains("[Image: Reference](<https://example.com/reference.png>)"))
        XCTAssertTrue(sanitized.contains("[Image: Collapsed](<Assets/collapsed.png>)"))
        XCTAssertTrue(sanitized.contains("[Image: Shortcut](<https://example.com/shortcut.png>)"))
        XCTAssertTrue(sanitized.contains("Image: File"))
        XCTAssertTrue(sanitized.contains("Image: Data"))
        XCTAssertTrue(sanitized.contains("Image: FTP"))
        XCTAssertTrue(sanitized.contains("Image: Custom"))
        XCTAssertFalse(sanitized.contains("file:///etc/passwd"))
        XCTAssertFalse(sanitized.contains("data:image/png"))
        XCTAssertFalse(sanitized.contains("ftp://example.com/image.png"))
        XCTAssertFalse(sanitized.contains("arbitrary-scheme://"))
        XCTAssertTrue(
            sanitized.contains("`![Code image](https://example.com/code.png)`")
        )
        XCTAssertTrue(
            sanitized.contains("![Fenced image](https://example.com/fenced.png)")
        )
    }

    @MainActor
    func testMarkdownSanitizationRunsOffMain() async {
        let result = await MarkdownSafety.sanitizedSourceOffMain(
            "Before <script>x</script>\n![Image](https://example.com/image.png)"
        )

        XCTAssertFalse(result.performedOnMainThread)
        XCTAssertFalse(MarkdownSafety.containsRenderableImage(in: result.source))
        XCTAssertTrue(result.source.contains("&lt;script>"))
        XCTAssertTrue(
            result.source.contains("[Image: Image](<https://example.com/image.png>)")
        )
    }

    func testMessageTimestampUsesUnixMilliseconds() throws {
        XCTAssertNil(ChatTimestamp.date(milliseconds: nil))
        XCTAssertNil(ChatTimestamp.date(milliseconds: -1))

        let date = try XCTUnwrap(
            ChatTimestamp.date(milliseconds: 1_800_000_000_250)
        )
        XCTAssertEqual(date.timeIntervalSince1970, 1_800_000_000.25, accuracy: 0.001)
    }

    @MainActor
    func testSyntaxHighlightingWorkRunsOffMainAndKeepsPlainFallback() async {
        let highlighted = await ChatSyntaxHighlighter.tokensOffMain(
            for: "let answer = 42 // done",
            language: "swift"
        )
        XCTAssertFalse(highlighted.performedOnMainThread)
        XCTAssertEqual(highlighted.tokens.map(\.text).joined(), "let answer = 42 // done")
        XCTAssertTrue(highlighted.tokens.contains { $0.kind == .keyword })
        XCTAssertTrue(highlighted.tokens.contains { $0.kind == .number })
        XCTAssertTrue(highlighted.tokens.contains { $0.kind == .comment })

        let fallback = await ChatSyntaxHighlighter.tokensOffMain(
            for: "opaque <content>",
            language: "future-language"
        )
        XCTAssertFalse(fallback.performedOnMainThread)
        XCTAssertEqual(
            fallback.tokens,
            [ChatCodeToken(text: "opaque <content>", kind: .plain)]
        )
    }

    func testAllQuestionTypesMustBeCompleteBeforeAtomicSubmission() {
        let request = QuestionRequest(
            id: "request",
            providerConnectionGeneration: "generation",
            providerRequestID: .number(7),
            prompt: "Answer these questions",
            kind: .freeText,
            fields: [
                QuestionField(
                    id: "single",
                    prompt: "Choose one",
                    kind: .singleChoice,
                    options: [
                        QuestionOption(id: "a", label: "A"),
                        QuestionOption(id: "b", label: "B"),
                    ]
                ),
                QuestionField(
                    id: "multiple",
                    prompt: "Choose several",
                    kind: .multipleChoice,
                    options: [
                        QuestionOption(id: "x", label: "X"),
                        QuestionOption(id: "y", label: "Y"),
                    ]
                ),
                QuestionField(
                    id: "free",
                    prompt: "Explain",
                    kind: .freeText
                ),
                QuestionField(
                    id: "secret",
                    prompt: "Enter token",
                    kind: .secret
                ),
            ]
        )
        let selected = [
            request.draftKey(for: request.resolvedFields[0]): Set(["b"]),
            request.draftKey(for: request.resolvedFields[1]): Set(["y", "x"]),
        ]
        let text = [
            request.draftKey(for: request.resolvedFields[2]): "Because it is safer.",
        ]

        XCTAssertFalse(
            QuestionResponsePresentation.canSubmit(
                request: request,
                selectedOptions: selected,
                text: text,
                secretTextByField: [:]
            )
        )

        let secrets = ["secret": "ephemeral-value"]
        XCTAssertTrue(
            QuestionResponsePresentation.canSubmit(
                request: request,
                selectedOptions: selected,
                text: text,
                secretTextByField: secrets
            )
        )
        let answers = QuestionResponsePresentation.answers(
            request: request,
            selectedOptions: selected,
            text: text,
            secretTextByField: secrets
        )
        XCTAssertEqual(answers.map(\.questionID), ["single", "multiple", "free", "secret"])
        XCTAssertEqual(answers[0].selectedOptionIDs, ["b"])
        XCTAssertEqual(answers[1].selectedOptionIDs, ["x", "y"])
        XCTAssertEqual(answers[2].text, "Because it is safer.")
        XCTAssertEqual(answers[3].text, "ephemeral-value")
    }
}
