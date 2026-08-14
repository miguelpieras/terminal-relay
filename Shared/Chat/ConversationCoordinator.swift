import Foundation

struct ChatRetryPolicy: Equatable, Sendable {
    let maximumAutomaticRetries: Int
    let initialDelayNanoseconds: UInt64
    let maximumDelayNanoseconds: UInt64
    // How long a sent attach may wait for its first inbound envelope before
    // the transport is presumed undelivered. A transport reports "connected"
    // once its process spawns and accepts writes into a local pipe, so a sent
    // attach proves nothing about the worker — when nothing at all comes
    // back, the coordinator tears the transport down and reconnects through
    // the normal retry loop instead of surfacing a failure. A healthy attach
    // answers in under a second.
    var attachResponseGraceNanoseconds: UInt64 = 10_000_000_000
    // How long an attached conversation may sit in "connecting" while the
    // transport IS delivering events (heartbeats, the early-ready placeholder
    // snapshot). The broker aborts a hung resume itself after 120 seconds and
    // reports a terminal session.ended, so this fires only when the broker is
    // wedged past its own deadline — the one case Retry cannot fix.
    var connectingGraceNanoseconds: UInt64 = 150_000_000_000

    static let standard = ChatRetryPolicy(
        maximumAutomaticRetries: 5,
        initialDelayNanoseconds: 500_000_000,
        maximumDelayNanoseconds: 8_000_000_000
    )

    static let immediate = ChatRetryPolicy(
        maximumAutomaticRetries: 0,
        initialDelayNanoseconds: 0,
        maximumDelayNanoseconds: 0
    )
}

struct ChatStopPolicy: Equatable, Sendable {
    let confirmationPollCount: Int
    let pollDelayNanoseconds: UInt64

    static let standard = ChatStopPolicy(
        confirmationPollCount: 25,
        pollDelayNanoseconds: 100_000_000
    )

    static let immediate = ChatStopPolicy(
        confirmationPollCount: 20,
        pollDelayNanoseconds: 0
    )
}

enum ConversationCoordinatorError: LocalizedError, Equatable {
    case invalidIdentity
    case emptyPrompt
    case promptTooLarge
    case tooManyAttachments
    case attachmentsTooLarge
    case attachmentPathTooLarge
    case turnAlreadyActive
    case noActiveTurn
    case interactionUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            "This chat has invalid session identifiers."
        case .emptyPrompt:
            "Write a message before sending."
        case .promptTooLarge:
            "This message is larger than the 256 KiB chat limit."
        case .tooManyAttachments:
            "A turn can include at most 32 attachments."
        case .attachmentsTooLarge:
            "The selected attachments exceed the 100 MiB per-message limit."
        case .attachmentPathTooLarge:
            "An attachment path is too long to send safely."
        case .turnAlreadyActive:
            "Wait for the current turn to finish before sending another message."
        case .noActiveTurn:
            "There is no active turn to stop."
        case .interactionUnavailable:
            "This request is no longer available."
        }
    }
}

@MainActor
final class ConversationCoordinator {
    private enum LifecycleTransition: Equatable {
        case detaching
        case stopping
    }

    private struct PendingTurn {
        let text: String
        let attachments: [ChatAttachmentReference]
    }

    private struct PendingInterrupt {
        let requestID: String
        let turnID: String
    }

    let store: ConversationStore
    let identity: ChatConversationIdentity

    private let transport: any ChatTransport
    private var launchOptions: ChatLaunchOptions
    private let retryPolicy: ChatRetryPolicy
    private let stopPolicy: ChatStopPolicy
    private let cache: (any ConversationStateCaching)?
    private let cachedHydrationWillApply: (@MainActor () async -> Void)?
    private var didAttemptHydration = false
    private var previewHydrationTask: Task<Void, Never>?
    private var previewHydrationToken: UInt64 = 0
    private var cacheSaveTask: Task<Void, Never>?
    private var suppressCachePersistenceUntilAuthoritativeSnapshot = false
    private var lifecycleTask: Task<Void, Never>?
    private var lifecycleEpoch: UInt64 = 0
    private var lifecycleTransition: LifecycleTransition?
    private var startRequestedAfterDetach = false
    private var detachRequestedAfterStop = false
    private var retryTask: Task<Void, Never>?
    private var retrySleepTask: Task<Void, Never>?
    private var retrySleepToken: UUID?
    private var connectingWatchdogTask: Task<Void, Never>?
    private var attachGeneration: UInt64 = 0
    private var shouldStayConnected = false
    private var isAttached = false
    private var hasReceivedEnvelopeSinceAttach = false
    private var needsFreshSnapshot = false
    private var pendingInteractionByCommand: [String: String] = [:]
    private var pendingTurnByCommand: [String: PendingTurn] = [:]
    private var unconfirmedTurnByCommand: [String: PendingTurn] = [:]
    private var pendingInterrupt: PendingInterrupt?
    private var isStopping = false
    private var stopRequestID: String?
    private var stopWasConfirmed = false
    private var stopEnvelope: ChatEnvelope?

