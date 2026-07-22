import Combine
import Foundation

@MainActor
struct SessionOccupant {
    let kind: AgentKind
    let repositoryName: String
    let projectID: UUID?
    let localSession: TerminalSession?
    let attachedClientCount: Int?

    init(session: TerminalSession) {
        kind = session.kind
        repositoryName = session.projectName
        projectID = session.projectID
        localSession = session
        attachedClientCount = session.remoteAttachedClientCount
    }

    init(
        snapshot: WorkerSessionSnapshot,
        projectID: UUID?,
        localSession: TerminalSession?
    ) {
        kind = snapshot.kind
        repositoryName = snapshot.repositoryName
        self.projectID = projectID
        self.localSession = localSession
        attachedClientCount = snapshot.attachedClientCount
    }
}

@MainActor
enum SessionOpenResult {
    case opened(TerminalSession)
    case selectedExisting(TerminalSession)
    case occupied(SessionOccupant)

    var localSession: TerminalSession? {
        switch self {
        case .opened(let session), .selectedExisting(let session):
            return session
        case .occupied(let occupant):
            return occupant.localSession
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    @Published var selectedSessionID: UUID?
    @Published private var remoteOccupancies: [SessionSlot: WorkerSessionSnapshot] = [:]

    private var lastSequenceNumberByProjectAndKind: [ProjectAgentKey: Int] = [:]
    private var sessionObservers: [UUID: AnyCancellable] = [:]

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
        occupant(for: server, kind: kind)?.localSession
    }

    func occupant(for server: ServerProfile, kind: AgentKind) -> SessionOccupant? {
        let slot = SessionSlot(serverKey: server.concurrencyKey, kind: kind)
        if let snapshot = remoteOccupancies[slot] {
            let localSession = sessions.last {
                $0.serverKey == server.concurrencyKey
                    && $0.kind == kind
                    && $0.projectName == snapshot.repositoryName
                    && $0.instanceToken == snapshot.instanceToken
                    && $0.status.occupiesSlot
            }
            return SessionOccupant(
                snapshot: snapshot,
                projectID: localSession?.projectID,
                localSession: localSession
            )
        }

        return occupyingSession(server: server, kind: kind).map(SessionOccupant.init)
    }

    @discardableResult
    func openAfterRefresh(
        project: ProjectProfile,
        on server: ServerProfile,
        kind: AgentKind,
        projects: [ProjectProfile],
        launchDefaults: AgentLaunchDefaults,
        using service: WorkerSessionService
    ) async -> SessionOpenResult? {
        guard project.serverID == server.id else { return nil }

        if let existing = activeSession(projectID: project.id, kind: kind) {
            guard existing.serverKey == server.concurrencyKey else {
                return .occupied(SessionOccupant(session: existing))
            }
            guard existing.status.canReconnect else {
                selectedSessionID = existing.id
                return .selectedExisting(existing)
            }
            guard await refresh(
                worker: server,
                projects: projects,
                launchDefaults: launchDefaults,
                using: service
            ),
            let current = sessions.first(where: { $0.id == existing.id }),
            current.status.canReconnect,
            let snapshot = confirmedRemoteSnapshot(for: current, on: server),
            let replacement = replaceDetachedSession(
                sessionID: current.id,
                project: project,
                on: server,
                confirmedSnapshot: snapshot
            ) else {
                return nil
            }
            return .selectedExisting(replacement)
        }

        guard await refresh(
            worker: server,
            projects: projects,
            launchDefaults: launchDefaults,
            using: service
        ) else {
            return nil
        }

        let slot = SessionSlot(serverKey: server.concurrencyKey, kind: kind)
        if let remote = remoteOccupancies[slot], remote.repositoryName != project.displayName {
            return .occupied(occupant(for: remote, on: server))
        }
        if let occupant = occupyingSession(server: server, kind: kind),
           occupant.projectID != project.id || occupant.projectName != project.displayName {
            return .occupied(SessionOccupant(session: occupant))
        }

        guard let snapshot = await service.start(
            kind: kind,
            repositoryName: project.displayName,
            launchDefaults: launchDefaults,
            on: server
        ),
        snapshot.kind == kind,
        snapshot.repositoryName == project.displayName else {
            return nil
        }

        return openConfirmedRemote(
            project: project,
            on: server,
            snapshot: snapshot
        )
    }

    @discardableResult
    func openConfirmedRemote(
        project: ProjectProfile,
        on server: ServerProfile,
        snapshot: WorkerSessionSnapshot
    ) -> SessionOpenResult? {
        guard project.serverID == server.id,
              snapshot.repositoryName == project.displayName,
              let instanceID = UUID(uuidString: snapshot.instanceToken),
              instanceID.uuidString.lowercased() == snapshot.instanceToken else {
            return nil
        }

        let slot = SessionSlot(serverKey: server.concurrencyKey, kind: snapshot.kind)
        if let remote = remoteOccupancies[slot],
           remote.repositoryName != snapshot.repositoryName {
            return .occupied(occupant(for: remote, on: server))
        }
        if let occupant = sessions.first(where: {
            $0.serverKey == server.concurrencyKey
                && $0.kind == snapshot.kind
                && $0.status.occupiesSlot
                && ($0.projectID != project.id || $0.projectName != project.displayName)
        }) {
            return .occupied(SessionOccupant(session: occupant))
        }

        for staleSession in sessions where staleSession.serverKey == server.concurrencyKey
            && staleSession.kind == snapshot.kind
            && staleSession.projectID == project.id
            && staleSession.projectName == project.displayName
            && staleSession.instanceToken != snapshot.instanceToken
            && staleSession.status.occupiesSlot {
            staleSession.markRemoteReplaced()
        }

        remoteOccupancies[slot] = snapshot
        if let existing = sessions.last(where: {
            $0.projectID == project.id
                && $0.serverKey == server.concurrencyKey
                && $0.kind == snapshot.kind
                && $0.instanceToken == snapshot.instanceToken
        }) {
            existing.applyRemoteSnapshot(snapshot)
            if existing.status.canReconnect,
               let replacement = replaceDetachedSession(
                   sessionID: existing.id,
                   project: project,
                   on: server,
                   confirmedSnapshot: snapshot
               ) {
                return .selectedExisting(replacement)
            }
            selectedSessionID = existing.id
            return .selectedExisting(existing)
        }

        let session = TerminalSession(
            project: project,
            server: server,
            kind: snapshot.kind,
            sequenceNumber: nextSequenceNumber(projectID: project.id, kind: snapshot.kind),
            instanceToken: snapshot.instanceToken,
            remoteAttachedClientCount: snapshot.attachedClientCount
        )
        append(session)
        selectedSessionID = session.id
        return .opened(session)
    }

    @discardableResult
    func reconnectAfterRefresh(
        sessionID: UUID,
        project: ProjectProfile,
        on server: ServerProfile,
        projects: [ProjectProfile],
        launchDefaults: AgentLaunchDefaults,
        using service: WorkerSessionService
    ) async -> TerminalSession? {
        guard project.serverID == server.id,
              await refresh(
                  worker: server,
                  projects: projects,
                  launchDefaults: launchDefaults,
                  using: service
              ),
              let existing = sessions.first(where: { $0.id == sessionID }),
              existing.projectID == project.id,
              existing.serverKey == server.concurrencyKey,
              existing.projectName == project.displayName,
              existing.status.canReconnect,
              let snapshot = confirmedRemoteSnapshot(for: existing, on: server) else {
            return nil
        }

        return replaceDetachedSession(
            sessionID: sessionID,
            project: project,
            on: server,
            confirmedSnapshot: snapshot
        )
    }

    private func replaceDetachedSession(
        sessionID: UUID,
        project: ProjectProfile,
        on server: ServerProfile,
        confirmedSnapshot: WorkerSessionSnapshot
    ) -> TerminalSession? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let existing = sessions[index]
        guard existing.projectID == project.id,
              existing.serverKey == server.concurrencyKey,
              existing.projectName == project.displayName,
              existing.status.canReconnect,
              confirmedSnapshot.kind == existing.kind,
              confirmedSnapshot.repositoryName == existing.projectName,
              confirmedSnapshot.instanceToken == existing.instanceToken else {
            return nil
        }
        let launchIdentity = confirmedSnapshot.instanceToken

        let replacement = TerminalSession(
            project: project,
            server: server,
            kind: existing.kind,
            sequenceNumber: existing.sequenceNumber,
            instanceToken: launchIdentity,
            id: existing.id,
            startedAt: existing.startedAt,
            initialStatus: .connecting,
            terminalTitle: existing.terminalTitle,
            remoteAttachedClientCount: confirmedSnapshot.attachedClientCount
        )
        sessionObservers[existing.id] = nil
        sessions[index] = replacement
        observe(replacement)
        selectedSessionID = replacement.id
        return replacement
    }

