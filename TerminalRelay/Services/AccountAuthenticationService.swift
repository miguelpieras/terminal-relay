import AppKit
import Combine
import Foundation
import OSLog

private let accountAuthenticationLogger = Logger(
    subsystem: "com.mpieras.TerminalRelay",
    category: "account-authentication"
)

struct AccountAuthenticationPresentation: Identifiable, Equatable {
    let id: UUID
    let worker: ServerProfile
    let kind: AgentKind
    let account: ProviderAccountProfile?
    let currentAccount: String?

    init(
        id: UUID = UUID(),
        worker: ServerProfile,
        kind: AgentKind,
        account: ProviderAccountProfile? = nil,
        currentAccount: String?
    ) {
        self.id = id
        self.worker = worker
        self.kind = kind
        self.account = account
        self.currentAccount = currentAccount
    }
}

enum AccountAuthenticationPhase: Equatable {
    case idle
    case connecting
    case awaitingAuthorization
    case finishing
    case succeeded
    case failed(String)
}

struct AccountAuthenticationOutput: Equatable {
    let authorizationURL: URL?
    let deviceCode: String?
}

enum AccountChangePolicy {
    static func requiresStoppingActiveAgent(
        kind: AgentKind,
        hasActiveAgent: Bool
    ) -> Bool {
        false
    }
}

enum AccountAuthenticationOutputParser {
    static func parse(_ output: String, for kind: AgentKind) -> AccountAuthenticationOutput {
        let authorizationURL = urls(in: output).first { url in
            guard let host = url.host?.lowercased() else { return false }
            switch kind {
            case .codex:
                return host == "auth.openai.com" && url.path == "/codex/device"
            case .claude:
                return host.hasSuffix("claude.com")
                    && url.path == "/cai/oauth/authorize"
            }
        }
        let deviceCode: String?
        if kind == .codex,
           let range = output.range(
               of: #"(?<![A-Z0-9])[A-Z0-9]{4}-[A-Z0-9]{4,5}(?![A-Z0-9])"#,
               options: .regularExpression
           ) {
            deviceCode = String(output[range])
        } else {
            deviceCode = nil
        }
        return AccountAuthenticationOutput(
            authorizationURL: authorizationURL,
            deviceCode: deviceCode
        )
    }

    private static func urls(in output: String) -> [URL] {
        var result: [URL] = []
        var searchStart = output.startIndex
        let excludedCharacters = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "<>\"\u{001B}\u{0007}")
        )

        while searchStart < output.endIndex,
              let prefixRange = output.range(
                  of: "https://",
                  range: searchStart..<output.endIndex
              ) {
            var end = prefixRange.upperBound
            while end < output.endIndex {
                let character = output[end]
                if character.unicodeScalars.contains(where: {
                    excludedCharacters.contains($0)
                }) {
                    break
                }
                end = output.index(after: end)
            }

            var candidate = String(output[prefixRange.lowerBound..<end])
            while let last = candidate.last, ".,)".contains(last) {
                candidate.removeLast()
            }
            if let url = URL(string: candidate) {
                result.append(url)
            }
            searchStart = end
        }
        return result
    }
}

enum AccountAuthenticationCommand {
    static func configuration(
        for worker: ServerProfile,
        kind: AgentKind,
        accountID: ProviderAccountID? = nil
    ) -> SSHLaunchConfiguration {
        var arguments = [
            "-tt",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=30",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new"
        ]

        if worker.port != 22 {
            arguments += ["-p", String(worker.port)]
        }

        let identityFile = worker.identityFile
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !identityFile.isEmpty {
            arguments += ["-i", (identityFile as NSString).expandingTildeInPath]
        }

        let loginCommand: String
        if let accountID {
            loginCommand = [
                WorkerSessionProtocol.helperPath,
                "provider-account-login-v1",
                kind.rawValue,
                accountID.rawValue,
            ]
                .map(SSHCommandBuilder.shellQuote)
                .joined(separator: " ")
        } else {
            loginCommand = switch kind {
            case .codex:
                "\(WorkerSessionProtocol.helperPath) codex-login"
            case .claude:
                "claude auth login --claudeai"
            }
        }
        let script = "stty -echo 2>/dev/null || true; exec \(loginCommand)"
        let remoteCommand = "exec \"${SHELL:-/bin/sh}\" -lic \(SSHCommandBuilder.shellQuote(script))"

        arguments += ["--", worker.destination, remoteCommand]
        return SSHLaunchConfiguration(executable: "/usr/bin/ssh", arguments: arguments)
    }
}

