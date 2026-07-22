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

    var onTermination: ((UUID) -> Void)?

    private let configuration: SSHLaunchConfiguration
    private var hasStarted = false
    private var hasFinished = false
    private var processExitSource: DispatchSourceProcess?

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
        } else {
            finish(exitCode: nil)
        }
    }

    func requestStop() {
        guard status.occupiesSlot, !hasFinished else { return }
        status = .stopping

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
        onTermination?(id)
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor [weak self] in
            self?.terminalTitle = title
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            self?.finish(exitCode: exitCode)
        }
    }
}
