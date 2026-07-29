import Combine
import Foundation
import SwiftTerm

enum WorkerSessionConfirmation: Equatable {
    case active(instanceToken: String)
    case ended
    case moved(repositoryName: String)
    case replaced
}

enum TerminalSessionRecoveryError: LocalizedError, Equatable {
    case ended(kind: AgentKind, repositoryName: String)
    case moved(kind: AgentKind, repositoryName: String)
    case replaced(kind: AgentKind, repositoryName: String)
    case unconfirmed(kind: AgentKind, repositoryName: String)
    case invalidStartResponse(kind: AgentKind, repositoryName: String)

    var errorDescription: String? {
        switch self {
        case .ended(let kind, let repositoryName):
            "The \(kind.displayName) session in \(repositoryName) has ended. Return to Projects to start it again."
        case .moved(let kind, let repositoryName):
            "\(kind.displayName) is now running in \(repositoryName). Return to Projects to attach there."
        case .replaced(let kind, let repositoryName):
            "The original \(kind.displayName) session in \(repositoryName) ended and was replaced. Return to Projects to attach to the new session."
        case .unconfirmed(let kind, let repositoryName):
            "The \(kind.displayName) session in \(repositoryName) has not finished starting yet."
        case .invalidStartResponse(let kind, let repositoryName):
            "The worker returned an invalid session record while starting \(kind.displayName) in \(repositoryName)."
        }
    }
}

enum TerminalSessionInitialAction: Equatable {
    case start
    case reattach(instanceToken: String)
}

enum TerminalSessionCommandPolicy {
    static func initialAction(instanceToken: String?) -> TerminalSessionInitialAction {
        if let instanceToken {
            .reattach(instanceToken: instanceToken)
        } else {
            .start
        }
    }

    static func terminalCommand(
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String
    ) throws -> String {
        try WorkerRemoteCommand.reattach(
            kind: kind,
            repositoryName: repositoryName,
            instanceToken: instanceToken
        )
    }

    static func launchCommand(
        kind: AgentKind,
        repositoryName: String,
        providerThreadID: String?,
        launchArguments: [String]
    ) throws -> String {
        if let providerThreadID {
            return try WorkerRemoteCommand.resumeThread(
                kind: kind,
                repositoryName: repositoryName,
                threadID: providerThreadID,
                launchArguments: launchArguments
            )
        }
        return try WorkerRemoteCommand.start(
            kind: kind,
            repositoryName: repositoryName,
            launchArguments: launchArguments
        )
    }
}

@MainActor
final class TerminalSessionController: ObservableObject, RelayTerminalIO {
    @Published private(set) var state: TerminalConnectionState = .disconnected

    let kind: AgentKind
    let repositoryName: String

    private let profile: WorkerProfile
    private let launchArguments: [String]
    private let identityStore: SSHIdentityStore
    private let workerClient: SSHWorkerClient
    private weak var terminalView: RelayTerminalView?
    private var connection: SSHTerminalConnection?
    private var connectionID = UUID()
    private var operationID = UUID()
    private var instanceToken: String?
    private var providerThreadID: String?
    private var didStartInitialConnection = false
    private var isStartingSession = false
    private var isConfirmingReconnect = false
    private var isSuspended = false
    private var shouldReconnect = true

    init(
        profile: WorkerProfile,
        kind: AgentKind,
        repositoryName: String,
        instanceToken: String? = nil,
        providerThreadID: String? = nil,
        identityStore: SSHIdentityStore = SSHIdentityStore()
    ) {
        self.profile = profile
        self.kind = kind
        self.repositoryName = repositoryName
        self.instanceToken = instanceToken
        self.providerThreadID = providerThreadID
        self.identityStore = identityStore
        self.workerClient = SSHWorkerClient(identityStore: identityStore)
        self.launchArguments = AgentLaunchDefaults.standard.arguments(for: kind)
    }

    func bind(to terminalView: RelayTerminalView) {
        self.terminalView = terminalView
        terminalView.relayIO = self
        if !didStartInitialConnection {
            didStartInitialConnection = true
            switch TerminalSessionCommandPolicy.initialAction(instanceToken: instanceToken) {
            case .start:
                Task { @MainActor [weak self] in
                    await self?.startSessionAndConnect()
                }
            case .reattach(let instanceToken):
                connectToInstance(instanceToken)
            }
        }
    }

