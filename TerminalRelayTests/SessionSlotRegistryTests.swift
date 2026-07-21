import XCTest
@testable import TerminalRelay

final class SessionSlotRegistryTests: XCTestCase {
    func testRegistryAllowsOneSlotPerAgentKindOnEachServer() {
        let firstCodex = SessionSlot(serverKey: "first.example:22", kind: .codex)
        let firstClaude = SessionSlot(serverKey: "first.example:22", kind: .claude)
        let secondCodex = SessionSlot(serverKey: "second.example:22", kind: .codex)
        var registry = SessionSlotRegistry()

        XCTAssertTrue(registry.claim(firstCodex))
        XCTAssertFalse(registry.claim(firstCodex), "A server cannot claim a second Codex slot")
        XCTAssertTrue(registry.claim(firstClaude), "Codex and Claude may coexist on one server")
        XCTAssertFalse(registry.claim(firstClaude), "A server cannot claim a second Claude slot")
        XCTAssertTrue(registry.claim(secondCodex), "The same agent kind may run on another server")

        XCTAssertEqual(registry.occupied, [firstCodex, firstClaude, secondCodex])
    }

    func testReleasedSlotCanBeClaimedAgainWithoutAffectingOtherSlots() {
        let codex = SessionSlot(serverKey: "worker.example:22", kind: .codex)
        let claude = SessionSlot(serverKey: "worker.example:22", kind: .claude)
        var registry = SessionSlotRegistry()
        XCTAssertTrue(registry.claim(codex))
        XCTAssertTrue(registry.claim(claude))

        registry.release(codex)

        XCTAssertFalse(registry.contains(codex))
        XCTAssertTrue(registry.contains(claude))
        XCTAssertTrue(registry.claim(codex))
    }
}