    init(
        store: ConversationStore? = nil,
        transport: any ChatTransport,
        identity: ChatConversationIdentity,
        launchOptions: ChatLaunchOptions = ChatLaunchOptions(),
        retryPolicy: ChatRetryPolicy = .standard,
        stopPolicy: ChatStopPolicy = .standard,
        cache: (any ConversationStateCaching)? = nil,
        cachedHydrationWillApply: (@MainActor () async -> Void)? = nil
    ) {
        self.store = store ?? ConversationStore()
        self.transport = transport
        self.identity = identity
        self.launchOptions = launchOptions
        self.retryPolicy = retryPolicy
        self.stopPolicy = stopPolicy
        self.cache = cache
        self.cachedHydrationWillApply = cachedHydrationWillApply
    }

    deinit {
        lifecycleTask?.cancel()
        retryTask?.cancel()
        retrySleepTask?.cancel()
        connectingWatchdogTask?.cancel()
        previewHydrationTask?.cancel()
        cacheSaveTask?.cancel()
    }

    func start() {
        if lifecycleTransition != nil {
            if lifecycleTransition == .detaching {
                startRequestedAfterDetach = true
            }
            return
        }
        guard lifecycleTask == nil, retryTask == nil else {
            expediteReconnectIfWaiting()
            return
        }
        guard identity.isValid else {
            store.setConnectionState(
                .failed,
                message: ConversationCoordinatorError.invalidIdentity.localizedDescription
            )
            return
        }
        shouldStayConnected = true
        store.setConnectionState(.connecting)
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        lifecycleTask = Task { [weak self] in
            await self?.hydrateFromCacheIfNeeded(lifecycleEpoch: epoch)
            guard let self, self.canContinueLifecycle(epoch) else { return }
            await self.runConnectionLoop(lifecycleEpoch: epoch)
        }
    }

    /// Skips the remainder of a reconnect backoff sleep, if one is pending.
    /// Called when the user opens the conversation: a transcript someone is
    /// looking at never waits out a multi-second backoff.
    func expediteReconnectIfWaiting() {
        retrySleepTask?.cancel()
    }

    /// Paints cached history without connecting — used by the launch-pending
    /// pane so a cold worker resume shows the conversation immediately while
    /// the real session starts. Safe to call at most once; start() skips
    /// hydration if this already ran.
    func hydrateForPreview() {
        guard previewHydrationTask == nil else { return }
        previewHydrationToken &+= 1
        let token = previewHydrationToken
        previewHydrationTask = Task { [weak self] in
            await self?.hydrateFromCacheIfNeeded()
            self?.finishPreviewHydration(token: token)
        }
    }

    private func finishPreviewHydration(token: UInt64) {
        guard previewHydrationToken == token else { return }
        previewHydrationTask = nil
    }

    private func cancelPreviewHydration() {
        previewHydrationToken &+= 1
        previewHydrationTask?.cancel()
        previewHydrationTask = nil
    }

    /// Paints the transcript from the on-disk cache before the first connect,
    /// so opening a known thread shows content immediately. The subsequent
    /// attach resumes from the cached cursor and reconciles with the worker.
    private func hydrateFromCacheIfNeeded(
        lifecycleEpoch expectedEpoch: UInt64? = nil
    ) async {
        guard !didAttemptHydration else { return }
        didAttemptHydration = true
        guard let cache, store.lastAppliedSequence == 0 else { return }
        let cached = await cache.load(for: identity)
        if cached != nil, let cachedHydrationWillApply {
            await cachedHydrationWillApply()
        }
        guard canContinueLifecycle(expectedEpoch) else {
            didAttemptHydration = false
            return
        }
        guard let cached else { return }
        async let preparedProjections = ConversationStore
            .prepareTranscriptProjections(for: cached.items)
        await warmRecentMarkdown(for: cached.items)
        guard canContinueLifecycle(expectedEpoch) else {
            didAttemptHydration = false
            return
        }
        let prepared = await preparedProjections
        guard canContinueLifecycle(expectedEpoch) else {
            didAttemptHydration = false
            return
        }
        store.hydrateFromCache(
            cached,
            preparedProjections: prepared
        )
    }

