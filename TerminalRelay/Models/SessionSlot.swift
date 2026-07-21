import Foundation

struct SessionSlot: Hashable {
    let serverKey: String
    let kind: AgentKind
}

struct SessionSlotRegistry {
    private(set) var occupied: Set<SessionSlot> = []

    mutating func claim(_ slot: SessionSlot) -> Bool {
        occupied.insert(slot).inserted
    }

    mutating func release(_ slot: SessionSlot) {
        occupied.remove(slot)
    }

    func contains(_ slot: SessionSlot) -> Bool {
        occupied.contains(slot)
    }
}
