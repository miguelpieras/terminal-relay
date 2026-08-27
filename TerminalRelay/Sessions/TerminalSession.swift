import AppKit
import Combine
import Darwin
import OSLog
import SwiftTerm

private let terminalSessionLogger = Logger(
    subsystem: "com.mpieras.TerminalRelay",
    category: "terminal-session"
)

enum TerminalSessionStatus: Equatable {
    case connecting
    case running
    case remoteRunning
    case disconnected(Int32?)
    case stopping
    case exited(Int32?)

    var occupiesSlot: Bool {
        switch self {
        case .connecting, .running, .remoteRunning, .disconnected, .stopping: true
        case .exited: false
        }
    }

    var isLocallyAttached: Bool {
        switch self {
        case .connecting, .running: true
        case .remoteRunning, .disconnected, .stopping, .exited: false
        }
    }

    var canReconnect: Bool {
        switch self {
        case .remoteRunning, .disconnected: true
        case .connecting, .running, .stopping, .exited: false
        }
    }

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .running: "Connected"
        case .remoteRunning: "Running remotely"
        case .disconnected(let code):
            if let code { "Disconnected (\(code))" } else { "Disconnected" }
        case .stopping: "Stopping"
        case .exited(let code):
            if let code { "Exited (\(code))" } else { "Exited" }
        }
    }
}

enum TerminalSessionLaunchState: Equatable {
    case ready
    case starting
    case failed(String)
}

private struct CodexTerminalTitle {
    private static let runStates = Set(["Ready", "Working", "Thinking", "Waiting", "Starting"])

    let title: String?
    let isWorking: Bool

    init(_ rawTitle: String) {
        let normalizedTitle = normalizedTerminalTitle(rawTitle)
        let parts = normalizedTitle.components(separatedBy: " | ")

        guard let runState = parts.last, Self.runStates.contains(runState) else {
            title = displayableTerminalTitle(normalizedTitle)
            isWorking = false
            return
        }

        let displayTitle = parts.dropLast().joined(separator: " | ")
        title = displayableTerminalTitle(displayTitle)
        isWorking = runState != "Ready"
    }
}

private func normalizedTerminalTitle(_ title: String) -> String {
    title
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}

private func displayableTerminalTitle(_ title: String) -> String? {
    let normalizedTitle = normalizedTerminalTitle(title)
    guard !normalizedTitle.isEmpty, UUID(uuidString: normalizedTitle) == nil else { return nil }
    return normalizedTitle
}

private func displayableClaudeTerminalTitle(_ title: String) -> String? {
    var normalizedTitle = normalizedTerminalTitle(title)
    let activityGlyphs = Set("*✢✣✤✥✦✧✳✶✻✽")

    while let first = normalizedTitle.first, activityGlyphs.contains(first) {
        normalizedTitle.removeFirst()
        normalizedTitle = normalizedTitle.trimmingCharacters(in: .whitespaces)
    }
    return displayableTerminalTitle(normalizedTitle)
}

private func progressReport(fromOSC9Payload payload: ArraySlice<UInt8>) -> Terminal.ProgressReport? {
    guard let text = String(bytes: payload, encoding: .ascii) else { return nil }

    let parts = text.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.count >= 2,
          parts[0] == "4",
          parts[1].count == 1,
          let rawState = Int(parts[1]),
          let state = Terminal.ProgressReportState(rawValue: rawState) else {
        return nil
    }

    var progress: UInt8?
    if parts.count >= 3, !parts[2].isEmpty {
        guard let rawProgress = Int(parts[2]) else { return nil }
        progress = UInt8(max(0, min(rawProgress, 100)))
    } else if state == .set {
        progress = 0
    }

    if state == .remove {
        progress = nil
    }
    return Terminal.ProgressReport(state: state, progress: progress)
}

