import Combine
import Foundation

enum SessionOpenResult {
    case opened(TerminalSession)
    case selectedExisting(TerminalSession)
    case occupied(TerminalSession)

    var session: TerminalSession {
        switch self {
        case .opened(let session), .selectedExisting(let session), .occupied(let session):
            session
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?

    private var sessionsPendingClose: Set<UUID> = []
    private var lastSequenceNumberByProjectAndKind: [ProjectAgentKey: Int] = [:]

    func session(projectID: UUID, kind: AgentKind) -> TerminalSession? {
        activeSession(projectID: projectID, kind: kind)
            ?? sessions.last { $0.projectID == projectID && $0.kind == kind }
    }

    func sessions(forProjectID projectID: UUID) -> [TerminalSession] {
        sessions.filter { $0.projectID == projectID }
    }

    func activeSession(projectID: UUID, kind: AgentKind) -> TerminalSession? {
        sessions.last {
            $0.projectID == projectID
                && $0.kind == kind
                && $0.status.occupiesSlot
        }
    }

    func sessions(for server: ServerProfile) -> [TerminalSession] {
        sessions.filter { $0.serverKey == server.concurrencyKey }
    }

    func activeSession(for server: ServerProfile, kind: AgentKind) -> TerminalSession? {
        occupyingSession(server: server, kind: kind)
    }

    @discardableResult
    func open(
        project: ProjectProfile,
        on server: ServerProfile,
        kind: AgentKind,
        launchDefaults: AgentLaunchDefaults
    ) -> SessionOpenResult {
        if let existing = activeSession(projectID: project.id, kind: kind) {
            if existing.serverKey == server.concurrencyKey {
                selectedSessionID = existing.id
                return .selectedExisting(existing)
            }
            return .occupied(existing)
        }

        if let occupant = occupyingSession(server: server, kind: kind) {
            return .occupied(occupant)
        }

        let session = TerminalSession(
            project: project,
            server: server,
            kind: kind,
            sequenceNumber: nextSequenceNumber(projectID: project.id, kind: kind),
            launchDefaults: launchDefaults
        )
        session.onTermination = { [weak self] sessionID in
            self?.handleTermination(sessionID: sessionID)
        }
        sessions.append(session)
        selectedSessionID = session.id
        return .opened(session)
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

    func closeSessions(forProjectID projectID: UUID) {
        for session in sessions(forProjectID: projectID) {
            close(sessionID: session.id)
        }
    }

    func stopAll() {
        for session in sessions where session.status.occupiesSlot {
            session.requestStop()
        }
    }

    private func handleTermination(sessionID: UUID) {
        guard sessions.contains(where: { $0.id == sessionID }) else { return }

        if sessionsPendingClose.remove(sessionID) != nil {
            removeSession(id: sessionID)
        } else {
            objectWillChange.send()
        }
    }

    private func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removedProjectID = sessions[index].projectID
        sessions.remove(at: index)
        sessionsPendingClose.remove(id)

        if selectedSessionID == id {
            selectedSessionID = sessions.last(where: { $0.projectID == removedProjectID })?.id
                ?? sessions.last?.id
        }
    }

    private func nextSequenceNumber(projectID: UUID, kind: AgentKind) -> Int {
        let key = ProjectAgentKey(projectID: projectID, kind: kind)
        let nextNumber = (lastSequenceNumberByProjectAndKind[key] ?? 0) + 1
        lastSequenceNumberByProjectAndKind[key] = nextNumber
        return nextNumber
    }

    private func occupyingSession(server: ServerProfile, kind: AgentKind) -> TerminalSession? {
        sessions.first {
            $0.serverKey == server.concurrencyKey
                && $0.kind == kind
                && $0.status.occupiesSlot
        }
    }
}

private struct ProjectAgentKey: Hashable {
    let projectID: UUID
    let kind: AgentKind
}
