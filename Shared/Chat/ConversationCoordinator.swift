import Foundation

struct ChatRetryPolicy: Equatable, Sendable {
    let maximumAutomaticRetries: Int
    let initialDelayNanoseconds: UInt64
    let maximumDelayNanoseconds: UInt64

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
    private let cache: ConversationStateCache?
    private var didAttemptHydration = false
    private var cacheSaveTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retrySleepTask: Task<Void, Never>?
    private var shouldStayConnected = false
    private var isAttached = false
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
        cache: ConversationStateCache? = nil
    ) {
        self.store = store ?? ConversationStore()
        self.transport = transport
        self.identity = identity
        self.launchOptions = launchOptions
        self.retryPolicy = retryPolicy
        self.stopPolicy = stopPolicy
        self.cache = cache
    }

    deinit {
        lifecycleTask?.cancel()
        retryTask?.cancel()
        retrySleepTask?.cancel()
        cacheSaveTask?.cancel()
    }

    func start() {
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
        lifecycleTask = Task { [weak self] in
            await self?.hydrateFromCacheIfNeeded()
            await self?.runConnectionLoop()
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
        Task { [weak self] in
            await self?.hydrateFromCacheIfNeeded()
        }
    }

    /// Paints the transcript from the on-disk cache before the first connect,
    /// so opening a known thread shows content immediately. The subsequent
    /// attach resumes from the cached cursor and reconciles with the worker.
    private func hydrateFromCacheIfNeeded() async {
        guard !didAttemptHydration else { return }
        didAttemptHydration = true
        guard let cache, store.lastAppliedSequence == 0 else { return }
        if let cached = await cache.load(for: identity) {
            store.hydrateFromCache(cached)
        }
    }

    /// Persists the current state after live updates, debounced so streaming
    /// deltas coalesce into one write when the stream quiets.
    private func scheduleCacheSave(immediate: Bool = false) {
        guard cache != nil else { return }
        cacheSaveTask?.cancel()
        cacheSaveTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            guard !Task.isCancelled, let self, let cache = self.cache else {
                return
            }
            await cache.save(self.store.state, for: self.identity)
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
        shouldStayConnected = false
        retryTask?.cancel()
        retryTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        resetReconnectScopedState()
        if isAttached {
            try? await sendCommand(.detach)
        }
        isAttached = false
        await transport.disconnect()
        store.setConnectionState(.offlineAgentRunning)
        cacheSaveTask?.cancel()
        if let cache {
            await cache.save(store.state, for: identity)
        }
    }

    func retry() {
        guard retryTask == nil else { return }
        shouldStayConnected = false
        let previousLifecycleTask = lifecycleTask
        previousLifecycleTask?.cancel()
        lifecycleTask = nil
        resetReconnectScopedState()
        store.setConnectionState(.connecting)
        retryTask = Task { [weak self] in
            guard let self else { return }
            _ = await previousLifecycleTask?.value
            await transport.disconnect()
            guard !Task.isCancelled else {
                retryTask = nil
                return
            }
            shouldStayConnected = true
            retryTask = nil
            start()
        }
    }

    func sendDraft() async {
        let text = store.draft
        let attachments = store.attachments
        await send(text: text, attachments: attachments)
    }

    func send(text: String, attachments: [ChatAttachmentReference] = []) async {
        do {
            try validatePrompt(text, attachments: attachments)
            guard !store.state.turnState.isActive, pendingTurnByCommand.isEmpty else {
                throw ConversationCoordinatorError.turnAlreadyActive
            }
            let requestID = UUID().uuidString.lowercased()
            let envelope = try ChatCommand.startTurn(
                text: text,
                attachments: attachments,
                options: launchOptions
            ).envelope(identity: identity, requestID: requestID)

            store.clearComposer()
            store.addOptimisticUserMessage(requestID: requestID, text: text)
            pendingTurnByCommand[requestID] = PendingTurn(
                text: text,
                attachments: attachments
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
        } catch {
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
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
        guard !isStopping, store.state.connectionState != .stopped else { return }
        isStopping = true
        defer { isStopping = false }
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
        retryTask?.cancel()
        retryTask = nil
        lifecycleTask?.cancel()
        lifecycleTask = nil
        isAttached = false
        await transport.disconnect()
        store.setConnectionState(.stopped)
        stopRequestID = nil
    }

    private func runConnectionLoop() async {
        var retryCount = 0
        defer {
            lifecycleTask = nil
        }

        while shouldStayConnected, !Task.isCancelled {
            let stream = await transport.events()
            do {
                try await transport.connect()
                let attach = ChatCommand.attach(
                    afterSequence: needsFreshSnapshot ? nil : store.lastAppliedSequence,
                    snapshotGeneration: needsFreshSnapshot ? nil : store.snapshotGeneration
                )
                try await sendCommand(attach)
                isAttached = true
                needsFreshSnapshot = false
                retryCount = 0

                eventLoop: for await event in stream {
                    guard shouldStayConnected, !Task.isCancelled else { break eventLoop }
                    switch event {
                    case .envelope(let envelope):
                        if await apply(envelope) {
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
            } catch {
                isAttached = false
                resetReconnectScopedState()
                await transport.disconnect()
                store.setConnectionState(.connecting)
            }

            guard shouldStayConnected, !Task.isCancelled else { return }
            retryCount += 1
            guard retryCount <= retryPolicy.maximumAutomaticRetries else {
                store.setConnectionState(
                    .offlineAgentRunning,
                    message: "The agent is still running. Tap Retry to reconnect."
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
                retrySleepTask = sleeper
                await sleeper.value
                retrySleepTask = nil
            }
            if shouldStayConnected {
                store.setConnectionState(.connecting)
            }
        }
    }

    private func apply(_ envelope: ChatEnvelope) async -> Bool {
        do {
            await warmMarkdownCacheIfNeeded(for: envelope)
            try store.apply(envelope)
            if envelope.type == ChatEventKind.conversationSnapshot.rawValue {
                reconcileSnapshotTransients()
                scheduleCacheSave(immediate: true)
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

    /// Sanitizes the markdown of a restored conversation's most recent items
    /// before they publish, so their rows can parse synchronously and land at
    /// their final height on the first layout frame. Older history keeps
    /// warming in the background for stable scroll-up.
    private func warmMarkdownCacheIfNeeded(for envelope: ChatEnvelope) async {
        guard envelope.type == ChatEventKind.conversationSnapshot.rawValue,
              let snapshot = try? envelope.decodePayload(ConversationSnapshot.self),
              !snapshot.items.isEmpty else {
            return
        }
        let texts = SanitizedMarkdownCache.warmableTexts(items: snapshot.items)
        let recent = Array(texts.suffix(50))
        await SanitizedMarkdownCache.shared.warm(texts: recent)
        let older = texts.dropLast(50)
        if !older.isEmpty {
            Task(priority: .utility) { @MainActor in
                await SanitizedMarkdownCache.shared.warm(
                    texts: Array(older),
                    budget: .seconds(30)
                )
            }
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConversationCoordinatorError.emptyPrompt
        }
        guard text.utf8.count <= 256 * 1_024 else {
            throw ConversationCoordinatorError.promptTooLarge
        }
        guard attachments.count <= 32 else {
            throw ConversationCoordinatorError.tooManyAttachments
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
