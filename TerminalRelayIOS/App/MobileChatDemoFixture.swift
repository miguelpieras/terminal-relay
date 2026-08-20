import Foundation

enum MobileChatDemoFixture {
    struct Instance {
        let coordinator: ConversationCoordinator
        fileprivate let scrollUITestTransport: ChatFixtureTransport?

        var supportsScrollUITestUpdate: Bool {
            scrollUITestTransport != nil
        }

        func appendScrollUITestUpdate() async {
            guard let scrollUITestTransport else { return }
            for event in MobileChatDemoFixture.scrollUITestLateEvents {
                await scrollUITestTransport.yield(.envelope(event))
            }
        }
    }

    static let identity = ChatConversationIdentity(
        relayID: "00000000-0000-4000-8000-000000009001",
        provider: .codex,
        providerThreadID: "00000000-0000-4000-8000-000000009002"
    )

    @MainActor
    static func makeCoordinator() -> ConversationCoordinator {
        makeInstance().coordinator
    }

    @MainActor
    static func makeInstance() -> Instance {
        if ScreenshotDemoMode.runsScrollUITest {
            let transport = ChatFixtureTransport(
                initialEvents: scrollUITestInitialEvents
            )
            let coordinator = ConversationCoordinator(
                transport: transport,
                identity: identity,
                retryPolicy: .immediate
            )
            return Instance(
                coordinator: coordinator,
                scrollUITestTransport: transport
            )
        }

        let transport = ChatFixtureTransport(initialEvents: events)
        return Instance(
            coordinator: ConversationCoordinator(
                transport: transport,
                identity: identity,
                retryPolicy: .immediate
            ),
            scrollUITestTransport: nil
        )
    }