    /// Persists the current state after live updates, debounced so streaming
    /// deltas coalesce into one write when the stream quiets.
    private func scheduleCacheSave(immediate: Bool = false) {
        guard cache != nil,
              !suppressCachePersistenceUntilAuthoritativeSnapshot else {
            return
        }
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled, let self, let cache = self.cache else {
                return
            }
            guard !self.suppressCachePersistenceUntilAuthoritativeSnapshot else {
                return
            }
            let snapshot = self.store.stateForCachePersistence
            await cache.save(snapshot, for: self.identity)
        }
    }

    func updateLaunchOptions(_ options: ChatLaunchOptions) {
        launchOptions = options
    }

    func updateLaunchOptions(
        model: String?,
        reasoningEffort: String?,
        fastMode: Bool?
    ) {
        launchOptions.model = model
        launchOptions.reasoningEffort = reasoningEffort
        launchOptions.fastMode = fastMode
    }

    func detach() async {
        cancelPreviewHydration()
        if lifecycleTransition == .stopping {
            detachRequestedAfterStop = true
            return
        }
        guard lifecycleTransition == nil else { return }
        lifecycleTransition = .detaching
        defer {
            lifecycleTransition = nil
            if startRequestedAfterDetach {
                startRequestedAfterDetach = false
                start()
            }
        }
        shouldStayConnected = false
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        let previousRetryTask = retryTask
        previousRetryTask?.cancel()
        retryTask = nil
        let previousLifecycleTask = lifecycleTask
        previousLifecycleTask?.cancel()
        lifecycleTask = nil
        retrySleepTask?.cancel()
        retrySleepTask = nil
        retrySleepToken = nil
        let shouldSendDetach = isAttached
        resetReconnectScopedState()

        let detachEnvelope = shouldSendDetach
            ? try? ChatCommand.detach.envelope(identity: identity)
            : nil
        guard lifecycleEpoch == epoch, lifecycleTransition == .detaching else {
            return
        }
        isAttached = false
        await transport.disconnect(sendingBestEffort: detachEnvelope)
        _ = await previousRetryTask?.value
        _ = await previousLifecycleTask?.value
        guard lifecycleEpoch == epoch, lifecycleTransition == .detaching else {
            return
        }
        store.setConnectionState(.offlineAgentRunning)
        cacheSaveTask?.cancel()
        if let cache,
           !suppressCachePersistenceUntilAuthoritativeSnapshot {
            let snapshot = store.stateForCachePersistence
            await cache.save(snapshot, for: identity)
        }
    }

    func retry() {
        guard retryTask == nil, lifecycleTransition == nil else { return }
        cancelPreviewHydration()
        shouldStayConnected = false
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        let previousLifecycleTask = lifecycleTask
        previousLifecycleTask?.cancel()
        lifecycleTask = nil
        retrySleepTask?.cancel()
        retrySleepTask = nil
        retrySleepToken = nil
        resetReconnectScopedState()
        store.setConnectionState(.connecting)
        let task = Task { [weak self] in
            guard let self else { return }
            await transport.disconnect()
            _ = await previousLifecycleTask?.value
            guard !Task.isCancelled,
                  lifecycleEpoch == epoch,
                  lifecycleTransition == nil else {
                if lifecycleEpoch == epoch {
                    retryTask = nil
                }
                return
            }
            shouldStayConnected = true
            retryTask = nil
            start()
        }
        retryTask = task
    }

    func sendDraft() async {
        let text = store.draft
        let attachments = store.attachments
        await send(text: text, attachments: attachments)
    }

    @discardableResult
    func send(
        text: String,
        attachments: [ChatAttachmentReference] = [],
        requestID suppliedRequestID: String? = nil
    ) async -> Bool {
        do {
            try validatePrompt(text, attachments: attachments)
            guard !store.hasActiveWorkingTurn, pendingTurnByCommand.isEmpty else {
                throw ConversationCoordinatorError.turnAlreadyActive
            }
            let requestID = suppliedRequestID ?? UUID().uuidString.lowercased()
            let envelope = try ChatCommand.startTurn(
                text: text,
                attachments: attachments,
                options: launchOptions
            ).envelope(identity: identity, requestID: requestID)

            store.clearComposer()
            pendingTurnByCommand[requestID] = PendingTurn(
                text: text,
                attachments: attachments
            )
            let optimisticItem = ConversationStore.optimisticUserMessage(
                requestID: requestID,
                text: text,
                occurredAt: Int64(Date().timeIntervalSince1970 * 1_000)
            )
            let prepared = await ConversationStore.prepareTranscriptProjections(
                for: [optimisticItem]
            )
            guard pendingTurnByCommand[requestID] != nil,
                  prepared[optimisticItem.id] != nil else {
                let abandoned = pendingTurnByCommand.removeValue(forKey: requestID)
                    ?? unconfirmedTurnByCommand.removeValue(forKey: requestID)
                if let abandoned {
                    store.restoreFailedSubmission(
                        text: abandoned.text,
                        attachments: abandoned.attachments
                    )
                }
                throw ConversationCoordinatorError.interactionUnavailable
            }
            guard !store.hasActiveWorkingTurn else {
                let rejected = pendingTurnByCommand.removeValue(forKey: requestID)
                if let rejected {
                    store.restoreFailedSubmission(
                        text: rejected.text,
                        attachments: rejected.attachments
                    )
                }
                throw ConversationCoordinatorError.turnAlreadyActive
            }
            store.addOptimisticUserMessage(
                optimisticItem,
                preparedTranscriptProjections: prepared
            )
            do {
                try await transport.send(envelope)
            } catch {
                let failedTurn = pendingTurnByCommand.removeValue(forKey: requestID)
                    ?? unconfirmedTurnByCommand.removeValue(forKey: requestID)
                store.removeOptimisticUserMessage(requestID: requestID)
                if let failedTurn {
                    store.restoreFailedSubmission(
                        text: failedTurn.text,
                        attachments: failedTurn.attachments
                    )
                }
                throw error
            }
            return true
        } catch {
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
            return false
        }
    }

    func interrupt() async {
        guard let turnID = store.state.activeTurnID else {
            store.setConnectionState(
                store.state.connectionState,
                message: ConversationCoordinatorError.noActiveTurn.localizedDescription
            )
            return
        }
        guard pendingInterrupt?.turnID != turnID else { return }
        let requestID = UUID().uuidString.lowercased()
        pendingInterrupt = PendingInterrupt(requestID: requestID, turnID: turnID)
        do {
            guard identity.isValid else {
                throw ConversationCoordinatorError.invalidIdentity
            }
            try await transport.send(
                ChatCommand.interrupt(turnID: turnID).envelope(
                    identity: identity,
                    requestID: requestID
                )
            )
        } catch {
            if pendingInterrupt?.requestID == requestID {
                pendingInterrupt = nil
            }
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
        }
    }

    func respond(to approvalID: String, decisionID: String, permissionChanges: JSONValue? = nil) async {
        guard let approval = store.state.approvals.first(where: {
            $0.id == approvalID && $0.status == .pending
        }), !store.respondingInteractionIDs.contains(approvalID),
        let decision = approval.decisions.first(where: { $0.id == decisionID }) else {
            store.setConnectionState(
                store.state.connectionState,
                message: ConversationCoordinatorError.interactionUnavailable.localizedDescription
            )
            return
        }

        if decision.isDestructive {
            let confirmation = DestructiveApprovalConfirmation(
                approvalID: approvalID,
                decisionID: decisionID
            )
            if store.pendingDestructiveApprovalConfirmation != confirmation {
                store.requestDestructiveApprovalConfirmation(
                    approvalID: approvalID,
                    decisionID: decisionID
                )
                return
            }
        }
        store.clearDestructiveApprovalConfirmation()
        store.setInteractionResponding(approvalID, isResponding: true)
        let requestID = UUID().uuidString.lowercased()
        pendingInteractionByCommand[requestID] = approvalID

        do {
            let command = ChatCommand.respondToApproval(
                providerConnectionGeneration: approval.providerConnectionGeneration,
                providerRequestID: approval.providerRequestID,
                decision: decisionID,
                permissionChanges: permissionChanges
            )
            try await transport.send(
                command.envelope(identity: identity, requestID: requestID)
            )
        } catch {
            pendingInteractionByCommand.removeValue(forKey: requestID)
            store.setInteractionResponding(approvalID, isResponding: false)
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
        }
    }

    func answer(
        questionID: String,
        answers: [ChatQuestionAnswer],
        secretText: String? = nil
    ) async {
        guard let question = store.state.questions.first(where: {
            $0.id == questionID && $0.status == .pending
        }), !store.respondingInteractionIDs.contains(questionID) else {
            store.setConnectionState(
                store.state.connectionState,
                message: ConversationCoordinatorError.interactionUnavailable.localizedDescription
            )
            return
        }

        var outboundAnswers = answers
        if question.kind == .secret, let secretText {
            outboundAnswers = [
                ChatQuestionAnswer(questionID: questionID, text: secretText),
            ]
        }

        store.setInteractionResponding(questionID, isResponding: true)
        let requestID = UUID().uuidString.lowercased()
        pendingInteractionByCommand[requestID] = questionID
        do {
            let command = ChatCommand.answerQuestion(
                providerConnectionGeneration: question.providerConnectionGeneration,
                providerRequestID: question.providerRequestID,
                answers: outboundAnswers
            )
            try await transport.send(
                command.envelope(identity: identity, requestID: requestID)
            )
            store.clearQuestionDraft(questionID: questionID)
        } catch {
            pendingInteractionByCommand.removeValue(forKey: requestID)
            store.setInteractionResponding(questionID, isResponding: false)
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
        }
    }

    func loadOlderHistory() async {
        guard store.state.hasOlderHistory, !store.isLoadingOlderHistory else { return }
        store.beginLoadingOlderHistory()
        do {
            try await sendCommand(
                .loadHistory(beforeItemID: store.state.oldestItemID, limit: 50)
            )
        } catch {
            store.endLoadingOlderHistory()
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
        }
    }

    func previewFile(_ link: ChatRepositoryLink) async {
        do {
            try await sendCommand(.previewFile(link))
        } catch {
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
        }
    }

    func stop() async {
        guard !isStopping,
              lifecycleTransition == nil,
              store.state.connectionState != .stopped else { return }
        cancelPreviewHydration()
        lifecycleTransition = .stopping
        isStopping = true
        var didCompleteStop = false
        defer {
            isStopping = false
            if lifecycleTransition == .stopping {
                lifecycleTransition = nil
            }
            let shouldReplayDetach = detachRequestedAfterStop
                && !didCompleteStop
            detachRequestedAfterStop = false
            if shouldReplayDetach {
                Task { [weak self] in
                    await self?.detach()
                }
            }
        }
        let requestID = stopEnvelope?.requestID ?? UUID().uuidString.lowercased()
        stopRequestID = requestID
        stopWasConfirmed = false
        do {
            let envelope: ChatEnvelope
            if let stopEnvelope {
                envelope = stopEnvelope
            } else {
                envelope = try ChatCommand.stop.envelope(
                    identity: identity,
                    requestID: requestID
                )
            }
            stopEnvelope = envelope
            try await transport.send(envelope)
            for _ in 0..<stopPolicy.confirmationPollCount where !stopWasConfirmed {
                if stopPolicy.pollDelayNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: stopPolicy.pollDelayNanoseconds)
                } else {
                    await Task.yield()
                }
            }
            if !stopWasConfirmed {
                store.setConnectionState(
                    .offlineAgentRunning,
                    message: "Stop was sent, but the worker did not confirm it. Retry before trying again."
                )
                return
            }
        } catch {
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
            return
        }
        shouldStayConnected = false
        lifecycleEpoch &+= 1
        let epoch = lifecycleEpoch
        let previousRetryTask = retryTask
        previousRetryTask?.cancel()
        retryTask = nil
        let previousLifecycleTask = lifecycleTask
        previousLifecycleTask?.cancel()
        lifecycleTask = nil
        retrySleepTask?.cancel()
        retrySleepTask = nil
        retrySleepToken = nil
        isAttached = false
        await transport.disconnect()
        _ = await previousRetryTask?.value
        _ = await previousLifecycleTask?.value
        guard lifecycleEpoch == epoch, lifecycleTransition == .stopping else {
            lifecycleTransition = nil
            return
        }
        store.setConnectionState(.stopped)
        didCompleteStop = true
        stopRequestID = nil
    }

    private func runConnectionLoop(lifecycleEpoch epoch: UInt64) async {
        var retryCount = 0
        defer {
            if lifecycleEpoch == epoch {
                lifecycleTask = nil
            }
        }

        while canContinueLifecycle(epoch) {
            let stream = await transport.events()
            guard canContinueLifecycle(epoch) else { return }
            do {
                try await transport.connect()
                guard canContinueLifecycle(epoch) else { return }
                let attach = ChatCommand.attach(
                    afterSequence: needsFreshSnapshot ? nil : store.lastAppliedSequence,
                    snapshotGeneration: needsFreshSnapshot ? nil : store.snapshotGeneration
                )
                try await sendCommand(attach)
                guard canContinueLifecycle(epoch) else { return }
                isAttached = true
                needsFreshSnapshot = false
                startConnectingWatchdog(lifecycleEpoch: epoch)

                eventLoop: for await event in stream {
                    guard canContinueLifecycle(epoch) else { break eventLoop }
                    switch event {
                    case .envelope(let envelope):
                        // Only received traffic refreshes the retry budget.
                        // A sent attach merely reached a local pipe; if it
                        // reset the budget, a transport that spawns but never
                        // delivers would be reconnected forever.
                        retryCount = 0
                        hasReceivedEnvelopeSinceAttach = true
                        if await apply(envelope, lifecycleEpoch: epoch) {
                            break eventLoop
                        }
                    case .disconnected(let failure):
                        isAttached = false
                        resetReconnectScopedState()
                        if let failure, !failure.isRecoverable {
                            shouldStayConnected = false
                            store.setConnectionState(.failed, message: failure.message)
                        } else {
                            store.setConnectionState(.connecting)
                        }
                        break eventLoop
                    }
                }
                connectingWatchdogTask?.cancel()
                connectingWatchdogTask = nil
            } catch {
                connectingWatchdogTask?.cancel()
                connectingWatchdogTask = nil
                guard canContinueLifecycle(epoch) else { return }
                isAttached = false
                resetReconnectScopedState()
                await transport.disconnect()
                guard canContinueLifecycle(epoch) else { return }
                store.setConnectionState(.connecting)
            }

            guard canContinueLifecycle(epoch) else { return }
            retryCount += 1
            guard retryCount <= retryPolicy.maximumAutomaticRetries else {
                store.setConnectionState(
                    .offlineAgentRunning,
                    message: "Lost the connection to this conversation. Tap Retry to reconnect."
                )
                shouldStayConnected = false
                return
            }
            let multiplier = UInt64(1 << min(retryCount - 1, 10))
            let delay = min(
                retryPolicy.initialDelayNanoseconds * multiplier,
                retryPolicy.maximumDelayNanoseconds
            )
            if delay > 0 {
                // A cancellable child so opening the conversation can cut the
                // backoff short without tearing down the connection loop.
                let sleeper = Task { _ = try? await Task.sleep(nanoseconds: delay) }
                let token = UUID()
                retrySleepTask = sleeper
                retrySleepToken = token
                await sleeper.value
                if retrySleepToken == token {
                    retrySleepTask = nil
                    retrySleepToken = nil
                }
            }
            if canContinueLifecycle(epoch) {
                store.setConnectionState(.connecting)
            }
        }
    }

    private func startConnectingWatchdog(lifecycleEpoch epoch: UInt64) {
        connectingWatchdogTask?.cancel()
        connectingWatchdogTask = nil
        hasReceivedEnvelopeSinceAttach = false
        let grace = retryPolicy.connectingGraceNanoseconds
        guard grace > 0 else { return }
        // A zero response grace disables phase one: the watchdog then only
        // fires the terminal check at the full connecting grace.
        let responseGrace = retryPolicy.attachResponseGraceNanoseconds > 0
            ? min(retryPolicy.attachResponseGraceNanoseconds, grace)
            : grace
        attachGeneration &+= 1
        let generation = attachGeneration
        connectingWatchdogTask = Task { [weak self] in
            if responseGrace > 0 {
                guard (try? await Task.sleep(nanoseconds: responseGrace)) != nil
                else { return }
            }
            guard let self else { return }
            if responseGrace < grace {
                guard await self.shouldKeepWaitingForConnecting(
                    lifecycleEpoch: epoch,
                    attachGeneration: generation
                ) else { return }
                guard (try? await Task.sleep(
                    nanoseconds: grace - responseGrace
                )) != nil else { return }
            }
            await self.handleConnectingWatchdogExpiry(
                lifecycleEpoch: epoch,
                attachGeneration: generation
            )
        }
    }

    /// Phase one of the attach watchdog. Returns whether a still-"connecting"
    /// attach has earned the long grace: envelopes are arriving, so the
    /// transport works and the broker is genuinely mid-resume. When nothing at
    /// all has come back, the transport is torn down instead — the event loop
    /// then reconnects through the normal retry path, because a sent attach
    /// only proves the bytes reached a local pipe, and a fresh connection
    /// almost always succeeds immediately.
    private func shouldKeepWaitingForConnecting(
        lifecycleEpoch epoch: UInt64,
        attachGeneration generation: UInt64
    ) async -> Bool {
        guard canContinueLifecycle(epoch),
              attachGeneration == generation,
              isAttached,
              store.workingConnectionState == .connecting else {
            return false
        }
        guard !hasReceivedEnvelopeSinceAttach else { return true }
        isAttached = false
        connectingWatchdogTask = nil
        // Commands sent into the doomed pipe died with it: clear interaction
        // and history latches exactly like every other reconnect path, or a
        // tap during the dead window leaves its control disabled forever.
        resetReconnectScopedState()
        await transport.disconnect()
        return false
    }

    private func handleConnectingWatchdogExpiry(
        lifecycleEpoch epoch: UInt64,
        attachGeneration generation: UInt64
    ) async {
        guard canContinueLifecycle(epoch),
              attachGeneration == generation,
              isAttached,
              store.workingConnectionState == .connecting else {
            return
        }
        shouldStayConnected = false
        isAttached = false
        connectingWatchdogTask = nil
        store.setConnectionState(
            .failed,
            message: "The worker didn't finish loading this conversation. "
                + "Tap Retry, or open the thread again from the sidebar."
        )
        await transport.disconnect()
    }

    private func apply(
        _ envelope: ChatEnvelope,
        lifecycleEpoch epoch: UInt64
    ) async -> Bool {
        guard canContinueLifecycle(epoch) else { return true }
        let kind = ChatEventKind(rawValue: envelope.type)
        let projectionPreparation: Task<PreparedConversationApplication, Never>?
        let requiresProjectionPreparation: Bool
        switch kind {
        case .conversationSnapshot, .historyPage,
             .messageStarted, .messageDelta, .messageCompleted,
             .reasoningStarted, .reasoningDelta, .reasoningCompleted,
             .toolStarted, .toolUpdated, .toolCompleted,
             .fileChangeUpdated, .diffUpdated, .planUpdated,
             .turnCompleted, .turnFailed, .turnInterrupted:
            requiresProjectionPreparation = true
        default:
            requiresProjectionPreparation = false
        }
        if requiresProjectionPreparation {
            let currentState: ConversationState?
            switch kind {
            case .conversationSnapshot, .historyPage,
                 .turnCompleted, .turnFailed, .turnInterrupted:
                currentState = store.stateForTranscriptProjectionPreparation
            default:
                currentState = nil
            }
            let currentItem = store.transcriptProjectionPreparationItem(
                for: envelope
            )
            let stagedProjection = store.stagedTranscriptProjection(
                for: envelope
            )
            projectionPreparation = Task {
                let reducerPayload = await ConversationStore
                    .prepareAuthoritativeReducerPayload(
                        for: envelope,
                        retaining: currentItem
                    )
                let preservedSnapshotItemIDs = await ConversationStore
                    .preparePreservedSnapshotItemIDs(
                        for: reducerPayload,
                        retaining: currentState?.items ?? [],
                        currentState: currentState
                    )
                async let projections = ConversationStore.prepareTranscriptProjections(
                    for: envelope,
                    retaining: currentState?.items ?? [],
                    currentState: currentState,
                    currentItem: currentItem,
                    stagedProjection: stagedProjection,
                    preparedReducerPayload: reducerPayload,
                    preservingSnapshotItemIDs: preservedSnapshotItemIDs
                )
                async let markdownWarmTexts = ConversationStore
                    .prepareMarkdownWarmTexts(for: reducerPayload)
                let preparedProjections = await projections
                let warmTexts = await markdownWarmTexts
                return PreparedConversationApplication(
                    transcriptProjections: preparedProjections,
                    reducerPayload: reducerPayload,
                    markdownWarmTexts: warmTexts,
                    preservedSnapshotItemIDs: preservedSnapshotItemIDs
                )
            }
        } else {
            projectionPreparation = nil
        }
        defer { projectionPreparation?.cancel() }
        do {
            let existingItemIDs = envelope.type == ChatEventKind.historyPage.rawValue
                ? Set(store.state.items.map(\.id))
                : []
            let preparedApplication = await projectionPreparation?.value
            await warmMarkdownCacheIfNeeded(
                texts: preparedApplication?.markdownWarmTexts ?? []
            )
            guard canContinueLifecycle(epoch) else { return true }
            let preservesPaintedTranscript = preparedApplication?.reducerPayload?
                .preservesPaintedTranscript(
                    previousItemCount: store
                        .itemsForTranscriptProjectionPreparation.count
                ) == true
            try store.apply(
                envelope,
                preparedTranscriptProjections:
                    preparedApplication?.transcriptProjections ?? [:],
                preparedReducerPayload: preparedApplication?.reducerPayload,
                preservedSnapshotItemIDs:
                    preparedApplication?.preservedSnapshotItemIDs ?? []
            )
            scheduleMarkdownWarmAfterApply(
                envelope,
                existingItemIDs: existingItemIDs
            )
            if envelope.type == ChatEventKind.conversationSnapshot.rawValue {
                reconcileSnapshotTransients()
                if preservesPaintedTranscript {
                    suppressCachePersistenceUntilAuthoritativeSnapshot = true
                    cacheSaveTask?.cancel()
                    cacheSaveTask = nil
                } else {
                    suppressCachePersistenceUntilAuthoritativeSnapshot = false
                    scheduleCacheSave(immediate: true)
                }
            } else if envelope.type == ChatEventKind.turnStarted.rawValue {
                releasePendingTurnLatchPreservingRestoration()
                scheduleCacheSave()
            } else if envelope.sequence != nil {
                scheduleCacheSave()
            }
            if let pendingInterrupt,
               store.state.activeTurnID != pendingInterrupt.turnID {
                self.pendingInterrupt = nil
            }
            if envelope.type == ChatEventKind.acknowledgement.rawValue
                || envelope.type == ChatEventKind.error.rawValue {
                let requestID = envelope.requestID ?? envelope.payload["requestId"]?.stringValue
                if envelope.type == ChatEventKind.error.rawValue,
                   requestID == pendingInterrupt?.requestID {
                    pendingInterrupt = nil
                }
                resolvePendingTurn(
                    requestID,
                    isError: envelope.type == ChatEventKind.error.rawValue
                )
                resolvePendingCommand(
                    requestID,
                    isError: envelope.type == ChatEventKind.error.rawValue
                )
                if requestID == stopRequestID,
                   envelope.type == ChatEventKind.acknowledgement.rawValue {
                    stopWasConfirmed = true
                }
            }
            if envelope.type == ChatEventKind.sessionEnded.rawValue {
                stopWasConfirmed = true
            }
            if envelope.type == ChatEventKind.historyPage.rawValue {
                store.endLoadingOlderHistory()
            }
            if envelope.type == ChatEventKind.approvalResolved.rawValue
                || envelope.type == ChatEventKind.approvalExpired.rawValue,
               let id = envelope.itemID ?? envelope.payload["displayId"]?.stringValue {
                store.setInteractionResponding(id, isResponding: false)
                pendingInteractionByCommand = pendingInteractionByCommand.filter { $0.value != id }
            }
            if envelope.type == ChatEventKind.questionResolved.rawValue
                || envelope.type == ChatEventKind.questionExpired.rawValue,
               let id = envelope.itemID ?? envelope.payload["displayId"]?.stringValue {
                store.setInteractionResponding(id, isResponding: false)
                pendingInteractionByCommand = pendingInteractionByCommand.filter { $0.value != id }
            }
            return false
        } catch ConversationReducerError.sequenceGap,
                ConversationReducerError.snapshotGenerationChanged {
            needsFreshSnapshot = true
            resetReconnectScopedState()
            store.setConnectionState(.connecting)
            isAttached = false
            await transport.disconnect()
            return true
        } catch {
            store.setConnectionState(.failed, message: sanitizedMessage(for: error))
            shouldStayConnected = false
            return true
        }
    }

    /// Prepares the final Markdown artifacts for the restored viewport before
    /// it publishes. Older rows are warmed directionally by the table instead
    /// of scanning the complete retained transcript on the UI actor.
    private func warmMarkdownCacheIfNeeded(texts: [String]) async {
        guard !texts.isEmpty, !Task.isCancelled else { return }
        await SanitizedMarkdownCache.shared.warm(texts: texts)
    }

    private func canContinueLifecycle(_ expectedEpoch: UInt64?) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let expectedEpoch else { return true }
        return shouldStayConnected && lifecycleEpoch == expectedEpoch
    }

    private func warmRecentMarkdown(
        for items: [ConversationItem],
        budget: Duration = .milliseconds(150)
    ) async {
        let texts = await Task.detached(priority: .utility) {
            Array(
                SanitizedMarkdownCache.warmableTexts(
                    items: items,
                    suffixLimit: 50
                )
                    .reversed()
            )
        }.value
        guard !texts.isEmpty else { return }
        await SanitizedMarkdownCache.shared.warm(
            texts: texts,
            budget: budget
        )
    }

    /// Snapshot restoration gets a short synchronous warm above. These paths
    /// cover content that becomes immutable later: disk hydration, history
    /// pages, and live message completion. Newest tiles are prepared first
    /// because the transcript opens and normally scrolls upward from latest.
    private func scheduleMarkdownWarmAfterApply(
        _ envelope: ChatEnvelope,
        existingItemIDs: Set<String>
    ) {
        switch ChatEventKind(rawValue: envelope.type) {
        case .messageCompleted:
            let itemID = envelope.itemID
                ?? envelope.payload["itemId"]?.stringValue
                ?? envelope.payload["id"]?.stringValue
            guard let itemID,
                  let item = store.state.items.last(where: { $0.id == itemID }) else {
                return
            }
            scheduleMarkdownWarm(for: [item])

        case .historyPage:
            scheduleMarkdownWarm(
                for: store.state.items.filter { !existingItemIDs.contains($0.id) }
            )

        default:
            break
        }
    }

    private func scheduleMarkdownWarm(
        for items: [ConversationItem],
        priority: TaskPriority = .utility
    ) {
        Task.detached(priority: priority) {
            let texts = Array(
                SanitizedMarkdownCache.warmableTexts(
                    items: items,
                    suffixLimit: 50
                )
                    .reversed()
            )
            guard !texts.isEmpty, !Task.isCancelled else { return }
            await SanitizedMarkdownCache.shared.warm(
                texts: texts,
                budget: .seconds(30),
                priority: priority
            )
        }
    }

    private func sendCommand(_ command: ChatCommand) async throws {
        guard identity.isValid else {
            throw ConversationCoordinatorError.invalidIdentity
        }
        try await transport.send(command.envelope(identity: identity))
    }

    private func resolvePendingCommand(_ requestID: String?, isError: Bool) {
        guard let requestID,
              let interactionID = pendingInteractionByCommand[requestID] else {
            return
        }
        if isError {
            pendingInteractionByCommand.removeValue(forKey: requestID)
            store.setInteractionResponding(interactionID, isResponding: false)
        }
    }

    private func resolvePendingTurn(_ requestID: String?, isError: Bool) {
        guard let requestID else {
            return
        }
        let pending = pendingTurnByCommand.removeValue(forKey: requestID)
            ?? unconfirmedTurnByCommand.removeValue(forKey: requestID)
        guard let pending, isError else { return }
        store.removeOptimisticUserMessage(requestID: requestID)
        store.restoreFailedSubmission(
            text: pending.text,
            attachments: pending.attachments
        )
    }

    private func resetReconnectScopedState() {
        releasePendingTurnLatchPreservingRestoration()
        pendingInteractionByCommand.removeAll()
        pendingInterrupt = nil
        store.resetReconnectTransients()
    }

    private func reconcileSnapshotTransients() {
        pendingInteractionByCommand.removeAll()
        pendingInterrupt = nil
        if store.state.turnState.isActive {
            releasePendingTurnLatchPreservingRestoration()
        }
    }

    private func releasePendingTurnLatchPreservingRestoration() {
        unconfirmedTurnByCommand.merge(pendingTurnByCommand) { current, _ in
            current
        }
        pendingTurnByCommand.removeAll()
    }

    private func validatePrompt(
        _ text: String,
        attachments: [ChatAttachmentReference]
    ) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !attachments.isEmpty else {
            throw ConversationCoordinatorError.emptyPrompt
        }
        guard text.utf8.count <= 256 * 1_024 else {
            throw ConversationCoordinatorError.promptTooLarge
        }
        guard attachments.count <= ChatAttachmentPolicy.maximumCount else {
            throw ConversationCoordinatorError.tooManyAttachments
        }
        var attachmentBytes = 0
        for attachment in attachments {
            let byteCount = attachment.byteCount ?? 0
            guard byteCount >= 0,
                  byteCount <= ChatAttachmentPolicy.maximumFileBytes,
                  attachmentBytes <= ChatAttachmentPolicy.maximumTurnBytes - byteCount else {
                throw ConversationCoordinatorError.attachmentsTooLarge
            }
            attachmentBytes += byteCount
        }
        guard attachments.allSatisfy({ $0.path.utf8.count <= 4_096 }) else {
            throw ConversationCoordinatorError.attachmentPathTooLarge
        }
    }

    private func sanitizedMessage(for error: Error) -> String {
        if let error = error as? LocalizedError, let message = error.errorDescription {
            return message
        }
        return "The chat connection could not complete that action."
    }
}