@MainActor
final class AccountAuthenticationService: ObservableObject {
    @Published var presentation: AccountAuthenticationPresentation?
    @Published private(set) var phase: AccountAuthenticationPhase = .idle
    @Published private(set) var authorizationURL: URL?
    @Published private(set) var deviceCode: String?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var activeRunID: UUID?
    private var outputBuffer = ""
    private var didOpenAuthorizationURL = false

    var isRunning: Bool {
        switch phase {
        case .connecting, .awaitingAuthorization, .finishing:
            true
        case .idle, .succeeded, .failed:
            false
        }
    }

    func begin(
        worker: ServerProfile,
        kind: AgentKind,
        currentAccount: String?
    ) {
        accountAuthenticationLogger.notice(
            "Beginning \(kind.rawValue, privacy: .public) sign-in on \(worker.destination, privacy: .public)"
        )
        cancelCurrentRun()
        presentation = AccountAuthenticationPresentation(
            worker: worker,
            kind: kind,
            currentAccount: currentAccount
        )
        resetTransientState()
        start()
    }

    func begin(worker: ServerProfile, account: ProviderAccountProfile) {
        accountAuthenticationLogger.notice(
            "Beginning \(account.provider.rawValue, privacy: .public) sign-in for account \(account.accountID.rawValue, privacy: .public) on \(worker.destination, privacy: .public)"
        )
        cancelCurrentRun()
        presentation = AccountAuthenticationPresentation(
            worker: worker,
            kind: account.provider,
            account: account,
            currentAccount: account.displayName
        )
        resetTransientState()
        start()
    }

    func retry() {
        guard let presentation else { return }
        accountAuthenticationLogger.notice(
            "Retrying \(presentation.kind.rawValue, privacy: .public) sign-in on \(presentation.worker.destination, privacy: .public)"
        )
        cancelCurrentRun()
        resetTransientState()
        start()
    }

    func submitClaudeAuthorizationCode(_ value: String) {
        guard presentation?.kind == .claude,
              isRunning,
              let inputHandle = inputPipe?.fileHandleForWriting else { return }
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, code.count <= 4_096,
              !code.contains("\n"), !code.contains("\r"),
              let data = "\(code)\n".data(using: .utf8) else { return }

        do {
            try inputHandle.write(contentsOf: data)
            phase = .finishing
            accountAuthenticationLogger.info(
                "Submitted Claude authorization response to \(self.presentation?.worker.destination ?? "unknown", privacy: .public)"
            )
        } catch {
            fail("The authorization code could not be sent to the worker.")
        }
    }

    func openAuthorizationPage() {
        guard let authorizationURL else { return }
        NSWorkspace.shared.open(authorizationURL)
    }

    func dismiss() {
        cancelCurrentRun()
        presentation = nil
        resetTransientState()
    }