    static var events: [ChatEnvelope] {
        let generation = "00000000-0000-4000-8000-000000009003"
        let turnID = "00000000-0000-4000-8000-000000009004"
        let assistantID = "assistant-demo"
        let finalMarkdown = """
        ## Adaptive workspace polish

        The conversation now feels native on every screen size:

        | Surface | Result |
        |:--|:--|
        | iPhone | Focused transcript and anchored composer |
        | iPad | Comfortable reading width in Split View |
        | Mac | Keyboard-first controls and selectable output |

        ```swift
        struct ConversationView: View {
            let isReadOnly: Bool
        }
        ```

        I also verified the [direct SSH boundary](https://example.com/security)
        and kept remote images disabled.
        """
        let snapshot = ConversationSnapshot(
            snapshotGeneration: generation,
            baseSequence: 1,
            items: [
                .message(
                    ChatMessage(
                        id: "user-demo",
                        turnID: turnID,
                        role: .user,
                        text: "Make the chat experience excellent on iPhone, iPad, and Mac."
                    )
                ),
                .message(
                    ChatMessage(
                        id: assistantID,
                        turnID: turnID,
                        role: .assistant,
                        text: "## Adaptive workspace polish\n\n",
                        isStreaming: true
                    )
                ),
                .tool(
                    ToolActivity(
                        id: "tool-demo",
                        turnID: turnID,
                        kind: .shell,
                        title: "Run interaction tests",
                        status: .completed,
                        input: "xcodebuild test",
                        output: "All focused chat interaction tests passed.",
                        errorMessage: nil,
                        durationMilliseconds: 1_420,
                        exitCode: 0,
                        occurredAt: 1_800_000_002_000,
                        isTruncated: false,
                        originalByteCount: nil
                    )
                ),
                .diff(
                    ChatDiff(
                        id: "diff-demo",
                        turnID: turnID,
                        path: "Shared/Chat/ConversationView.swift",
                        unifiedDiff: """
                        - TerminalRepresentable(controller: controller)
                        + ConversationView(coordinator: coordinator)
                        """,
                        occurredAt: 1_800_000_003_000,
                        isTruncated: false
                    )
                ),
                .generic(
                    ChatGenericItem(
                        id: "error-demo",
                        turnID: turnID,
                        type: "error",
                        title: "Preview server was briefly unavailable",
                        detail: "The agent recovered without losing the turn.",
                        occurredAt: 1_800_000_004_000
                    )
                ),
            ],
            approvals: [
                ApprovalRequest(
                    id: "approval-demo",
                    turnID: turnID,
                    providerConnectionGeneration:
                        "00000000-0000-4000-8000-000000009005",
                    providerRequestID: .string("demo-request"),
                    title: "Apply the reviewed UI changes?",
                    reason: "The diff only changes presentation code.",
                    context: "2 files · 38 additions · 14 deletions",
                    decisions: [
                        ApprovalDecision(id: "approve", label: "Approved"),
                        ApprovalDecision(id: "deny", label: "Denied"),
                    ],
                    status: .approved,
                    occurredAt: 1_800_000_003_500
                ),
            ],
            connectionState: .streaming,
            turnState: .running,
            activeTurnID: turnID,
            capabilities: ChatCapabilities(
                features: ["approvals", "streaming", "tools"],
                supportsAttachments: true
            ),
            usage: ChatUsage(
                inputTokens: 3_420,
                outputTokens: 1_180,
                contextTokens: 18_240,
                contextLimit: 200_000
            )
        )

        return [
            envelope(
                type: "conversation.snapshot",
                sequence: 1,
                generation: generation,
                turnID: turnID,
                payload: (try? JSONValue.encoded(snapshot)) ?? .object([:])
            ),
            envelope(
                type: "message.delta",
                sequence: 2,
                generation: generation,
                turnID: turnID,
                itemID: assistantID,
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(String(finalMarkdown.dropFirst(
                        "## Adaptive workspace polish\n\n".count
                    ))),
                ])
            ),
            envelope(
                type: "message.completed",
                sequence: 3,
                generation: generation,
                turnID: turnID,
                itemID: assistantID,
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(finalMarkdown),
                ])
            ),
            envelope(
                type: "turn.completed",
                sequence: 4,
                generation: generation,
                turnID: turnID
            ),
        ]
    }

    private static var scrollUITestInitialEvents: [ChatEnvelope] {
        let generation = "00000000-0000-4000-8000-000000009103"
        let turnID = "00000000-0000-4000-8000-000000009104"
        var restoredItems = (1...100).map { row -> ConversationItem in
            let firstLine = (row - 1) * 5 + 1
            return .message(
                ChatMessage(
                    id: String(format: "scroll-row-%03d", row),
                    turnID: turnID,
                    role: .assistant,
                    text: numberedStreamingLines(firstLine...(firstLine + 4)),
                    isStreaming: false
                )
            )
        }
        restoredItems.append(
            .tool(
                ToolActivity(
                    id: "scroll-test-tail",
                    turnID: turnID,
                    kind: .shell,
                    title: "End of restored conversation",
                    status: .completed,
                    input: nil,
                    output: "The initial viewport reached the newest restored item.",
                    errorMessage: nil,
                    durationMilliseconds: 1,
                    exitCode: 0,
                    occurredAt: 1_800_000_102_000,
                    isTruncated: false,
                    originalByteCount: nil
                )
            )
        )
        let snapshot = ConversationSnapshot(
            snapshotGeneration: generation,
            baseSequence: 1,
            items: restoredItems,
            connectionState: .streaming,
            turnState: .completed,
            activeTurnID: nil,
            capabilities: ChatCapabilities(features: ["streaming"])
        )

        return [
            envelope(
                type: "conversation.snapshot",
                sequence: 1,
                generation: generation,
                turnID: turnID,
                payload: (try? JSONValue.encoded(snapshot)) ?? .object([:])
            ),
        ]
    }

    private static var scrollUITestLateEvents: [ChatEnvelope] {
        let generation = "00000000-0000-4000-8000-000000009103"
        let turnID = "00000000-0000-4000-8000-000000009104"
        return [
            envelope(
                type: "message.completed",
                sequence: 2,
                generation: generation,
                turnID: turnID,
                itemID: "scroll-row-100",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string(numberedStreamingLines(496...600)),
                ])
            ),
            envelope(
                type: "uiTest.lateUpdate",
                sequence: 3,
                generation: generation,
                turnID: turnID,
                itemID: "scroll-test-late-update",
                payload: .object([
                    "title": .string("Late update arrived"),
                    "summary": .string("Manual scrolling must remain in control."),
                ])
            ),
        ]
    }

    private static func numberedStreamingLines(
        _ range: ClosedRange<Int>
    ) -> String {
        range.map { "\($0). streaming" }.joined(separator: "\n")
    }

    private static func envelope(
        type: String,
        sequence: Int64,
        generation: String,
        turnID: String?,
        itemID: String? = nil,
        payload: JSONValue = .object([:])
    ) -> ChatEnvelope {
        ChatEnvelope(
            v: ChatEnvelope.legacyProtocolVersion,
            type: type,
            eventID: String(
                format: "00000000-0000-4000-8000-%012lld",
                sequence + 9_100
            ),
            relayID: identity.relayID,
            provider: identity.provider,
            providerThreadID: identity.providerThreadID,
            snapshotGeneration: generation,
            sequence: sequence,
            occurredAt: 1_800_000_000_000 + sequence * 1_000,
            turnID: turnID,
            itemID: itemID,
            payload: payload
        )
    }
}
