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
    @Published private(set) var selectedSessionID: UUID?
    @Published private var remoteSessions: [RemoteSessionKey: WorkerSessionSnapshot] = [:]

    private let defaults: UserDefaults
    private let taskCompletionHandler: @MainActor (TerminalSession) -> Void
    private let sidebarSessionOrderStorageKey = "sidebarSessionOrder.v1"
    private var selectionRevision = 0
    private var sidebarSessionInstanceTokensByProject: [String: [String]] = [:]
    private var lastSequenceNumberByProjectAndKind: [ProjectAgentKey: Int] = [:]
    private var sessionObservers: [UUID: AnyCancellable] = [:]
    private var taskCompletionObservers: [UUID: AnyCancellable] = [:]
    private var backgroundAttachmentAttemptedSessionIDs = Set<UUID>()

    init(
        defaults: UserDefaults = .standard,
        taskCompletionHandler: @escaping @MainActor (TerminalSession) -> Void =
            TaskCompletionNotificationService.notifyTaskCompletion(for:)
    ) {
        self.defaults = defaults
        self.taskCompletionHandler = taskCompletionHandler
        if let data = defaults.data(forKey: sidebarSessionOrderStorageKey),
           let savedOrder = try? JSONDecoder().decode([String: [String]].self, from: data) {
            sidebarSessionInstanceTokensByProject = savedOrder
        }
    }

#if DEBUG
    func loadScreenshotDemo(
        _ fixtures: [(project: ProjectProfile, snapshot: WorkerSessionSnapshot)],
        on worker: ServerProfile
    ) {
        for fixture in fixtures {
            _ = openConfirmedRemote(
                project: fixture.project,
                on: worker,
                snapshot: fixture.snapshot,
                selectResult: false
            )
        }
        selectSession(nil)
    }