    private func start() {
        guard let presentation else { return }
        let configuration = AccountAuthenticationCommand.configuration(
            for: presentation.worker,
            kind: presentation.kind,
            accountID: presentation.account?.accountID
        )
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let runID = UUID()

        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receive(data, runID: runID)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.receive(data, runID: runID)
            }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { @MainActor [weak self] in
                self?.finish(runID: runID, status: status)
            }
        }

        self.process = process
        self.inputPipe = inputPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        activeRunID = runID
        phase = .connecting
        accountAuthenticationLogger.info(
            "Starting secure sign-in process for \(presentation.kind.rawValue, privacy: .public) on \(presentation.worker.destination, privacy: .public)"
        )

        do {
            try process.run()
        } catch {
            accountAuthenticationLogger.error(
                "Could not start sign-in process for \(presentation.kind.rawValue, privacy: .public) on \(presentation.worker.destination, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            activeRunID = nil
            cleanUpProcess()
            fail("Terminal Relay could not start the secure worker sign-in.")
        }
    }

    private func receive(_ data: Data, runID: UUID) {
        guard activeRunID == runID else { return }
        outputBuffer += String(decoding: data, as: UTF8.self)
        if outputBuffer.count > 65_536 {
            outputBuffer = String(outputBuffer.suffix(65_536))
        }

        let parsed = AccountAuthenticationOutputParser.parse(
            outputBuffer,
            for: presentation?.kind ?? .codex
        )
        if authorizationURL == nil, let url = parsed.authorizationURL {
            authorizationURL = url
            accountAuthenticationLogger.info(
                "Received authorization URL for \(self.presentation?.kind.rawValue ?? "unknown", privacy: .public) on \(self.presentation?.worker.destination ?? "unknown", privacy: .public)"
            )
        }
        if deviceCode == nil, let code = parsed.deviceCode {
            deviceCode = code
        }

        guard authorizationURL != nil else { return }
        if phase != .finishing {
            phase = .awaitingAuthorization
        }
        if !didOpenAuthorizationURL {
            didOpenAuthorizationURL = true
            openAuthorizationPage()
        }
    }

    private func finish(runID: UUID, status: Int32) {
        guard activeRunID == runID else { return }
        activeRunID = nil
        cleanUpProcess()
        if status == 0 {
            accountAuthenticationLogger.notice(
                "Sign-in process succeeded for \(self.presentation?.kind.rawValue ?? "unknown", privacy: .public) on \(self.presentation?.worker.destination ?? "unknown", privacy: .public)"
            )
            phase = .succeeded
            outputBuffer = ""
        } else {
            accountAuthenticationLogger.error(
                "Sign-in process exited with status \(status, privacy: .public) for \(self.presentation?.kind.rawValue ?? "unknown", privacy: .public) on \(self.presentation?.worker.destination ?? "unknown", privacy: .public)"
            )
            fail(failureMessage(for: outputBuffer))
        }
    }

    private func failureMessage(for output: String) -> String {
        let lowercased = output.lowercased()
        if lowercased.contains("permission denied") {
            return "SSH authentication to the worker was denied."
        }
        if lowercased.contains("could not resolve hostname") {
            return "The worker hostname could not be resolved."
        }
        if lowercased.contains("connection timed out")
            || lowercased.contains("operation timed out") {
            return "The worker did not respond in time."
        }
        return "Sign-in ended before the account was connected."
    }

    private func fail(_ message: String) {
        accountAuthenticationLogger.error("\(message, privacy: .public)")
        phase = .failed(message)
        outputBuffer = ""
    }

    private func resetTransientState() {
        phase = .idle
        authorizationURL = nil
        deviceCode = nil
        outputBuffer = ""
        didOpenAuthorizationURL = false
    }

    private func cancelCurrentRun() {
        activeRunID = nil
        if let process, process.isRunning {
            accountAuthenticationLogger.info("Cancelling active sign-in process")
            process.terminate()
        }
        cleanUpProcess()
    }

    private func cleanUpProcess() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        try? errorPipe?.fileHandleForReading.close()
        process = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
    }
}

