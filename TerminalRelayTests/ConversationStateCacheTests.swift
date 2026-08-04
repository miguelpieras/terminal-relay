import XCTest
@testable import TerminalRelay

@MainActor
final class ConversationStateCacheTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversation-cache-tests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var identity: ChatConversationIdentity {
        ChatConversationIdentity(
            relayID: "b265e274-d701-483b-8cf5-42dc41791d65",
            provider: .codex,
            providerThreadID: "019fb19a-89be-7772-8ab8-74da1d3fd8df"
        )
    }

    private func populatedState() throws -> ConversationState {
        let store = ConversationStore()
        try store.apply(
            ChatTestFixtures.event(
                "message.completed",
                sequence: 1,
                itemID: "message-1",
                turnID: "turn-1",
                payload: .object([
                    "role": .string("assistant"),
                    "text": .string("Cached reply"),
                ])
            )
        )
        return store.state
    }

    func testRoundTripPreservesItemsAndResumeCursor() async throws {
        let cache = ConversationStateCache(directory: directory)
        let state = try populatedState()
        await cache.save(state, for: identity)

        let loaded = await cache.load(for: identity)
        XCTAssertEqual(loaded?.items, state.items)
        XCTAssertEqual(
            loaded?.lastAppliedSequence,
            1,
            "The resume cursor must survive the round trip so attach replays only the delta."
        )
    }

    func testLoadRefusesMissingThreadIdentityAndEmptyStates() async throws {
        let cache = ConversationStateCache(directory: directory)
        let anonymous = ChatConversationIdentity(
            relayID: "b265e274-d701-483b-8cf5-42dc41791d65",
            provider: .codex,
            providerThreadID: nil
        )
        await cache.save(try populatedState(), for: anonymous)
        let loadedAnonymous = await cache.load(for: anonymous)
        XCTAssertNil(
            loadedAnonymous,
            "Per-run relay IDs are never written or read; only stable thread IDs key the cache."
        )

        await cache.save(ConversationState(), for: identity)
        let loadedEmpty = await cache.load(for: identity)
        XCTAssertNil(loadedEmpty, "Empty states are not worth persisting.")
    }

    func testHydrationPaintsCacheOnceAndNeverClobbersLiveState() throws {
        let store = ConversationStore()
        let cached = try populatedState()

        store.hydrateFromCache(cached)
        XCTAssertEqual(store.state.items, cached.items)
        XCTAssertEqual(store.lastAppliedSequence, 1)
        XCTAssertEqual(
            store.state.connectionState,
            .connecting,
            "Hydrated content is stale until the attach reconciles."
        )

        var impostor = cached
        impostor.items = []
        store.hydrateFromCache(impostor)
        XCTAssertEqual(
            store.state.items,
            cached.items,
            "Hydration must never replace state that already holds live or cached content."
        )
    }

    func testHydrationNeutralizesStaleInteractionsAndTurnActivity() throws {
        var cached = try populatedState()
        cached.turnState = .running
        cached.activeTurnID = "turn-1"
        cached.approvals = [
            ApprovalRequest(
                id: "approval-1",
                turnID: "turn-1",
                providerConnectionGeneration: "dead-generation",
                providerRequestID: .string("request-1"),
                title: "Run a command",
                reason: nil,
                context: nil,
                decisions: [ApprovalDecision(id: "yes", label: "Approve")],
                status: .pending,
                occurredAt: nil
            ),
            ApprovalRequest(
                id: "approval-2",
                turnID: "turn-1",
                providerConnectionGeneration: "dead-generation",
                providerRequestID: .string("request-2"),
                title: "Earlier decision",
                reason: nil,
                context: nil,
                decisions: [ApprovalDecision(id: "yes", label: "Approve")],
                status: .approved,
                occurredAt: nil
            ),
        ]

        let store = ConversationStore()
        store.hydrateFromCache(cached)

        XCTAssertEqual(
            store.state.turnState,
            .idle,
            "Cached turn activity is stale until the attach reconciles."
        )
        XCTAssertNil(store.state.activeTurnID)
        XCTAssertEqual(
            store.state.approvals.map(\.id),
            ["approval-2"],
            "Pending prompts wired to a dead worker generation must not render actionable."
        )
    }
}