    /// Configures the terminal fallback to resume the provider conversation
    /// released by native chat. This is only valid before the PTY view binds,
    /// which prevents a fallback race from launching a fresh conversation.
    @discardableResult
    func configureForChatFallback(providerThreadID: String) -> Bool {
        guard ChatWireValidation.isCanonicalUUID(providerThreadID),
              !didStartInitialConnection,
              connection == nil,
              instanceToken == nil else {
            return false
        }
        self.providerThreadID = providerThreadID
        return true
    }

    private func startSessionAndConnect() async {
        if let instanceToken {
            connectToInstance(instanceToken)
            return
        }
        guard shouldReconnect, connection == nil, !isStartingSession else { return }

        isStartingSession = true
        state = .connecting
        defer { isStartingSession = false }

        do {
            let command = try TerminalSessionCommandPolicy.launchCommand(
                kind: kind,
                repositoryName: repositoryName,
                providerThreadID: providerThreadID,
                launchArguments: launchArguments
            )
            let data = try await workerClient.execute(command, on: profile)
            let response = try WorkerSessionProtocol.parse(data)
            let session = try Self.startedSession(
                in: response,
                kind: kind,
                repositoryName: repositoryName
            )
            if let providerThreadID, session.threadID != providerThreadID {
                throw TerminalSessionRecoveryError.invalidStartResponse(
                    kind: kind,
                    repositoryName: repositoryName
                )
            }
            instanceToken = session.instanceToken

            guard shouldReconnect, !isSuspended, connection == nil else { return }
            connectToInstance(session.instanceToken)
        } catch {
            guard shouldReconnect else { return }
            state = .failed(
                "Could not start the remote session. Check the worker connection and try again. \(error.localizedDescription)"
            )
        }
    }

