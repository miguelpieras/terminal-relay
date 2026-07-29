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
        case .noActiveTurn:
            "There is no active turn to stop."
        case .interactionUnavailable:
            "This request is no longer available."
        }
    }
}

@MainActor
final class ConversationCoordinator {
    let store: ConversationStore
    let identity: ChatConversationIdentity

    private let transport: any ChatTransport
    private var launchOptions: ChatLaunchOptions
    private let retryPolicy: ChatRetryPolicy
    private let stopPolicy: ChatStopPolicy
    private var lifecycleTask: Task<Void, Never>?
    private var shouldStayConnected = false
    private var isAttached = false
    private var needsFreshSnapshot = false
    private var pendingInteractionByCommand: [String: String] = [:]
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
        stopPolicy: ChatStopPolicy = .standard
    ) {
        self.store = store ?? ConversationStore()
        self.transport = transport
        self.identity = identity
        self.launchOptions = launchOptions
        self.retryPolicy = retryPolicy
        self.stopPolicy = stopPolicy
    }

    deinit {
        lifecycleTask?.cancel()
    }

    func start() {
        guard lifecycleTask == nil else { return }
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
            await self?.runConnectionLoop()
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
        lifecycleTask?.cancel()
        lifecycleTask = nil
        if isAttached {
            try? await sendCommand(.detach)
        }
        isAttached = false
        await transport.disconnect()
        store.setConnectionState(.offlineAgentRunning)
    }

    func retry() {
        shouldStayConnected = false
        lifecycleTask?.cancel()
        lifecycleTask = nil
        Task { [weak self] in
            guard let self else { return }
            await transport.disconnect()
            shouldStayConnected = true
            store.setConnectionState(.connecting)
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
            let requestID = UUID().uuidString.lowercased()
            let envelope = try ChatCommand.startTurn(
                text: text,
                attachments: attachments,
                options: launchOptions
            ).envelope(identity: identity, requestID: requestID)

            store.clearComposer()
            store.addOptimisticUserMessage(requestID: requestID, text: text)
            do {
                try await transport.send(envelope)
            } catch {
                store.removeOptimisticUserMessage(requestID: requestID)
                if store.draft.isEmpty {
                    store.draft = text
                    store.attachments = attachments
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
        do {
            try await sendCommand(.interrupt(turnID: turnID))
        } catch {
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
                    message: "Stop was sent, but the worker did not confirm it. Reconnect before trying again."
                )
                return
            }
        } catch {
            store.setConnectionState(store.state.connectionState, message: sanitizedMessage(for: error))
            return
        }
        shouldStayConnected = false
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
                        if let failure, !failure.isRecoverable {
                            shouldStayConnected = false
                            store.setConnectionState(.failed, message: failure.message)
                        } else {
                            store.setConnectionState(.offlineAgentRunning, message: failure?.message)
                        }
                        break eventLoop
                    }
                }
            } catch {
                isAttached = false
                store.setConnectionState(.offlineAgentRunning, message: sanitizedMessage(for: error))
            }

            guard shouldStayConnected, !Task.isCancelled else { return }
            retryCount += 1
            guard retryCount <= retryPolicy.maximumAutomaticRetries else {
                store.setConnectionState(
                    .offlineAgentRunning,
                    message: "The agent is still running. Tap Reconnect to try again."
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
                try? await Task.sleep(nanoseconds: delay)
            }
            if shouldStayConnected {
                store.setConnectionState(.connecting)
            }
        }
    }

    private func apply(_ envelope: ChatEnvelope) async -> Bool {
        do {
            try store.apply(envelope)
            if envelope.type == ChatEventKind.acknowledgement.rawValue
                || envelope.type == ChatEventKind.error.rawValue {
                let requestID = envelope.requestID ?? envelope.payload["requestId"]?.stringValue
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
