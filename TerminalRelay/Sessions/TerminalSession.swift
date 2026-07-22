import AppKit
import Combine
import Darwin
import SwiftTerm

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
    let terminalViewIdentity = UUID()
    let projectID: UUID
    let projectName: String
    let workingDirectory: String
    let serverKey: String
    let serverName: String
    let kind: AgentKind
    let accountLabel: String
    let sequenceNumber: Int
    let startedAt: Date
    let instanceToken: String
    let terminalView: LocalProcessTerminalView

    @Published private(set) var status: TerminalSessionStatus
    @Published private(set) var terminalTitle: String?
    @Published private(set) var isWorking = false
    @Published private(set) var remoteAttachedClientCount: Int?

    private let configuration: SSHLaunchConfiguration
    private var hasStarted = false
    private var hasFinished = false
    private var processExitSource: DispatchSourceProcess?
    private var titleIndicatesWorking = false
    private var progressIndicatesWorking = false
    private var lastLocalExitCode: Int32?
    private var statusBeforeStopping: TerminalSessionStatus?
    private var remoteStopRequested = false
    private var explicitDisconnectRequested = false

    init(
        project: ProjectProfile,
        server: ServerProfile,
        kind: AgentKind,
        sequenceNumber: Int,
        instanceToken: String,
        id: UUID = UUID(),
        startedAt: Date = Date(),
        initialStatus: TerminalSessionStatus = .connecting,
        terminalTitle: String? = nil,
        remoteAttachedClientCount: Int? = nil
    ) {
        self.id = id
        self.projectID = project.id
        self.projectName = project.displayName
        self.workingDirectory = project.workingDirectory
        self.serverKey = server.concurrencyKey
        self.serverName = server.displayName
        self.kind = kind
        self.accountLabel = server.accountLabel(for: kind)
        self.sequenceNumber = sequenceNumber
        self.startedAt = startedAt
        self.instanceToken = instanceToken
        self.status = initialStatus
        self.terminalTitle = terminalTitle
        self.remoteAttachedClientCount = remoteAttachedClientCount
        self.configuration = SSHCommandBuilder.configuration(
            for: server,
            project: project,
            kind: kind,
            instanceToken: instanceToken
        )
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        super.init()

        terminalView.processDelegate = self
        terminalView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        terminalView.nativeBackgroundColor = NSColor(srgbRed: 0.071, green: 0.071, blue: 0.078, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(srgbRed: 0.87, green: 0.89, blue: 0.92, alpha: 1)
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true

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
        guard !hasStarted,
              !hasFinished,
              status != .stopping,
              !isExited else { return }
        hasStarted = true
        status = .connecting
        terminalView.startProcess(
            executable: configuration.executable,
            args: configuration.arguments,
            environment: nil
        )

        if terminalView.process.shellPid > 0 {
            status = .running
            updateWorkingState()
        } else {
            finish(exitCode: nil)
        }
    }

    private var isExited: Bool {
        if case .exited = status { return true }
        return false
    }

    func requestDisconnect() {
        guard status.isLocallyAttached, !hasFinished else { return }
        explicitDisconnectRequested = true

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
        processExitSource?.cancel()
        processExitSource = nil
        if terminalView.process.shellPid > 0 {
            terminalView.terminate()
        }
        updateWorkingState()
    }

    func applyRemoteSnapshot(_ snapshot: WorkerSessionSnapshot) {
        guard snapshot.kind == kind,
              snapshot.repositoryName == projectName,
              snapshot.instanceToken == instanceToken else {
            return
        }
        remoteAttachedClientCount = snapshot.attachedClientCount
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
        processExitSource?.cancel()
        processExitSource = nil
        if terminalView.process.shellPid > 0 {
            terminalView.terminate()
        }
        updateWorkingState()
    }

    func markRemoteExited() {
        guard status.canReconnect else { return }
        remoteAttachedClientCount = nil
        status = .exited(lastLocalExitCode)
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
        updateWorkingState()
    }

    private func setProgressIndicatesWorking(_ indicatesWorking: Bool) {
        progressIndicatesWorking = indicatesWorking
        updateWorkingState()
    }

    private func applyTerminalTitle(_ title: String) {
        if kind == .codex {
            let parsedTitle = CodexTerminalTitle(title)
            if let parsedTitle = parsedTitle.title {
                terminalTitle = parsedTitle
            }
            titleIndicatesWorking = parsedTitle.isWorking
        } else if let displayableTitle = displayableTerminalTitle(title) {
            terminalTitle = displayableTitle
        }
        updateWorkingState()
    }

    private func updateWorkingState() {
        switch status {
        case .connecting, .running:
            isWorking = titleIndicatesWorking || progressIndicatesWorking
        case .remoteRunning, .disconnected, .stopping, .exited:
            isWorking = false
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