    private func connectToInstance(_ instanceToken: String) {
        do {
            let command = try TerminalSessionCommandPolicy.terminalCommand(
                kind: kind,
                repositoryName: repositoryName,
                instanceToken: instanceToken
            )
            connect(using: command)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func connect(using command: String) {
        guard connection == nil, !isSuspended, let terminalView else { return }

        do {
            let privateKey = try identityStore.loadOrCreatePrivateKey()
            let terminal = terminalView.getTerminal()
            let size = (
                columns: terminal.cols > 0 ? terminal.cols : 80,
                rows: terminal.rows > 0 ? terminal.rows : 24
            )
            let id = UUID()
            connectionID = id
            shouldReconnect = true

            let connection = SSHTerminalConnection(
                profile: profile,
                privateKey: privateKey,
                command: command,
                initialSize: size,
                onOutput: { [weak terminalView] data in
                    let bytes = [UInt8](data)
                    DispatchQueue.main.async {
                        terminalView?.feed(byteArray: bytes[...])
                    }
                },
                onStateChange: { [weak self] newState in
                    DispatchQueue.main.async {
                        guard let self, self.connectionID == id else { return }
                        self.state = newState
                        if newState == .disconnected || Self.isFailure(newState) {
                            self.connection = nil
                        }
                    }
                }
            )
            self.connection = connection
            state = .connecting
            connection.connect()
            _ = terminalView.becomeFirstResponder()
        } catch {
            state = .failed(error.localizedDescription)
            connection = nil
        }
    }

    func disconnect(manually: Bool) {
        shouldReconnect = !manually
        connectionID = UUID()
        operationID = UUID()
        isConfirmingReconnect = false
        let oldConnection = connection
        connection = nil
        oldConnection?.disconnect()
        state = .disconnected
    }

    func suspendForBackground() {
        isSuspended = true
        disconnect(manually: false)
    }

    func reconnectAfterForeground() async {
        isSuspended = false
        guard shouldReconnect, connection == nil else { return }
        await reconnect()
    }

    func reconnect() async {
        guard shouldReconnect, connection == nil else { return }
        guard let expectedInstanceToken = instanceToken else {
            await startSessionAndConnect()
            return
        }
        guard !isStartingSession, !isConfirmingReconnect else { return }

        let id = UUID()
        operationID = id
        isConfirmingReconnect = true
        state = .connecting
        defer {
            if operationID == id {
                isConfirmingReconnect = false
            }
        }

        do {
            let response = try await authoritativeStatus()
            guard operationID == id, shouldReconnect, connection == nil else { return }

            switch Self.confirmation(
                in: response,
                kind: kind,
                repositoryName: repositoryName,
                expectedInstanceToken: expectedInstanceToken
            ) {
            case .active(let confirmedToken):
                self.instanceToken = confirmedToken
                connectToInstance(confirmedToken)
            case .ended:
                shouldReconnect = false
                state = .ended(
                    TerminalSessionRecoveryError.ended(
                        kind: kind,
                        repositoryName: repositoryName
                    ).localizedDescription
                )
            case .moved(let activeRepository):
                shouldReconnect = false
                state = .ended(
                    TerminalSessionRecoveryError.moved(
                        kind: kind,
                        repositoryName: activeRepository
                    ).localizedDescription
                )
            case .replaced:
                shouldReconnect = false
                state = .ended(
                    TerminalSessionRecoveryError.replaced(
                        kind: kind,
                        repositoryName: repositoryName
                    ).localizedDescription
                )
            }
        } catch {
            guard operationID == id else { return }
            state = .failed(
                "Could not confirm that the remote session is still running. Check the worker connection and try again. \(error.localizedDescription)"
            )
        }
    }

    func stopAgent() async throws {
        guard let expectedInstanceToken = instanceToken else {
            throw TerminalSessionRecoveryError.unconfirmed(
                kind: kind,
                repositoryName: repositoryName
            )
        }
        let response = try await authoritativeStatus()
        let confirmation = Self.confirmation(
            in: response,
            kind: kind,
            repositoryName: repositoryName,
            expectedInstanceToken: expectedInstanceToken
        )
        let confirmedToken: String
        switch confirmation {
        case .active(let token):
            confirmedToken = token
            self.instanceToken = token
        case .ended:
            throw TerminalSessionRecoveryError.ended(kind: kind, repositoryName: repositoryName)
        case .moved(let activeRepository):
            throw TerminalSessionRecoveryError.moved(kind: kind, repositoryName: activeRepository)
        case .replaced:
            throw TerminalSessionRecoveryError.replaced(kind: kind, repositoryName: repositoryName)
        }

        let command = try WorkerRemoteCommand.stop(
            kind: kind,
            repositoryName: repositoryName,
            instanceToken: confirmedToken
        )
        _ = try await workerClient.execute(command, on: profile)
        disconnect(manually: true)
    }

    func sendTerminalInput(_ data: Data) {
        connection?.send(data)
    }

    func resizeTerminal(columns: Int, rows: Int) {
        connection?.resize(columns: columns, rows: rows)
    }

    func sendKey(_ key: MobileTerminalKey) {
        sendTerminalInput(key.data)
        _ = terminalView?.becomeFirstResponder()
    }

    private static func isFailure(_ state: TerminalConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }

    nonisolated static func confirmation(
        in response: WorkerSessionResponse,
        kind: AgentKind,
        repositoryName: String,
        expectedInstanceToken: String
    ) -> WorkerSessionConfirmation {
        guard let session = response.sessions.first(where: {
            $0.instanceToken == expectedInstanceToken
        }) else {
            return .ended
        }
        guard session.kind == kind else {
            return .ended
        }
        guard session.repositoryName == repositoryName else {
            return .moved(repositoryName: session.repositoryName)
        }
        return .active(instanceToken: session.instanceToken)
    }

    nonisolated static func startedSession(
        in response: WorkerSessionResponse,
        kind: AgentKind,
        repositoryName: String
    ) throws -> WorkerSessionSnapshot {
        guard response.projects.isEmpty,
              response.sessions.count == 1,
              let session = response.sessions.first,
              session.kind == kind,
              session.repositoryName == repositoryName else {
            throw TerminalSessionRecoveryError.invalidStartResponse(
                kind: kind,
                repositoryName: repositoryName
            )
        }
        return session
    }

    private func authoritativeStatus() async throws -> WorkerSessionResponse {
        let data = try await workerClient.execute(WorkerRemoteCommand.status, on: profile)
        return try WorkerSessionProtocol.parse(data)
    }
}

enum MobileTerminalKey: CaseIterable, Equatable, Identifiable {
    case escape
    case tab
    case controlC
    case left
    case down
    case up
    case right

    var id: String { label }

    var label: String {
        switch self {
        case .escape: "Esc"
        case .tab: "Tab"
        case .controlC: "Ctrl-C"
        case .left: "←"
        case .down: "↓"
        case .up: "↑"
        case .right: "→"
        }
    }

    var data: Data {
        switch self {
        case .escape: Data([0x1b])
        case .tab: Data([0x09])
        case .controlC: Data([0x03])
        case .left: Data([0x1b, 0x5b, 0x44])
        case .down: Data([0x1b, 0x5b, 0x42])
        case .up: Data([0x1b, 0x5b, 0x41])
        case .right: Data([0x1b, 0x5b, 0x43])
        }
    }
}
