import Combine
import Foundation
import OSLog

private let sessionOrderLogger = Logger(
    subsystem: "com.mpieras.TerminalRelay",
    category: "session-order"
)

@MainActor
struct SessionOccupant {
    let kind: AgentKind
    let accountID: ProviderAccountID?
    let repositoryName: String
    let projectID: UUID?
    let localSession: TerminalSession?
    let attachedClientCount: Int?

    init(session: TerminalSession) {
        kind = session.kind
        accountID = session.accountID
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
        accountID = snapshot.accountID
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
    @Published private(set) var selectedSessionID: UUID? {
        didSet {
            if let selectedSessionID {
                unreadSessionIDs.remove(selectedSessionID)
            }
        }
    }
    @Published private(set) var unreadSessionIDs: Set<UUID> = []
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
    private var stopsInFlight = Set<UUID>()
    private var cacheSeededSessionIDs = Set<UUID>()
    // Chat rows one refresh has failed to list. Removal requires a second
    // consecutive miss: a transient listing hiccup (a failed chat-status
    // probe on a live worker) must revive the same row on the next refresh
    // instead of destroying its identity, selection, and unread state.
    private var unlistedChatSessionIDs = Set<UUID>()

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
            let result = openConfirmedRemote(
                project: fixture.project,
                on: worker,
                snapshot: fixture.snapshot,
                selectResult: false
            )
            if fixture.snapshot.title == "Review private pairing flow",
               let session = result?.localSession {
                unreadSessionIDs.insert(session.id)
            }
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
            .filter { $0.status != .stopping }
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

    /// Thread identities already represented by a live or launch-pending
    /// session row, keyed like WorkerThreadSnapshot.id ("kind:threadID").
    /// The sidebar must not also render a dormant thread row for these: a
    /// resume click appends the session row synchronously while the worker's
    /// thread catalog only reports relay-active after the chat-start round
    /// trip, and relying on the catalog alone briefly duplicated the
    /// conversation.
    func occupiedThreadKeys(
        forProjectID projectID: UUID,
        serverKey: String
    ) -> Set<String> {
        Set(
            sessions.compactMap { session -> String? in
                // A chat row in the one-refresh removal debounce still
                // represents its conversation; showing the dormant thread
                // beside it would reopen the duplicate window.
                guard session.projectID == projectID,
                      session.serverKey == serverKey,
                      session.isLaunchPending
                          || session.status.occupiesSlot
                          || unlistedChatSessionIDs.contains(session.id),
                      let threadID = session.threadID else {
                    return nil
                }
                if let accountID = session.accountID {
                    return "\(session.kind.rawValue):\(accountID.rawValue):\(threadID)"
                }
                return "\(session.kind.rawValue):\(threadID)"
            }
        )
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

    func activeSession(
        projectID: UUID,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> TerminalSession? {
        sessions.last {
            $0.projectID == projectID
                && $0.kind == kind
                && (accountID == nil || $0.accountID == accountID)
                && $0.status.occupiesSlot
        }
    }

    func sessions(for server: ServerProfile) -> [TerminalSession] {
        sessions.filter { $0.serverKey == server.concurrencyKey }
    }

    func activeSession(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> TerminalSession? {
        sessions.last {
            $0.serverKey == server.concurrencyKey
                && $0.kind == kind
                && (accountID == nil || $0.accountID == accountID)
                && $0.status.occupiesSlot
        }
    }

    func occupant(
        for server: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> SessionOccupant? {
        if let localSession = activeSession(
            for: server,
            kind: kind,
            accountID: accountID
        ) {
            return SessionOccupant(session: localSession)
        }

        if let snapshot = remoteSessions.first(where: {
            $0.key.serverKey == server.concurrencyKey
                && $0.value.kind == kind
                && (accountID == nil || $0.value.accountID == accountID)
        })?.value {
            let localSession = sessions.last {
                $0.serverKey == server.concurrencyKey
                    && $0.kind == kind
                    && $0.accountID == snapshot.accountID
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
    func openNewSession(
        project: ProjectProfile,
        on server: ServerProfile,
        account: ProviderAccountProfile,
        launchDefaults: AgentLaunchDefaults,
        onPendingSession: ((TerminalSession) -> Void)? = nil,
        using service: WorkerSessionService
    ) async -> SessionOpenResult? {
        await openNewSession(
            project: project,
            on: server,
            kind: account.provider,
            account: account,
            launchDefaults: launchDefaults,
            onPendingSession: onPendingSession,
            using: service
        )
    }

    @discardableResult
    func openNewSession(
        project: ProjectProfile,
        on server: ServerProfile,
        kind: AgentKind,
        account: ProviderAccountProfile? = nil,
        launchDefaults: AgentLaunchDefaults,
        onPendingSession: ((TerminalSession) -> Void)? = nil,
        using service: WorkerSessionService
    ) async -> SessionOpenResult? {
        guard project.serverID == server.id,
              account.map({ $0.provider == kind && $0.status.isUsable }) != false else {
            return nil
        }

        invalidatePendingOpenSelection()
        let pendingSession = TerminalSession(
            project: project,
            server: server,
            kind: kind,
            account: account,
            sequenceNumber: nextSequenceNumber(
                projectID: project.id,
                kind: kind,
                accountID: account?.accountID
            ),
            instanceToken: UUID().uuidString.lowercased(),
            presentation: .chat,
            launchState: .starting,
            launchDefaults: launchDefaults
        )
        append(pendingSession)
        selectedSessionID = pendingSession.id
        onPendingSession?(pendingSession)
        let openSelectionRevision = selectionRevision

        guard let snapshot = await service.start(
            kind: kind,
            account: account,
            repositoryName: project.displayName,
            launchDefaults: launchDefaults,
            on: server
        ),
        snapshot.kind == kind,
        snapshot.accountID == account?.accountID,
        snapshot.repositoryName == project.displayName else {
            pendingSession.markLaunchFailed(
                service.error(for: server.id)
                    ?? "The worker could not start this agent."
            )
            return nil
        }

        let shouldSelectResult = selectionRevision == openSelectionRevision
            && selectedSessionID == pendingSession.id
        guard let session = replacePendingSession(
            pendingSession,
            project: project,
            on: server,
            snapshot: snapshot,
            account: account,
            launchDefaults: launchDefaults
        ) else {
            pendingSession.markLaunchFailed("The worker returned an invalid agent session.")
            return nil
        }
        return shouldSelectResult ? .opened(session) : nil
    }

    @discardableResult
    func resumeThread(
        _ thread: WorkerThreadSnapshot,
        project: ProjectProfile,
        on server: ServerProfile,
        account: ProviderAccountProfile? = nil,
        launchDefaults: AgentLaunchDefaults,
        onPendingSession: ((TerminalSession) -> Void)? = nil,
        using service: WorkerSessionService
    ) async -> SessionOpenResult? {
        guard thread.activityState == .inactive,
              thread.capabilities.resume,
              thread.repositoryName == project.displayName,
              project.serverID == server.id,
              account.map({
                  $0.provider == thread.kind
                      && $0.accountID == thread.accountID
                      && $0.status.isUsable
              }) != false else {
            return nil
        }

        if let existingSession = sessions.first(where: {
            $0.projectID == project.id
                && $0.serverKey == server.concurrencyKey
                && $0.kind == thread.kind
                && $0.accountID == thread.accountID
                && $0.threadID == thread.threadID
                && ($0.isLaunchPending || $0.status.occupiesSlot)
        }) {
            if selectedSessionID != existingSession.id {
                selectSession(existingSession.id)
            }
            return .selectedExisting(existingSession)
        }

        // A previous failed or exited row for this thread would sit beside
        // the new pending row as a dead duplicate; the fresh resume replaces
        // it.
        for leftover in sessions where leftover.projectID == project.id
            && leftover.serverKey == server.concurrencyKey
            && leftover.kind == thread.kind
            && leftover.accountID == thread.accountID
            && leftover.threadID == thread.threadID
            && leftover.status != .stopping {
            removeSession(id: leftover.id)
        }

        invalidatePendingOpenSelection()
        // The resumed conversation keeps the thread's own recency so the row
        // stays where the user clicked it instead of teleporting to the top;
        // real activity bumps it later.
        sessionOrderLogger.notice(
            "Resuming \(thread.kind.rawValue, privacy: .public) thread \(thread.threadID, privacy: .public) for \(thread.repositoryName, privacy: .public); inherited activity \(thread.updatedAt, privacy: .public)"
        )
        let pendingSession = TerminalSession(
            project: project,
            server: server,
            kind: thread.kind,
            account: account,
            accountID: thread.accountID,
            sequenceNumber: nextSequenceNumber(
                projectID: project.id,
                kind: thread.kind,
                accountID: thread.accountID
            ),
            instanceToken: UUID().uuidString.lowercased(),
            lastActivityAt: Date(timeIntervalSince1970: TimeInterval(thread.updatedAt)),
            terminalTitle: thread.title,
            threadID: thread.threadID,
            presentation: .chat,
            launchState: .starting,
            launchDefaults: launchDefaults
        )
        append(pendingSession)
        selectedSessionID = pendingSession.id
        onPendingSession?(pendingSession)
        let openSelectionRevision = selectionRevision

        guard let snapshot = await service.resumeThread(
            kind: thread.kind,
            accountID: thread.accountID,
            repositoryName: project.displayName,
            threadID: thread.threadID,
            launchDefaults: launchDefaults,
            on: server
        ), snapshot.accountID == thread.accountID else {
            pendingSession.markLaunchFailed(
                service.error(for: server.id)
                    ?? "The worker could not load this conversation."
            )
            return nil
        }
        let shouldSelectResult = selectionRevision == openSelectionRevision
            && selectedSessionID == pendingSession.id
        guard let session = replacePendingSession(
            pendingSession,
            project: project,
            on: server,
            snapshot: snapshot,
            account: account,
            launchDefaults: launchDefaults
        ) else {
            pendingSession.markLaunchFailed("The worker returned an invalid conversation.")
            return nil
        }
        return shouldSelectResult ? .opened(session) : nil
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
        account: ProviderAccountProfile? = nil,
        selectResult: Bool = true,
        launchDefaults: AgentLaunchDefaults = .standard
    ) -> SessionOpenResult? {
        guard project.serverID == server.id,
              snapshot.repositoryName == project.displayName,
              account.map({
                  $0.provider == snapshot.kind && $0.accountID == snapshot.accountID
              }) != false,
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
                    || $0.accountID != snapshot.accountID
                    || $0.presentation != snapshot.presentation)
        }) {
            return .occupied(SessionOccupant(session: occupant))
        }

        remoteSessions[
            RemoteSessionKey(
                serverKey: server.concurrencyKey,
                kind: snapshot.kind,
                accountID: snapshot.accountID,
                instanceToken: snapshot.instanceToken
            )
        ] = snapshot
        if let existing = sessions.last(where: {
            $0.projectID == project.id
                && $0.serverKey == server.concurrencyKey
                && $0.kind == snapshot.kind
                && $0.accountID == snapshot.accountID
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
            account: account,
            accountID: snapshot.accountID,
            sequenceNumber: nextSequenceNumber(
                projectID: project.id,
                kind: snapshot.kind,
                accountID: snapshot.accountID
            ),
            instanceToken: snapshot.instanceToken,
            lastActivityAt: snapshot.lastActivityAt.map {
                Date(timeIntervalSince1970: TimeInterval($0))
            },
            terminalTitle: snapshot.title,
            threadID: snapshot.threadID,
            remoteAttachedClientCount: snapshot.attachedClientCount,
            presentation: snapshot.presentation,
            launchDefaults: launchDefaults
        )
        append(session)
        session.applyRemoteSnapshot(snapshot)
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
              confirmedSnapshot.accountID == existing.accountID,
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
            accountID: existing.accountID,
            accountLabel: existing.accountLabel,
            sequenceNumber: existing.sequenceNumber,
            instanceToken: launchIdentity,
            id: existing.id,
            startedAt: existing.startedAt,
            lastActivityAt: existing.lastActivityAt,
            lastActivityIsFallback: existing.lastActivityIsFallback,
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

    private func replacePendingSession(
        _ pendingSession: TerminalSession,
        project: ProjectProfile,
        on server: ServerProfile,
        snapshot: WorkerSessionSnapshot,
        account: ProviderAccountProfile? = nil,
        launchDefaults: AgentLaunchDefaults
    ) -> TerminalSession? {
        guard pendingSession.isLaunchPending,
              project.serverID == server.id,
              pendingSession.projectID == project.id,
              pendingSession.serverKey == server.concurrencyKey,
              pendingSession.kind == snapshot.kind,
              pendingSession.accountID == snapshot.accountID,
              snapshot.repositoryName == project.displayName,
              snapshot.presentation == .chat,
              let instanceID = UUID(uuidString: snapshot.instanceToken),
              instanceID.uuidString.lowercased() == snapshot.instanceToken,
              !sessions.contains(where: {
                  $0 !== pendingSession
                      && $0.serverKey == server.concurrencyKey
                      && $0.accountID == snapshot.accountID
                      && $0.instanceToken == snapshot.instanceToken
              }),
              let index = sessions.firstIndex(where: { $0 === pendingSession }) else {
            return nil
        }

        remoteSessions[
            RemoteSessionKey(
                serverKey: server.concurrencyKey,
                kind: snapshot.kind,
                accountID: snapshot.accountID,
                instanceToken: snapshot.instanceToken
            )
        ] = snapshot
        let terminalTitle = snapshot.title.flatMap { title in
            title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : title
        } ?? pendingSession.terminalTitle
        let replacement = TerminalSession(
            project: project,
            server: server,
            kind: snapshot.kind,
            account: account,
            accountID: snapshot.accountID,
            accountLabel: pendingSession.accountLabel,
            sequenceNumber: pendingSession.sequenceNumber,
            instanceToken: snapshot.instanceToken,
            id: pendingSession.id,
            terminalViewIdentity: pendingSession.terminalViewIdentity,
            startedAt: pendingSession.startedAt,
            lastActivityAt: pendingSession.lastActivityAt,
            lastActivityIsFallback: pendingSession.lastActivityIsFallback,
            initialStatus: .connecting,
            terminalTitle: terminalTitle,
            threadID: snapshot.threadID,
            remoteAttachedClientCount: snapshot.attachedClientCount,
            presentation: snapshot.presentation,
            launchDefaults: launchDefaults,
            initialChatState: pendingSession.chatCoordinator.flatMap {
                $0.store.state.items.isEmpty ? nil : $0.store.state
            }
        )
        sessionObservers[pendingSession.id] = nil
        taskCompletionObservers[pendingSession.id] = nil
        sessions[index] = replacement
        observe(replacement)
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

    /// Materializes last-known session rows from a persisted response so the
    /// sidebar renders them at launch without waiting for SSH. Rows the next
    /// real refresh does not confirm are removed rather than marked exited.
    func restoreCachedSessions(
        worker: ServerProfile,
        projects: [ProjectProfile],
        response: WorkerSessionResponse,
        accounts: [ProviderAccountProfile] = [],
        launchDefaults: AgentLaunchDefaults
    ) {
        let existingIDs = Set(sessions.map(\.id))
        reconcile(
            worker: worker,
            projects: projects,
            response: response,
            accounts: accounts,
            launchDefaults: launchDefaults
        )
        let seededIDs = sessions.map(\.id).filter { !existingIDs.contains($0) }
        cacheSeededSessionIDs.formUnion(seededIDs)
        sessionOrderLogger.notice(
            "Seeded \(seededIDs.count, privacy: .public) cached session rows for \(worker.destination, privacy: .public)"
        )
    }

    @discardableResult
    func refresh(
        worker: ServerProfile,
        projects: [ProjectProfile],
        accounts: [ProviderAccountProfile] = [],
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
            accounts: accounts,
            launchDefaults: launchDefaults
        )
        return true
    }

    func reconcile(
        worker: ServerProfile,
        projects: [ProjectProfile],
        response: WorkerSessionResponse,
        accounts: [ProviderAccountProfile] = [],
        launchDefaults: AgentLaunchDefaults
    ) {
        remoteSessions = remoteSessions.filter {
            $0.key.serverKey != worker.concurrencyKey
        }
        for snapshot in response.sessions {
            remoteSessions[
                RemoteSessionKey(
                    serverKey: worker.concurrencyKey,
                    kind: snapshot.kind,
                    accountID: snapshot.accountID,
                    instanceToken: snapshot.instanceToken
                )
            ] = snapshot
        }

        let previouslyUnlistedChatSessionIDs = unlistedChatSessionIDs
        for session in sessions(for: worker) where session.status.occupiesSlot {
            let remote = remoteSessions[
                RemoteSessionKey(
                    serverKey: worker.concurrencyKey,
                    kind: session.kind,
                    accountID: session.accountID,
                    instanceToken: session.instanceToken
                )
            ]
            guard session.status.canReconnect,
                  remote?.kind != session.kind
                    || remote?.accountID != session.accountID
                    || remote?.repositoryName != session.projectName else {
                continue
            }
            // A cache-restored row the worker never confirmed has no exit to
            // report; drop it silently instead of leaving a dimmed ghost.
            if cacheSeededSessionIDs.contains(session.id) {
                removeSession(id: session.id)
            } else if session.presentation == .chat, session.threadID != nil {
                // First miss: keep the row (a transient listing hiccup must
                // not destroy its identity) but mark it; the follow-up sweep
                // below removes it if a second refresh confirms the relay is
                // really gone. The dormant thread row then becomes the
                // conversation's single representation.
                unlistedChatSessionIDs.insert(session.id)
                session.markRemoteExited()
            } else {
                session.markRemoteExited()
            }
        }

        // Second consecutive refresh without the relay: drop the exited chat
        // row so it cannot duplicate the dormant thread row or accumulate on
        // re-resume. A relay listed again instead revives the same row via
        // applyRemoteSnapshot below.
        for session in sessions(for: worker)
        where !session.status.occupiesSlot
            && previouslyUnlistedChatSessionIDs.contains(session.id) {
            let remote = remoteSessions[
                RemoteSessionKey(
                    serverKey: worker.concurrencyKey,
                    kind: session.kind,
                    accountID: session.accountID,
                    instanceToken: session.instanceToken
                )
            ]
            if remote?.kind == session.kind,
               remote?.accountID == session.accountID,
               remote?.repositoryName == session.projectName {
                unlistedChatSessionIDs.remove(session.id)
            } else {
                removeSession(id: session.id)
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
                    && $0.accountID == snapshot.accountID
                    && $0.instanceToken == snapshot.instanceToken
            }
            if let existing {
                cacheSeededSessionIDs.remove(existing.id)
                existing.applyRemoteSnapshot(snapshot)
            } else {
                // A launch-pending row is mid-flight to adopt this relay's
                // token via replacePendingSession; adopting it here too
                // would render the conversation twice and then fail the
                // pending launch on the duplicate-token guard. If the
                // launch never claims it, the next refresh adopts it.
                if snapshot.presentation == .chat,
                   sessions.contains(where: {
                       $0.projectID == project.id
                           && $0.serverKey == worker.concurrencyKey
                           && $0.kind == snapshot.kind
                           && $0.accountID == snapshot.accountID
                           && $0.isLaunchPending
                           && ($0.threadID == nil || $0.threadID == snapshot.threadID)
                   }) {
                    sessionOrderLogger.notice(
                        "Deferring adoption of \(snapshot.kind.rawValue, privacy: .public) session \(snapshot.instanceToken, privacy: .public) for \(snapshot.repositoryName, privacy: .public) while a launch is pending"
                    )
                    continue
                }
                sessionOrderLogger.notice(
                    "Adopting remote \(snapshot.kind.rawValue, privacy: .public) session \(snapshot.instanceToken, privacy: .public) for \(snapshot.repositoryName, privacy: .public); reported activity \(snapshot.lastActivityAt.map(String.init) ?? "none", privacy: .public)"
                )
                let session = TerminalSession(
                    project: project,
                    server: worker,
                    kind: snapshot.kind,
                    account: accounts.first {
                        $0.provider == snapshot.kind
                            && $0.accountID == snapshot.accountID
                    },
                    accountID: snapshot.accountID,
                    accountLabel: snapshot.accountID.map {
                        "Account \($0.rawValue.prefix(8))"
                    },
                    sequenceNumber: nextSequenceNumber(
                        projectID: project.id,
                        kind: snapshot.kind,
                        accountID: snapshot.accountID
                    ),
                    instanceToken: snapshot.instanceToken,
                    lastActivityAt: snapshot.lastActivityAt.map {
                        Date(timeIntervalSince1970: TimeInterval($0))
                    },
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

    /// Marks a session as stopping before its remote stop lands so the UI can
    /// drop it immediately; `stopAgent` completes or cancels the state later.
    func beginArchiveStop(sessionID: UUID) {
        guard let session = sessions.first(where: { $0.id == sessionID }),
              session.status.occupiesSlot else {
            return
        }
        session.beginRemoteStop()
        if selectedSessionID == sessionID {
            selectedSessionID = sessions.last(where: {
                $0.projectID == session.projectID && $0.status != .stopping
            })?.id
        }
    }

    func cancelArchiveStop(sessionID: UUID) {
        sessions.first(where: { $0.id == sessionID })?.cancelRemoteStop()
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
              stopsInFlight.insert(sessionID).inserted else {
            return false
        }
        defer { stopsInFlight.remove(sessionID) }

        let remoteKey = RemoteSessionKey(
            serverKey: worker.concurrencyKey,
            kind: session.kind,
            accountID: session.accountID,
            instanceToken: session.instanceToken
        )
        guard let snapshot = remoteSessions[remoteKey],
              snapshot.kind == session.kind,
              snapshot.accountID == session.accountID,
              snapshot.repositoryName == session.projectName,
              snapshot.instanceToken == session.instanceToken else {
            return false
        }
        let repositoryName = session.projectName
        let instanceToken = session.instanceToken
        session.beginRemoteStop()

        guard await service.stop(
            kind: session.kind,
            accountID: session.accountID,
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

    func append(_ session: TerminalSession) {
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
                guard let self, let session else { return }
                if self.selectedSessionID != session.id {
                    self.unreadSessionIDs.insert(session.id)
                }
                if ApplicationSettings.showTaskCompletionNotifications(in: self.defaults) {
                    self.taskCompletionHandler(session)
                }
            }
    }

    private func removeSession(id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let removedProjectID = sessions[index].projectID
        let removedInstanceToken = sessions[index].instanceToken
        sessions.remove(at: index)
        sessionObservers[id] = nil
        taskCompletionObservers[id] = nil
        unreadSessionIDs.remove(id)
        backgroundAttachmentAttemptedSessionIDs.remove(id)
        cacheSeededSessionIDs.remove(id)
        unlistedChatSessionIDs.remove(id)
        sidebarSessionInstanceTokensByProject[removedProjectID.uuidString]?.removeAll {
            $0 == removedInstanceToken
        }
        persistSidebarSessionOrder()

        if selectedSessionID == id {
            selectedSessionID = sessions.last(where: { $0.projectID == removedProjectID })?.id
        }
    }

    private func nextSequenceNumber(
        projectID: UUID,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> Int {
        let key = ProjectAgentKey(
            projectID: projectID,
            kind: kind,
            accountID: accountID
        )
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

    private func confirmedRemoteSnapshot(
        for session: TerminalSession,
        on server: ServerProfile
    ) -> WorkerSessionSnapshot? {
        guard session.serverKey == server.concurrencyKey else { return nil }
        let snapshot = remoteSessions[
            RemoteSessionKey(
                serverKey: server.concurrencyKey,
                kind: session.kind,
                accountID: session.accountID,
                instanceToken: session.instanceToken
            )
        ]
        guard snapshot?.kind == session.kind,
              snapshot?.accountID == session.accountID,
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
    let accountID: ProviderAccountID?
}

private struct RemoteSessionKey: Hashable {
    let serverKey: String
    let kind: AgentKind
    let accountID: ProviderAccountID?
    let instanceToken: String
}
