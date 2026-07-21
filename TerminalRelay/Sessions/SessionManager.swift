import Combine
import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?

    private var slots = SessionSlotRegistry()
    private var sessionsPendingClose: Set<UUID> = []

    func session(server: ServerProfile, kind: AgentKind) -> TerminalSession? {
        sessions.first { $0.serverKey == server.concurrencyKey && $0.kind == kind }
    }

    func sessions(for server: ServerProfile) -> [TerminalSession] {
        sessions.filter { $0.serverKey == server.concurrencyKey }
    }

    func open(server: ServerProfile, kind: AgentKind, launchDefaults: AgentLaunchDefaults) {
        if let existing = session(server: server, kind: kind) {
            if existing.status.occupiesSlot {
                selectedSessionID = existing.id
                return
            }
            removeSession(id: existing.id)
        }

        let slot = SessionSlot(serverKey: server.concurrencyKey, kind: kind)
        guard slots.claim(slot) else {
            selectedSessionID = session(server: server, kind: kind)?.id
            return
        }

        let session = TerminalSession(server: server, kind: kind, launchDefaults: launchDefaults)
        session.onTermination = { [weak self] sessionID in
            self?.handleTermination(sessionID: sessionID)
        }
        sessions.append(session)
        selectedSessionID = session.id
    }

    func close(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }

        if session.status.occupiesSlot {
            sessionsPendingClose.insert(sessionID)
            session.requestStop()
        } else {
            removeSession(id: sessionID)
        }
    }

    func closeSessions(for server: ServerProfile) {
        for session in sessions(for: server) {
            close(sessionID: session.id)
        }
    }

    func stopAll() {
        for session in sessions where session.status.occupiesSlot {
            session.requestStop()
        }
    }

    private func handleTermination(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        slots.release(SessionSlot(serverKey: session.serverKey, kind: session.kind))

        if sessionsPendingClose.remove(sessionID) != nil {
            removeSession(id: sessionID)
        } else {
            objectWillChange.send()
        }
    }

    private func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions[index]
        slots.release(SessionSlot(serverKey: session.serverKey, kind: session.kind))
        sessions.remove(at: index)
        sessionsPendingClose.remove(id)

        if selectedSessionID == id {
            selectedSessionID = sessions.last?.id
        }
    }
}