    func disconnect(sessionID: UUID) {
        sessions.first(where: { $0.id == sessionID })?.requestDisconnect()
    }

    func close(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        if session.status.isLocallyAttached {
            session.requestDisconnect()
        } else {
            removeSession(id: sessionID)
        }
    }

    func closeSessions(for server: ServerProfile) {
        for session in sessions(for: server) {
            session.requestDisconnect()
            removeSession(id: session.id)
        }
        remoteOccupancies = remoteOccupancies.filter { $0.key.serverKey != server.concurrencyKey }
    }

    func closeSessions(forProjectID projectID: UUID) {
        for session in sessions(forProjectID: projectID) {
            session.requestDisconnect()
            removeSession(id: session.id)
        }
    }

    func disconnectAll() {
        for session in sessions where session.status.isLocallyAttached {
            session.requestDisconnect()
        }
    }

    @discardableResult
    func refresh(
        worker: ServerProfile,
        projects: [ProjectProfile],
        launchDefaults: AgentLaunchDefaults,
        using service: WorkerSessionService
    ) async -> Bool {
        guard let response = await service.refresh(worker: worker) else {
            return false
        }
        reconcile(
            worker: worker,
            projects: projects,
            response: response,
            launchDefaults: launchDefaults
        )
        return true
    }