enum ProviderAccountServiceError: LocalizedError, Equatable {
    case invalidLabel
    case legacyTasksRunning(AgentKind)
    case commandFailed
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidLabel:
            "Enter an account name between 1 and 100 bytes."
        case .legacyTasksRunning(let provider):
            "Stop every existing \(provider.displayName) task on this worker, then add the account again."
        case .commandFailed:
            "The worker could not complete that account action."
        case .invalidResponse:
            "The worker returned unexpected account metadata."
        }
    }
}

/// Account catalog used by all Mac task-creation and account-management UI.
/// Only public routing metadata is retained; provider credentials stay on the
/// worker in the profile selected by `accountID`.
@MainActor
final class ProviderAccountService: ObservableObject {
    typealias CommandRunner = (SSHLaunchConfiguration) async throws -> WorkerSessionCommandResult

    @Published private(set) var profilesByWorker: [UUID: [ProviderAccountProfile]] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published private(set) var loadingWorkerIDs: Set<UUID> = []
    @Published private(set) var mutatingAccounts: Set<ProviderAccountKey> = []

    private let runCommand: CommandRunner

    convenience init() {
        self.init { configuration in
            let result = try await Subprocess.run(
                executable: URL(fileURLWithPath: configuration.executable),
                arguments: configuration.arguments
            )
            return WorkerSessionCommandResult(
                exitCode: result.exitCode,
                standardOutput: result.standardOutput,
                standardError: result.standardError
            )
        }
    }

    init(runCommand: @escaping CommandRunner) {
        self.runCommand = runCommand
    }

    func accounts(
        workerID: UUID,
        provider: AgentKind? = nil
    ) -> [ProviderAccountProfile] {
        let accounts = profilesByWorker[workerID] ?? []
        guard let provider else { return accounts }
        return accounts.filter { $0.provider == provider }
    }

    func account(
        workerID: UUID,
        provider: AgentKind,
        accountID: ProviderAccountID
    ) -> ProviderAccountProfile? {
        accounts(workerID: workerID, provider: provider).first {
            $0.accountID == accountID
        }
    }

    @discardableResult
    func refresh(
        worker: ServerProfile,
        provider: AgentKind? = nil
    ) async -> [ProviderAccountProfile]? {
        guard loadingWorkerIDs.insert(worker.id).inserted else {
            return provider.map { accounts(workerID: worker.id, provider: $0) }
                ?? accounts(workerID: worker.id)
        }
        defer { loadingWorkerIDs.remove(worker.id) }
        do {
            let result = try await runCommand(
                SSHCommandBuilder.providerAccountListConfiguration(
                    for: worker,
                    provider: provider
                )
            )
            guard result.exitCode == 0 else {
                throw ProviderAccountServiceError.commandFailed
            }
            let loaded = try ProviderAccountProtocol.parse(
                result.standardOutput,
                expectedProvider: provider
            )
            if let provider {
                replaceProfiles(loaded, provider: provider, workerID: worker.id)
            } else {
                profilesByWorker[worker.id] = loaded
            }
            errors[worker.id] = nil
            return loaded
        } catch {
            errors[worker.id] = message(for: error)
            return nil
        }
    }

    func create(
        worker: ServerProfile,
        provider: AgentKind,
        label: String
    ) async throws -> ProviderAccountProfile {
        let label = try validatedLabel(label)
        let result = try await runCommand(
            SSHCommandBuilder.providerAccountCreateConfiguration(
                for: worker,
                provider: provider,
                label: label
            )
        )
        guard result.exitCode == 0 else {
            if String(decoding: result.standardError, as: UTF8.self)
                .contains("Stop every legacy \(provider.rawValue) task") {
                throw ProviderAccountServiceError.legacyTasksRunning(provider)
            }
            throw ProviderAccountServiceError.commandFailed
        }
        let accounts = try ProviderAccountProtocol.parse(
            result.standardOutput,
            expectedProvider: provider
        )
        guard accounts.count == 1, let account = accounts.first else {
            throw ProviderAccountServiceError.invalidResponse
        }
        upsert(account, workerID: worker.id)
        errors[worker.id] = nil
        return account
    }

