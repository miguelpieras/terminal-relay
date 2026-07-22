import AppKit
import Combine
import Darwin
import SwiftTerm

enum TerminalSessionStatus: Equatable {
    case connecting
    case running
    case stopping
    case exited(Int32?)

    var occupiesSlot: Bool {
        switch self {
        case .connecting, .running, .stopping: true
        case .exited: false
        }
    }

    var label: String {
        switch self {
        case .connecting: "Connecting"
        case .running: "Connected"
        case .stopping: "Stopping"
        case .exited(let code):
            if let code { "Exited (\(code))" } else { "Disconnected" }
        }
    }
}

private struct CodexTerminalTitle {
    private static let runStates = Set(["Ready", "Working", "Thinking", "Waiting", "Starting"])

    let title: String?
    let isWorking: Bool

    init(_ rawTitle: String) {
        let normalizedTitle = rawTitle
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let parts = normalizedTitle.components(separatedBy: " | ")

        guard let runState = parts.last, Self.runStates.contains(runState) else {
            title = normalizedTitle.isEmpty ? nil : normalizedTitle
            isWorking = false
            return
        }

        let displayTitle = parts.dropLast().joined(separator: " | ")
        title = displayTitle.isEmpty ? nil : displayTitle
        isWorking = runState != "Ready"
    }
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
    let id = UUID()
    let projectID: UUID
    let projectName: String
    let workingDirectory: String
    let serverKey: String
    let serverName: String
    let kind: AgentKind
    let accountLabel: String
    let sequenceNumber: Int
    let startedAt = Date()
    let terminalView: LocalProcessTerminalView

    @Published private(set) var status: TerminalSessionStatus = .connecting
    @Published private(set) var terminalTitle: String?
    @Published private(set) var isWorking = false

    var onTermination: ((UUID) -> Void)?

    private let configuration: SSHLaunchConfiguration
    private var hasStarted = false
    private var hasFinished = false
    private var processExitSource: DispatchSourceProcess?
    private var titleIndicatesWorking = false
    private var progressIndicatesWorking = false

    init(
        project: ProjectProfile,
        server: ServerProfile,
        kind: AgentKind,
        sequenceNumber: Int,
        launchDefaults: AgentLaunchDefaults
    ) {
        self.projectID = project.id
        self.projectName = project.displayName
        self.workingDirectory = project.workingDirectory
        self.serverKey = server.concurrencyKey
        self.serverName = server.displayName
        self.kind = kind
        self.accountLabel = server.accountLabel(for: kind)
        self.sequenceNumber = sequenceNumber
        self.configuration = SSHCommandBuilder.configuration(
            for: server,
            project: project,
            kind: kind,
            launchDefaults: launchDefaults
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
        guard !hasStarted, !hasFinished else { return }
        hasStarted = true
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

    func requestStop() {
        guard status.occupiesSlot, !hasFinished else { return }
        status = .stopping
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
        processExitSource?.cancel()
        processExitSource = nil
        status = .exited(exitCode)
        titleIndicatesWorking = false
        progressIndicatesWorking = false
        updateWorkingState()
        onTermination?(id)
    }

    private func setProgressIndicatesWorking(_ indicatesWorking: Bool) {
        progressIndicatesWorking = indicatesWorking
        updateWorkingState()
    }

    private func applyTerminalTitle(_ title: String) {
        if kind == .codex {
            let parsedTitle = CodexTerminalTitle(title)
            terminalTitle = parsedTitle.title
            titleIndicatesWorking = parsedTitle.isWorking
        } else {
            terminalTitle = title
        }
        updateWorkingState()
    }

    private func updateWorkingState() {
        switch status {
        case .connecting, .running:
            isWorking = titleIndicatesWorking || progressIndicatesWorking
        case .stopping, .exited:
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