    func reconcile(
        worker: ServerProfile,
        projects: [ProjectProfile],
        response: WorkerSessionResponse,
        launchDefaults: AgentLaunchDefaults
    ) {
        remoteOccupancies = remoteOccupancies.filter {
            $0.key.serverKey != worker.concurrencyKey
        }
        for snapshot in response.sessions {
            remoteOccupancies[
                SessionSlot(serverKey: worker.concurrencyKey, kind: snapshot.kind)
            ] = snapshot
        }

        for session in sessions(for: worker) where session.status.occupiesSlot {
            let remote = remoteOccupancies[
                SessionSlot(serverKey: worker.concurrencyKey, kind: session.kind)
            ]
            if let remote,
               remote.repositoryName == session.projectName,
               remote.instanceToken != session.instanceToken {
                session.markRemoteReplaced()
            } else if session.status.canReconnect,
                      remote?.repositoryName != session.projectName {
                session.markRemoteExited()
            }
        }

        let workerProjects = projects.filter { $0.serverID == worker.id }
        for snapshot in response.sessions {
            guard let project = workerProjects.first(where: {
                $0.displayName == snapshot.repositoryName
            }) else { continue }

            let existing = sessions.last {
                $0.projectID == project.id
                    && $0.serverKey == worker.concurrencyKey
                    && $0.kind == snapshot.kind
                    && $0.instanceToken == snapshot.instanceToken
            }
            if let existing {
                existing.applyRemoteSnapshot(snapshot)
            } else {
                let session = TerminalSession(
                    project: project,
                    server: worker,
                    kind: snapshot.kind,
                    sequenceNumber: nextSequenceNumber(projectID: project.id, kind: snapshot.kind),
                    instanceToken: snapshot.instanceToken,
                    initialStatus: .remoteRunning,
                    remoteAttachedClientCount: snapshot.attachedClientCount
                )
                append(session)
            }
        }
    }