    func importDefault(
        worker: ServerProfile,
        provider: AgentKind,
        label: String
    ) async throws -> ProviderAccountProfile {
        let label = try validatedLabel(label)
        let result = try await runCommand(
            SSHCommandBuilder.providerAccountImportDefaultConfiguration(
                for: worker,
                provider: provider,
                label: label
            )
        )
        guard result.exitCode == 0 else {
            throw ProviderAccountServiceError.commandFailed
        }
        let accounts = try ProviderAccountProtocol.parse(
            result.standardOutput,
            expectedProvider: provider
        )
        guard accounts.count == 1, let account = accounts.first else {
            throw ProviderAccountServiceError.invalidResponse
        }
        upsert(account, workerID: worker.id)
        errors[worker.id] = nil
        return account
    }

    @discardableResult
    func rename(
        worker: ServerProfile,
        account: ProviderAccountProfile,
        label: String
    ) async throws -> ProviderAccountProfile {
        let label = try validatedLabel(label)
        return try await mutate(
            worker: worker,
            account: account,
            configuration: SSHCommandBuilder.providerAccountRenameConfiguration(
                for: worker,
                account: account,
                label: label
            )
        )
    }

    @discardableResult
    func refreshStatus(
        worker: ServerProfile,
        account: ProviderAccountProfile
    ) async throws -> ProviderAccountProfile {
        try await mutate(
            worker: worker,
            account: account,
            configuration: SSHCommandBuilder.providerAccountStatusConfiguration(
                for: worker,
                account: account
            )
        )
    }

    private func mutate(
        worker: ServerProfile,
        account: ProviderAccountProfile,
        configuration: SSHLaunchConfiguration
    ) async throws -> ProviderAccountProfile {
        let key = ProviderAccountKey(
            workerID: worker.id,
            provider: account.provider,
            accountID: account.accountID
        )
        guard mutatingAccounts.insert(key).inserted else {
            throw ProviderAccountServiceError.commandFailed
        }
        defer { mutatingAccounts.remove(key) }
        let result = try await runCommand(configuration)
        guard result.exitCode == 0 else {
            throw ProviderAccountServiceError.commandFailed
        }
        let accounts = try ProviderAccountProtocol.parse(
            result.standardOutput,
            expectedProvider: account.provider,
            expectedAccountID: account.accountID
        )
        guard accounts.count == 1, let updated = accounts.first else {
            throw ProviderAccountServiceError.invalidResponse
        }
        upsert(updated, workerID: worker.id)
        errors[worker.id] = nil
        return updated
    }

    private func validatedLabel(_ value: String) throws -> String {
        let label = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 100,
              !label.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ProviderAccountServiceError.invalidLabel
        }
        return label
    }

    private func upsert(_ account: ProviderAccountProfile, workerID: UUID) {
        var profiles = profilesByWorker[workerID] ?? []
        profiles.removeAll { $0.routeKey == account.routeKey }
        profiles.append(account)
        profilesByWorker[workerID] = profiles.sorted(by: profileSort)
    }

    private func replaceProfiles(
        _ accounts: [ProviderAccountProfile],
        provider: AgentKind,
        workerID: UUID
    ) {
        let retained = (profilesByWorker[workerID] ?? []).filter {
            $0.provider != provider
        }
        profilesByWorker[workerID] = (retained + accounts).sorted(by: profileSort)
    }

    private func profileSort(
        _ lhs: ProviderAccountProfile,
        _ rhs: ProviderAccountProfile
    ) -> Bool {
        if lhs.provider != rhs.provider {
            return lhs.provider.rawValue < rhs.provider.rawValue
        }
        let labelOrder = lhs.label.localizedStandardCompare(rhs.label)
        if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
        return lhs.accountID.rawValue < rhs.accountID.rawValue
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? ProviderAccountServiceError.commandFailed.localizedDescription
    }
}
