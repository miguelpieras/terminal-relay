import Foundation

struct SessionSlot: Hashable {
    let serverKey: String
    let kind: AgentKind
    let accountID: ProviderAccountID?

    init(
        serverKey: String,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) {
        self.serverKey = serverKey
        self.kind = kind
        self.accountID = accountID
    }
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