    @discardableResult
    func stopAgent(
        sessionID: UUID,
        on worker: ServerProfile,
        using service: WorkerSessionService
    ) async -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.serverKey == worker.concurrencyKey,
              WorkerSessionProtocol.isValidRepositoryName(session.projectName),
              session.status.occupiesSlot,
              session.status != .stopping else {
            return false
        }

        let slot = SessionSlot(serverKey: worker.concurrencyKey, kind: session.kind)
        guard let snapshot = remoteOccupancies[slot],
              snapshot.repositoryName == session.projectName,
              snapshot.instanceToken == session.instanceToken else {
            return false
        }
        let repositoryName = session.projectName
        let instanceToken = session.instanceToken
        session.beginRemoteStop()

        guard await service.stop(
            kind: session.kind,
            repositoryName: repositoryName,
            instanceToken: instanceToken,
            on: worker
        ) else {
            session.cancelRemoteStop()
            return false
        }

        guard let currentSession = sessions.first(where: { $0.id == sessionID }),
              currentSession === session,
              currentSession.serverKey == worker.concurrencyKey,
              currentSession.projectName == repositoryName else {
            session.cancelRemoteStop()
            return false
        }
        if let latestSnapshot = remoteOccupancies[slot],
           latestSnapshot.repositoryName != repositoryName
            || latestSnapshot.instanceToken != instanceToken {
            session.cancelRemoteStop()
            return false
        }

        remoteOccupancies.removeValue(forKey: slot)
        session.completeRemoteStop()
        return true
    }

    @discardableResult
    func stopAgentAfterRefresh(
        sessionID: UUID,
        on worker: ServerProfile,
        projects: [ProjectProfile],
        launchDefaults: AgentLaunchDefaults,
        using service: WorkerSessionService
    ) async -> Bool {
        guard await refresh(
            worker: worker,
            projects: projects,
            launchDefaults: launchDefaults,
            using: service
        ) else {
            return false
        }
        return await stopAgent(sessionID: sessionID, on: worker, using: service)
    }

    private func append(_ session: TerminalSession) {
        sessions.append(session)
        observe(session)
    }

    private func observe(_ session: TerminalSession) {
        sessionObservers[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    private func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removedProjectID = sessions[index].projectID
        sessions.remove(at: index)
        sessionObservers[id] = nil

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

    private func occupant(
        for snapshot: WorkerSessionSnapshot,
        on server: ServerProfile
    ) -> SessionOccupant {
        let localSession = sessions.last {
            $0.serverKey == server.concurrencyKey
                && $0.kind == snapshot.kind
                && $0.projectName == snapshot.repositoryName
                && $0.instanceToken == snapshot.instanceToken
                && $0.status.occupiesSlot
        }
        return SessionOccupant(
            snapshot: snapshot,
            projectID: localSession?.projectID,
            localSession: localSession
        )
    }

    private func confirmedRemoteSnapshot(
        for session: TerminalSession,
        on server: ServerProfile
    ) -> WorkerSessionSnapshot? {
        guard session.serverKey == server.concurrencyKey else { return nil }
        let snapshot = remoteOccupancies[
            SessionSlot(serverKey: server.concurrencyKey, kind: session.kind)
        ]
        guard snapshot?.repositoryName == session.projectName,
              snapshot?.instanceToken == session.instanceToken else {
            return nil
        }
        return snapshot
    }
}

private struct ProjectAgentKey: Hashable {
    let projectID: UUID
    let kind: AgentKind
}