@MainActor
final class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let terminalViewIdentity: UUID
    let projectID: UUID
    let projectName: String
    let workingDirectory: String
    let serverKey: String
    let serverName: String
    let kind: AgentKind
    let accountID: ProviderAccountID?
    let accountLabel: String
    let sequenceNumber: Int
    let startedAt: Date
    let instanceToken: String
    let presentation: WorkerSessionPresentation
    let terminalView: LocalProcessTerminalView
    let chatCoordinator: ConversationCoordinator?

    @Published private(set) var status: TerminalSessionStatus
    @Published private(set) var terminalTitle: String?
    @Published private(set) var threadID: String?
    @Published private(set) var isWorking = false
    @Published private(set) var lastActivityAt: Date
    /// True while lastActivityAt holds a row-creation fallback rather than
    /// observed activity. The first real worker-reported epoch replaces a
    /// fallback even when older; without this, a row materialized with an
    /// unknown activity time is pinned at "now" forever and sorts above
    /// genuinely recent conversations.
    private(set) var lastActivityIsFallback: Bool
    @Published private(set) var taskCompletionCount = 0
    @Published private(set) var remoteAttachedClientCount: Int?
    @Published private(set) var launchState: TerminalSessionLaunchState

    private let configuration: SSHLaunchConfiguration
    private var hasStarted = false
    private var hasFinished = false
    private var processExitSource: DispatchSourceProcess?
    private var titleIndicatesWorking = false
    private var progressIndicatesWorking = false
    private var remoteIndicatesWorking = false
    private var lastLocalExitCode: Int32?
    private var statusBeforeStopping: TerminalSessionStatus?
    private var remoteStopRequested = false
    private var explicitDisconnectRequested = false
    private var chatIndicatesWorking = false
    private var chatStateObserver: AnyCancellable?

    init(
        project: ProjectProfile,
        server: ServerProfile,
        kind: AgentKind,
        account: ProviderAccountProfile? = nil,
        accountID: ProviderAccountID? = nil,
        accountLabel: String? = nil,
        sequenceNumber: Int,
        instanceToken: String,
        id: UUID = UUID(),
        terminalViewIdentity: UUID = UUID(),
        startedAt: Date = Date(),
        lastActivityAt: Date? = nil,
        lastActivityIsFallback: Bool? = nil,
        initialStatus: TerminalSessionStatus = .connecting,
        terminalTitle: String? = nil,
        threadID: String? = nil,
        remoteAttachedClientCount: Int? = nil,
        presentation: WorkerSessionPresentation = .terminal,
        launchState: TerminalSessionLaunchState = .ready,
        launchDefaults: AgentLaunchDefaults = .standard,
        initialChatState: ConversationState? = nil,
        chatTransport: (any ChatTransport)? = nil,
        chatRetryPolicy: ChatRetryPolicy = .standard
    ) {
        self.id = id
        self.terminalViewIdentity = terminalViewIdentity
        self.projectID = project.id
        self.projectName = project.displayName
        self.workingDirectory = project.workingDirectory
        self.serverKey = server.concurrencyKey
        self.serverName = server.displayName
        self.kind = kind
        self.accountID = account?.accountID ?? accountID
        self.accountLabel = account?.displayName
            ?? accountLabel
            ?? server.accountLabel(for: kind)
        self.sequenceNumber = sequenceNumber
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.lastActivityIsFallback = lastActivityIsFallback ?? (lastActivityAt == nil)
        self.instanceToken = instanceToken
        self.presentation = presentation
        self.status = initialStatus
        self.launchState = launchState
        self.terminalTitle = nil
        let resolvedThreadID = threadID
            ?? (kind == .claude && launchState == .ready ? instanceToken : nil)
        self.threadID = resolvedThreadID
        self.remoteAttachedClientCount = remoteAttachedClientCount
        switch presentation {
        case .terminal:
            self.configuration = SSHCommandBuilder.configuration(
                for: server,
                project: project,
                kind: kind,
                accountID: account?.accountID ?? accountID,
                instanceToken: instanceToken
            )
            self.chatCoordinator = nil
        case .chat:
            let transport = chatTransport ?? MacChatTransport(
                configuration: SSHCommandBuilder.workerChatAttachConfiguration(
                    for: server,
                    kind: kind,
                    accountID: account?.accountID ?? accountID,
                    repositoryName: project.displayName,
                    instanceToken: instanceToken
                )
            )
            self.configuration = SSHCommandBuilder.workerChatAttachConfiguration(
                for: server,
                kind: kind,
                accountID: account?.accountID ?? accountID,
                repositoryName: project.displayName,
                instanceToken: instanceToken
            )
            // A carried state (the launch-pending preview's hydrated store)
            // keeps the transcript painted across the pending→confirmed
            // session swap instead of flashing back to a loading pane and
            // re-reading the cache from disk.
            self.chatCoordinator = ConversationCoordinator(
                store: initialChatState.map { ConversationStore(state: $0) },
                transport: transport,
                identity: ChatConversationIdentity(
                    relayID: instanceToken,
                    provider: ChatProvider(rawValue: kind.rawValue),
                    accountID: account?.accountID ?? accountID,
                    providerThreadID: resolvedThreadID
                ),
                launchOptions: launchDefaults.chatOptions(for: kind),
                retryPolicy: chatRetryPolicy
            )
        }
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()

        terminalView.processDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.078, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.92, alpha: 1)
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true

        if let terminalTitle {
            applyTerminalTitle(terminalTitle)
            // Applying the initial title is materialization, not activity;
            // undo its timestamp bump and restore the fallback marker.
            self.lastActivityAt = lastActivityAt ?? startedAt
            self.lastActivityIsFallback =
                lastActivityIsFallback ?? (lastActivityAt == nil)
        }

        if let chatCoordinator {
            chatStateObserver = chatCoordinator.store.$state
                .sink { [weak self] state in
                    self?.applyChatState(state)
                }
        }

        terminalView.getTerminal().registerOscHandler(code: 9) { [weak self, weak terminalView] payload in
            guard let report = progressReport(fromOSC9Payload: payload) else { return }

            if let terminalView {
                terminalView.progressReport(source: terminalView.getTerminal(), report: report)
            }

            let indicatesWorking: Bool
            switch report.state {
            case .set, .indeterminate:
                indicatesWorking = true
            case .remove, .error, .pause:
                indicatesWorking = false
            }

            Task { @MainActor [weak self] in
                self?.setProgressIndicatesWorking(indicatesWorking)
            }
        }
    }

    var title: String {
        "\(projectName) · \(kind.displayName)"
    }

    var usesNativeChat: Bool {
        presentation == .chat && chatCoordinator != nil
    }

    var workspaceViewIdentity: AnyHashable {
        usesNativeChat
            ? AnyHashable(ObjectIdentifier(self))
            : AnyHashable(terminalViewIdentity)
    }

    var isLaunchPending: Bool {
        launchState == .starting
    }

    var isLoadingExistingConversation: Bool {
        isLaunchPending && threadID != nil
    }

    var launchFailureMessage: String? {
        guard case .failed(let message) = launchState else { return nil }
        return message
    }

    var displayTitle: String {
        guard let terminalTitle else {
            return "\(kind.displayName) \(sequenceNumber)"
        }

        let normalizedTitle = terminalTitle
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard !normalizedTitle.isEmpty else {
            return "\(kind.displayName) \(sequenceNumber)"
        }

        let maximumLength = 48
        guard normalizedTitle.count > maximumLength else { return normalizedTitle }
        return String(normalizedTitle.prefix(maximumLength - 1)) + "…"
    }

    func startIfNeeded() {
        if hasStarted, let chatCoordinator {
            // Re-opening an already-started conversation: never let a visible
            // transcript sit out a reconnect backoff sleep.
            chatCoordinator.expediteReconnectIfWaiting()
        }
        guard !hasStarted,
              !hasFinished,
              launchState == .ready,
              status != .stopping,
              !isExited else { return }
        hasStarted = true
        status = .connecting
        if let chatCoordinator {
            terminalSessionLogger.notice(
                "Attaching native chat \(self.kind.rawValue, privacy: .public) session \(self.instanceToken, privacy: .public) for \(self.projectName, privacy: .public) on \(self.serverName, privacy: .public)"
            )
            chatCoordinator.start()
            return
        }
        terminalSessionLogger.notice(
            "Attaching \(self.kind.rawValue, privacy: .public) session \(self.instanceToken, privacy: .public) for \(self.projectName, privacy: .public) on \(self.serverName, privacy: .public)"
        )
        terminalView.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: nil
        )

        if terminalView.process.shellPid > 0 {
            status = .running
            terminalSessionLogger.info(
                "Terminal attachment started for session \(self.instanceToken, privacy: .public) with pid \(self.terminalView.process.shellPid, privacy: .public)"
            )
            updateWorkingState()
        } else {
            terminalSessionLogger.error(
                "Terminal attachment failed to start for session \(self.instanceToken, privacy: .public)"
            )
            finish(exitCode: nil)
        }
    }

    func sendPrompt(
        _ prompt: String,
        attachments: [ChatAttachmentReference] = []
    ) {
        if let chatCoordinator {
            guard !prompt.isEmpty else { return }
            Task {
                await chatCoordinator.send(
                    text: prompt,
                    attachments: attachments
                )
            }
            return
        }
        guard status == .running, !prompt.isEmpty else { return }
        terminalView.send(txt: "\u{1B}[200~\(prompt)\u{1B}[201~")
        pressReturn()
    }

    func updateChatLaunchOptions(
        model: String,
        reasoningEffort: String,
        fastMode: Bool
    ) {
        chatCoordinator?.updateLaunchOptions(
            model: model,
            reasoningEffort: reasoningEffort,
            fastMode: fastMode
        )
    }

    func sendCommand(_ command: String, focusesTerminal: Bool = false) {
        guard status == .running, !command.isEmpty else { return }
        terminalView.send(txt: command)
        pressReturn {
            if focusesTerminal {
                self.focusTerminal()
            }
        }
    }

    func selectCodexModel(pickerIndex: Int, effort: AgentReasoningEffort) {
        guard status == .running, kind == .codex else { return }

        terminalView.send(txt: "/model")
        pressReturn { [weak self] in
            guard let self else { return }
            self.scheduleTerminalKey(
                #selector(NSResponder.moveToBeginningOfLine(_:)),
                after: 0.3
            )
            for step in 0..<pickerIndex {
                self.scheduleTerminalKey(
                    #selector(NSResponder.moveDown(_:)),
                    after: 0.34 + (Double(step) * 0.025)
                )
            }

            let modelSelectionDelay = 0.34 + (Double(pickerIndex) * 0.025)
            self.scheduleTerminalKey(
                #selector(NSResponder.insertNewline(_:)),
                after: modelSelectionDelay
            )
            self.scheduleReasoningSelection(effort, after: modelSelectionDelay + 0.22)
        }
    }

    func interrupt() {
        if let chatCoordinator {
            Task {
                await chatCoordinator.interrupt()
            }
            return
        }
        guard status == .running else { return }
        sendEscape()
        DispatchQueue.main.async { [weak self] in
            self?.sendEscape()
        }
    }

    func sendEscape() {
        guard status == .running else { return }
        terminalView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }

    func focusTerminal() {
        guard let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    private func pressReturn(then action: (() -> Void)? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.terminalView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            action?()
        }
    }

    private func scheduleReasoningSelection(
        _ effort: AgentReasoningEffort,
        after delay: TimeInterval
    ) {
        switch effort {
        case .low, .medium, .high, .xhigh:
            let index: Int = switch effort {
            case .low: 0
            case .medium: 1
            case .high: 2
            case .xhigh: 3
            case .max, .ultra: 0
            }
            scheduleTerminalKey(#selector(NSResponder.moveToBeginningOfLine(_:)), after: delay)
            for step in 0..<index {
                scheduleTerminalKey(
                    #selector(NSResponder.moveDown(_:)),
                    after: delay + 0.04 + (Double(step) * 0.025)
                )
            }
            scheduleTerminalKey(
                #selector(NSResponder.insertNewline(_:)),
                after: delay + 0.04 + (Double(index) * 0.025)
            )

        case .max, .ultra:
            scheduleTerminalKey(#selector(NSResponder.moveToEndOfLine(_:)), after: delay)
            scheduleTerminalKey(
                #selector(NSResponder.insertNewline(_:)),
                after: delay + 0.04
            )
            scheduleTerminalKey(
                #selector(NSResponder.moveToBeginningOfLine(_:)),
                after: delay + 0.24
            )
            if effort == .ultra {
                scheduleTerminalKey(
                    #selector(NSResponder.moveDown(_:)),
                    after: delay + 0.28
                )
            }
            scheduleTerminalKey(
                #selector(NSResponder.insertNewline(_:)),
                after: delay + (effort == .ultra ? 0.32 : 0.28)
            )
        }
    }

    private func scheduleTerminalKey(_ selector: Selector, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.terminalView.doCommand(by: selector)
        }
    }

    private var isExited: Bool {
        if case .exited = status { return true }
        return false
    }

    func requestDisconnect() {
        guard status.isLocallyAttached, !hasFinished else { return }
        explicitDisconnectRequested = true

        if let chatCoordinator {
            status = .remoteRunning
            chatIndicatesWorking = false
            updateWorkingState()
            Task { [weak self] in
                await chatCoordinator.detach()
                self?.hasFinished = true
            }
            return
        }

        if !hasStarted {
            hasFinished = true
            status = .exited(nil)
            updateWorkingState()
            return
        }

        status = .remoteRunning
        titleIndicatesWorking = false
        progressIndicatesWorking = false
        updateWorkingState()

        let processID = terminalView.process.shellPid
        if processID > 0, processExitSource == nil {
            installExitMonitor(processID: processID)
        }

        terminalView.terminate()

        if processID <= 0 {
            finish(exitCode: nil)
        }
    }

    func beginRemoteStop() {
        guard status.occupiesSlot, status != .stopping else { return }
        statusBeforeStopping = status
        remoteStopRequested = true
        status = .stopping
        titleIndicatesWorking = false
        progressIndicatesWorking = false
        updateWorkingState()
    }

    func cancelRemoteStop() {
        guard status == .stopping else { return }
        if hasFinished, statusBeforeStopping?.isLocallyAttached == true {
            status = .disconnected(lastLocalExitCode)
        } else {
            status = statusBeforeStopping ?? .remoteRunning
        }
        statusBeforeStopping = nil
        remoteStopRequested = false
        updateWorkingState()
    }

    func completeRemoteStop() {
        guard status == .stopping || remoteStopRequested else { return }
        statusBeforeStopping = nil
        remoteAttachedClientCount = nil
        status = .exited(nil)
        hasFinished = true
        titleIndicatesWorking = false
        progressIndicatesWorking = false
        remoteIndicatesWorking = false
        processExitSource?.cancel()
        processExitSource = nil
        if terminalView.process.shellPid > 0 {
            terminalView.terminate()
        }
        if let chatCoordinator {
            Task {
                await chatCoordinator.detach()
            }
        }
        updateWorkingState()
    }

    func markLaunchFailed(_ message: String) {
        guard launchState == .starting else { return }
        launchState = .failed(message)
        status = .exited(nil)
        hasFinished = true
        updateWorkingState()
    }

    func applyRemoteSnapshot(_ snapshot: WorkerSessionSnapshot) {
        guard snapshot.kind == kind,
              snapshot.accountID == accountID,
              snapshot.repositoryName == projectName,
              snapshot.instanceToken == instanceToken,
              snapshot.presentation == presentation else {
            return
        }
        remoteAttachedClientCount = snapshot.attachedClientCount
        if let timestamp = snapshot.lastActivityAt {
            let reportedActivityAt = Date(timeIntervalSince1970: TimeInterval(timestamp))
            // The first observed epoch replaces a row-creation fallback even
            // when older; observed activity itself only ever moves forward.
            if lastActivityIsFallback || reportedActivityAt > lastActivityAt {
                lastActivityAt = reportedActivityAt
                lastActivityIsFallback = false
            }
        }
        if let threadID = snapshot.threadID {
            self.threadID = threadID
        }
        if let title = snapshot.title {
            applyResolvedTerminalTitle(title)
        } else if kind == .codex, snapshot.reportedWorking != nil {
            terminalTitle = nil
        }
        if let reportedWorking = snapshot.reportedWorking {
            remoteIndicatesWorking = reportedWorking
        }
        if status.canReconnect || isExited {
            status = .remoteRunning
        }
        updateWorkingState()
    }

    func markRemoteReplaced() {
        guard status.occupiesSlot else { return }
        remoteAttachedClientCount = nil
        statusBeforeStopping = nil
        remoteStopRequested = false
        explicitDisconnectRequested = false
        status = .exited(lastLocalExitCode)
        hasFinished = true
        titleIndicatesWorking = false
        progressIndicatesWorking = false
        remoteIndicatesWorking = false
        processExitSource?.cancel()
        processExitSource = nil
        if terminalView.process.shellPid > 0 {
            terminalView.terminate()
        }
        if let chatCoordinator {
            Task {
                await chatCoordinator.detach()
            }
        }
        updateWorkingState()
    }

    func markRemoteExited() {
        guard status.canReconnect else { return }
        remoteAttachedClientCount = nil
        remoteIndicatesWorking = false
        status = .exited(lastLocalExitCode)
        hasFinished = true
        if let chatCoordinator {
            Task {
                await chatCoordinator.detach()
            }
        }
        updateWorkingState()
    }

    private func installExitMonitor(processID: pid_t) {
        let source = DispatchSource.makeProcessSource(
            identifier: processID,
            eventMask: .exit,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            var waitStatus: Int32 = 0
            _ = waitpid(processID, &waitStatus, 0)
            self?.finish(exitCode: nil)
        }
        source.resume()
        processExitSource = source
    }

    private func finish(exitCode: Int32?) {
        guard !hasFinished else { return }
        hasFinished = true
        lastLocalExitCode = exitCode
        processExitSource?.cancel()
        processExitSource = nil
        if remoteStopRequested {
            status = .stopping
        } else if explicitDisconnectRequested {
            if !isExited {
                status = .remoteRunning
            }
        } else {
            remoteAttachedClientCount = nil
            status = .disconnected(exitCode)
        }
        titleIndicatesWorking = false
        progressIndicatesWorking = false
        remoteIndicatesWorking = false
        updateWorkingState()
        terminalSessionLogger.notice(
            "Terminal attachment finished for session \(self.instanceToken, privacy: .public); status=\(self.status.label, privacy: .public)"
        )
    }

    private func setProgressIndicatesWorking(_ indicatesWorking: Bool) {
        progressIndicatesWorking = indicatesWorking
        updateWorkingState()
    }

    private func applyTerminalTitle(_ title: String) {
        let previousTitle = terminalTitle
        if kind == .codex {
            if let parsedThreadID = Self.threadID(in: title) {
                threadID = parsedThreadID
            }
            let parsedTitle = CodexTerminalTitle(title)
            if let parsedTitle = parsedTitle.title {
                terminalTitle = parsedTitle
            }
            titleIndicatesWorking = parsedTitle.isWorking
        } else if let displayableTitle = displayableClaudeTerminalTitle(title) {
            terminalTitle = displayableTitle
        }
        if terminalTitle != previousTitle {
            lastActivityAt = Date()
            lastActivityIsFallback = false
        }
        updateWorkingState()
    }

    private static func threadID(in title: String) -> String? {
        guard let range = title.range(
            of: #"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"#,
            options: .regularExpression
        ),
        let id = UUID(uuidString: String(title[range])) else {
            return nil
        }
        return id.uuidString.lowercased()
    }

    private func applyResolvedTerminalTitle(_ title: String) {
        let previousTitle = terminalTitle
        if kind == .codex {
            if let displayableTitle = displayableTerminalTitle(title) {
                terminalTitle = displayableTitle
            }
        } else if let displayableTitle = displayableClaudeTerminalTitle(title) {
            terminalTitle = displayableTitle
        }
        if terminalTitle != previousTitle {
            lastActivityAt = Date()
            lastActivityIsFallback = false
        }
    }

    private func updateWorkingState() {
        let wasWorking = isWorking
        let nextWorking: Bool
        if presentation == .chat {
            switch status {
            case .connecting, .running:
                nextWorking = chatIndicatesWorking
            case .remoteRunning, .disconnected:
                nextWorking = remoteIndicatesWorking
            case .stopping, .exited:
                nextWorking = false
            }
        } else {
            switch status {
            case .connecting, .running:
                nextWorking = titleIndicatesWorking
                || progressIndicatesWorking
                || remoteIndicatesWorking
            case .remoteRunning, .disconnected:
                nextWorking = remoteIndicatesWorking
            case .stopping, .exited:
                nextWorking = false
            }
        }

        // @Published emits even when assigned the same value. Chat snapshots
        // arrive while a response streams, so an unconditional assignment
        // here used to invalidate SessionManager and the whole workspace at
        // the transport publication cadence despite no session-state change.
        guard nextWorking != wasWorking else { return }
        isWorking = nextWorking
        if wasWorking,
           !nextWorking,
           !explicitDisconnectRequested,
           !remoteStopRequested,
           status == .running || status == .remoteRunning {
           taskCompletionCount += 1
        }
        lastActivityAt = Date()
        lastActivityIsFallback = false
    }

    private func applyChatState(_ state: ConversationState) {
        guard presentation == .chat,
              hasStarted,
              !hasFinished,
              status != .stopping,
              !remoteStopRequested else {
            return
        }

        let nextWorking = state.turnState.isActive
        if chatIndicatesWorking != nextWorking {
            chatIndicatesWorking = nextWorking
        }
        let nextStatus: TerminalSessionStatus
        switch state.connectionState {
        case .connecting:
            nextStatus = .connecting
        case .streaming, .awaitingApproval, .interrupted:
            nextStatus = .running
        case .offlineAgentRunning:
            nextStatus = .remoteRunning
        case .stopped:
            nextStatus = .exited(nil)
        case .unsupportedWorker, .failed:
            nextStatus = .disconnected(nil)
        case .unknown:
            nextStatus = .running
        }
        if status != nextStatus {
            status = nextStatus
        }
        if state.connectionState == .stopped {
            hasFinished = true
        }
        updateWorkingState()
    }
}

private extension AgentLaunchDefaults {
    func chatOptions(for kind: AgentKind) -> ChatLaunchOptions {
        switch kind {
        case .codex:
            ChatLaunchOptions(
                model: codexModel,
                reasoningEffort: codexReasoningEffort.rawValue,
                sandbox: fullAccessEnabled ? "danger-full-access" : "workspace-write",
                approvalPolicy: fullAccessEnabled ? "never" : "on-request"
            )
        case .claude:
            ChatLaunchOptions(
                model: claudeModel,
                reasoningEffort: claudeReasoningEffort.rawValue,
                approvalPolicy: fullAccessEnabled ? "bypassPermissions" : "default"
            )
        }
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.applyTerminalTitle(title)
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.finish(exitCode: exitCode)
        }
    }
}