#endif

    func session(projectID: UUID, kind: AgentKind) -> TerminalSession? {
        activeSession(projectID: projectID, kind: kind)
            ?? sessions.last { $0.projectID == projectID && $0.kind == kind }
    }

    func sessions(forProjectID projectID: UUID) -> [TerminalSession] {
        sessions.filter { $0.projectID == projectID }
    }

    func sidebarSessions(forProjectID projectID: UUID) -> [TerminalSession] {
        let defaultOrder = Array(sessions(forProjectID: projectID).reversed())
        guard let savedTokens = sidebarSessionInstanceTokensByProject[projectID.uuidString] else {
            return defaultOrder
        }

        let sessionsByToken = Dictionary(
            uniqueKeysWithValues: defaultOrder.map { ($0.instanceToken, $0) }
        )
        let savedSessions = savedTokens.compactMap { sessionsByToken[$0] }
        let savedTokenSet = Set(savedSessions.map(\.instanceToken))
        return defaultOrder.filter { !savedTokenSet.contains($0.instanceToken) } + savedSessions
    }

    func moveSidebarSession(id sessionID: UUID, before targetSessionID: UUID?) {
        guard let movingSession = sessions.first(where: { $0.id == sessionID }) else { return }
        var orderedSessions = sidebarSessions(forProjectID: movingSession.projectID)
        guard let movingIndex = orderedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }

        let session = orderedSessions.remove(at: movingIndex)
        let targetIndex = targetSessionID.flatMap { targetID in
            orderedSessions.firstIndex(where: { $0.id == targetID })
        } ?? orderedSessions.endIndex
        orderedSessions.insert(session, at: targetIndex)
        sidebarSessionInstanceTokensByProject[movingSession.projectID.uuidString] =
            orderedSessions.map(\.instanceToken)
        persistSidebarSessionOrder()
        objectWillChange.send()
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
        sessions.last {
            $0.serverKey == server.concurrencyKey
                && $0.kind == kind
                && $0.status.occupiesSlot
        }
    }

    func occupant(for server: ServerProfile, kind: AgentKind) -> SessionOccupant? {
        if let localSession = activeSession(for: server, kind: kind) {
            return SessionOccupant(session: localSession)
        }

        if let snapshot = remoteSessions.first(where: {
            $0.key.serverKey == server.concurrencyKey && $0.value.kind == kind
        })?.value {
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

        return nil
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
        let openSelectionRevision = claimOpenSelectionIntent()
        guard project.serverID == server.id else { return nil }

        guard await refresh(
            worker: server,
            projects: projects,
            launchDefaults: launchDefaults,
            using: service
        ) else {
            return nil
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

        let shouldSelectResult = selectionRevision == openSelectionRevision
        let result = openConfirmedRemote(
            project: project,
            on: server,
            snapshot: snapshot,
            selectResult: shouldSelectResult,
            launchDefaults: launchDefaults
        )
        return shouldSelectResult ? result : nil
    }

    @discardableResult
    func resumeThreadAfterRefresh(
        _ thread: WorkerThreadSnapshot,
        project: ProjectProfile,
        on server: ServerProfile,
        projects: [ProjectProfile],
        launchDefaults: AgentLaunchDefaults,
        using service: WorkerSessionService
    ) async -> SessionOpenResult? {
        let openSelectionRevision = claimOpenSelectionIntent()
        guard thread.activityState == .inactive,
              thread.capabilities.resume,
              thread.repositoryName == project.displayName,
              project.serverID == server.id,
              await refresh(
                  worker: server,
                  projects: projects,
                  launchDefaults: launchDefaults,
                  using: service
              ),
              let snapshot = await service.resumeThread(
                  kind: thread.kind,
                  repositoryName: project.displayName,
                  threadID: thread.threadID,
                  launchDefaults: launchDefaults,
                  on: server
              ) else {
            return nil
        }
        let shouldSelectResult = selectionRevision == openSelectionRevision
        let result = openConfirmedRemote(
            project: project,
            on: server,
            snapshot: snapshot,
            selectResult: shouldSelectResult,
            launchDefaults: launchDefaults
        )
        return shouldSelectResult ? result : nil
    }

    func invalidatePendingOpenSelection() {
        selectionRevision &+= 1
    }

    func selectSession(_ sessionID: UUID?) {
        invalidatePendingOpenSelection()
        selectedSessionID = sessionID
    }

    @discardableResult
    func openConfirmedRemote(
        project: ProjectProfile,
        on server: ServerProfile,
        snapshot: WorkerSessionSnapshot,
        selectResult: Bool = true,
        launchDefaults: AgentLaunchDefaults = .standard
    ) -> SessionOpenResult? {
        guard project.serverID == server.id,
              snapshot.repositoryName == project.displayName,
              let instanceID = UUID(uuidString: snapshot.instanceToken),
              instanceID.uuidString.lowercased() == snapshot.instanceToken else {
            return nil
        }

        if let occupant = sessions.first(where: {
            $0.serverKey == server.concurrencyKey
                && $0.instanceToken == snapshot.instanceToken
                && ($0.projectID != project.id
                    || $0.projectName != project.displayName
                    || $0.kind != snapshot.kind
                    || $0.presentation != snapshot.presentation)
        }) {
            return .occupied(SessionOccupant(session: occupant))
        }

        remoteSessions[
            RemoteSessionKey(
                serverKey: server.concurrencyKey,
                instanceToken: snapshot.instanceToken
            )
        ] = snapshot
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
                   confirmedSnapshot: snapshot,
                   selectReplacement: selectResult,
                   launchDefaults: launchDefaults
               ) {
                return .selectedExisting(replacement)
            }
            if selectResult {
                selectedSessionID = existing.id
            }
            return .selectedExisting(existing)
        }

        let session = TerminalSession(
            project: project,
            server: server,
            kind: snapshot.kind,
            sequenceNumber: nextSequenceNumber(projectID: project.id, kind: snapshot.kind),
            instanceToken: snapshot.instanceToken,
            terminalTitle: snapshot.title,
            threadID: snapshot.threadID,
            remoteAttachedClientCount: snapshot.attachedClientCount,
            presentation: snapshot.presentation,
            launchDefaults: launchDefaults
        )
        append(session)
        if selectResult {
            selectedSessionID = session.id
        }
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
            confirmedSnapshot: snapshot,
            selectReplacement: selectedSessionID == sessionID,
            launchDefaults: launchDefaults
        )
    }

    private func replaceDetachedSession(
        sessionID: UUID,
        project: ProjectProfile,
        on server: ServerProfile,
        confirmedSnapshot: WorkerSessionSnapshot,
        selectReplacement: Bool,
        launchDefaults: AgentLaunchDefaults = .standard
    ) -> TerminalSession? {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        let existing = sessions[index]
        guard existing.projectID == project.id,
              existing.serverKey == server.concurrencyKey,
              existing.projectName == project.displayName,
              existing.status.canReconnect,
              confirmedSnapshot.kind == existing.kind,
              confirmedSnapshot.repositoryName == existing.projectName,
              confirmedSnapshot.instanceToken == existing.instanceToken,
              confirmedSnapshot.presentation == existing.presentation else {
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
            threadID: confirmedSnapshot.threadID ?? existing.threadID,
            remoteAttachedClientCount: confirmedSnapshot.attachedClientCount,
            presentation: confirmedSnapshot.presentation,
            launchDefaults: launchDefaults
        )
        sessionObservers[existing.id] = nil
        taskCompletionObservers[existing.id] = nil
        sessions[index] = replacement
        observe(replacement)
        replacement.applyRemoteSnapshot(confirmedSnapshot)
        if selectReplacement {
            selectedSessionID = replacement.id
        }
        return replacement
    }

    func disconnect(sessionID: UUID) {
        backgroundAttachmentAttemptedSessionIDs.insert(sessionID)
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
        remoteSessions = remoteSessions.filter { $0.key.serverKey != server.concurrencyKey }
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

    func preloadRemoteSessions(for server: ServerProfile) {
        for session in sessions(for: server)
        where session.status == .remoteRunning
            && backgroundAttachmentAttemptedSessionIDs.insert(session.id).inserted {
            session.startIfNeeded()
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
        remoteSessions = remoteSessions.filter {
            $0.key.serverKey != worker.concurrencyKey
        }
        for snapshot in response.sessions {
            remoteSessions[
                RemoteSessionKey(
                    serverKey: worker.concurrencyKey,
                    instanceToken: snapshot.instanceToken
                )
            ] = snapshot
        }

        for session in sessions(for: worker) where session.status.occupiesSlot {
            let remote = remoteSessions[
                RemoteSessionKey(
                    serverKey: worker.concurrencyKey,
                    instanceToken: session.instanceToken
                )
            ]
            if session.status.canReconnect,
               (remote?.kind != session.kind || remote?.repositoryName != session.projectName) {
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
                    terminalTitle: snapshot.title,
                    threadID: snapshot.threadID,
                    remoteAttachedClientCount: snapshot.attachedClientCount,
                    presentation: snapshot.presentation,
                    launchDefaults: launchDefaults
                )
                append(session)
                session.applyRemoteSnapshot(snapshot)
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

        let remoteKey = RemoteSessionKey(
            serverKey: worker.concurrencyKey,
            instanceToken: session.instanceToken
        )
        guard let snapshot = remoteSessions[remoteKey],
              snapshot.kind == session.kind,
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
            presentation: session.presentation,
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
        if let latestSnapshot = remoteSessions[remoteKey],
           latestSnapshot.repositoryName != repositoryName
            || latestSnapshot.instanceToken != instanceToken {
            session.cancelRemoteStop()
            return false
        }

        remoteSessions.removeValue(forKey: remoteKey)
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

    @discardableResult
    func openTerminalFallbackAfterRefresh(
        sessionID: UUID,
        project: ProjectProfile,
        on worker: ServerProfile,
        projects: [ProjectProfile],
        launchDefaults: AgentLaunchDefaults,
        using service: WorkerSessionService
    ) async -> TerminalSession? {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.projectID == project.id,
              session.projectName == project.displayName,
              session.serverKey == worker.concurrencyKey,
              session.presentation == .chat,
              let threadID = session.threadID,
              await refresh(
                  worker: worker,
                  projects: projects,
                  launchDefaults: launchDefaults,
                  using: service
              ),
              await stopAgent(
                  sessionID: sessionID,
                  on: worker,
                  using: service
              ),
              let snapshot = await service.resumeThread(
                  kind: session.kind,
                  repositoryName: project.displayName,
                  threadID: threadID,
                  launchDefaults: launchDefaults,
                  preferredPresentation: .terminal,
                  on: worker
              ),
              snapshot.presentation == .terminal else {
            return nil
        }

        guard let result = openConfirmedRemote(
            project: project,
            on: worker,
            snapshot: snapshot,
            selectResult: true,
            launchDefaults: launchDefaults
        ), let terminalSession = result.localSession else {
            return nil
        }
        removeSession(id: sessionID)
        return terminalSession
    }

    private func append(_ session: TerminalSession) {
        sessions.append(session)
        observe(session)
    }

    private func observe(_ session: TerminalSession) {
        sessionObservers[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        taskCompletionObservers[session.id] = session.$taskCompletionCount
            .dropFirst()
            .sink { [weak self, weak session] _ in
                guard let self,
                      let session,
                      ApplicationSettings.showTaskCompletionNotifications(in: self.defaults) else {
                    return
                }
                self.taskCompletionHandler(session)
            }
    }

    private func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removedProjectID = sessions[index].projectID
        let removedInstanceToken = sessions[index].instanceToken
        sessions.remove(at: index)
        sessionObservers[id] = nil
        taskCompletionObservers[id] = nil
        backgroundAttachmentAttemptedSessionIDs.remove(id)
        sidebarSessionInstanceTokensByProject[removedProjectID.uuidString]?.removeAll {
            $0 == removedInstanceToken
        }
        persistSidebarSessionOrder()

        if selectedSessionID == id {
            selectedSessionID = sessions.last(where: { $0.projectID == removedProjectID })?.id
        }
    }

    private func nextSequenceNumber(projectID: UUID, kind: AgentKind) -> Int {
        let key = ProjectAgentKey(projectID: projectID, kind: kind)
        let nextNumber = (lastSequenceNumberByProjectAndKind[key] ?? 0) + 1
        lastSequenceNumberByProjectAndKind[key] = nextNumber
        return nextNumber
    }

    private func persistSidebarSessionOrder() {
        guard let data = try? JSONEncoder().encode(sidebarSessionInstanceTokensByProject) else {
            return
        }
        defaults.set(data, forKey: sidebarSessionOrderStorageKey)
    }

    private func claimOpenSelectionIntent() -> Int {
        invalidatePendingOpenSelection()
        return selectionRevision
    }

    private func confirmedRemoteSnapshot(
        for session: TerminalSession,
        on server: ServerProfile
    ) -> WorkerSessionSnapshot? {
        guard session.serverKey == server.concurrencyKey else { return nil }
        let snapshot = remoteSessions[
            RemoteSessionKey(
                serverKey: server.concurrencyKey,
                instanceToken: session.instanceToken
            )
        ]
        guard snapshot?.kind == session.kind,
              snapshot?.repositoryName == session.projectName,
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

private struct RemoteSessionKey: Hashable {
    let serverKey: String
    let instanceToken: String
}
