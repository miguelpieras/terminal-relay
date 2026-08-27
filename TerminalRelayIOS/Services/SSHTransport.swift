import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

enum SSHTransportError: LocalizedError {
    case invalidHostKey
    case hostKeyMismatch(expected: String, actual: String)
    case publicKeyAuthenticationUnavailable
    case invalidChannelType
    case connectionClosed
    case missingExitStatus
    case commandFailed(status: Int, message: String)
    case connection(String)

    var errorDescription: String? {
        switch self {
        case .invalidHostKey:
            "The worker presented an invalid SSH host key."
        case .hostKeyMismatch(let expected, let actual):
            "The worker host key did not match. Expected \(expected), received \(actual)."
        case .publicKeyAuthenticationUnavailable:
            "The worker did not accept the app's SSH public key."
        case .invalidChannelType:
            "The worker opened an unexpected SSH channel."
        case .connectionClosed:
            "The SSH connection closed before the operation completed."
        case .missingExitStatus:
            "The SSH command closed without reporting an exit status."
        case .commandFailed(let status, let message):
            message.isEmpty ? "The worker command failed with status \(status)." : message
        case .connection(let message):
            message
        }
    }
}

enum SSHExecOutputStream {
    case standardOutput
    case standardError
}

enum SSHStreamingExecEvent: Equatable, Sendable {
    case standardOutput(Data)
    case standardError(Data)
    case exitStatus(Int)
    case exitSignal(String)
}

enum SSHStreamingExecState: Equatable, Sendable {
    case connecting
    case connected
    case disconnected
    case failed(SSHStreamingExecFailure)
}

enum SSHStreamingExecFailure: Equatable, Sendable {
    case hostKey
    case authentication
    case connection

    static func classify(_ error: Error) -> SSHStreamingExecFailure {
        if let transportError = error as? SSHTransportError {
            switch transportError {
            case .invalidHostKey, .hostKeyMismatch:
                return .hostKey
            case .publicKeyAuthenticationUnavailable:
                return .authentication
            case .invalidChannelType, .connectionClosed, .missingExitStatus,
                 .commandFailed, .connection:
                return .connection
            }
        }
        if let sshError = error as? NIOSSHError,
           sshError.type == .invalidUserAuthSignature {
            return .authentication
        }
        return .connection
    }
}

typealias SSHExecCommandResult = (
    status: Int,
    standardOutput: Data,
    standardError: Data
)

struct SSHExecResultAccumulator {
    private var standardOutput = Data()
    private var standardError = Data()
    private var exitStatus: Int?
    private var didReceiveEOF = false

    mutating func append(_ data: Data, to stream: SSHExecOutputStream) {
        switch stream {
        case .standardOutput:
            standardOutput.append(data)
        case .standardError:
            standardError.append(data)
        }
    }

    mutating func recordExitStatus(_ status: Int) {
        if exitStatus == nil {
            exitStatus = status
        }
    }

    mutating func recordEOF() {
        didReceiveEOF = true
    }

    func resultIfComplete() -> Result<SSHExecCommandResult, Error>? {
        guard didReceiveEOF, let exitStatus else { return nil }
        return .success((exitStatus, standardOutput, standardError))
    }

    func resultAtChannelClose() -> Result<SSHExecCommandResult, Error> {
        guard let exitStatus else {
            return .failure(SSHTransportError.missingExitStatus)
        }
        return .success((exitStatus, standardOutput, standardError))
    }
}

private final class PinnedHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let expectedFingerprint: String

    init(expectedFingerprint: String) {
        self.expectedFingerprint = expectedFingerprint
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let actual = try Self.fingerprint(for: hostKey)
            guard actual == expectedFingerprint else {
                throw SSHTransportError.hostKeyMismatch(expected: expectedFingerprint, actual: actual)
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }

    private static func fingerprint(for publicKey: NIOSSHPublicKey) throws -> String {
        let fields = String(openSSHPublicKey: publicKey).split(separator: " ")
        guard fields.count == 2, let wireKey = Data(base64Encoded: String(fields[1])) else {
            throw SSHTransportError.invalidHostKey
        }
        let digest = Data(CryptoKit.SHA256.hash(data: wireKey))
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(digest)"
    }
}

private final class PrivateKeyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let privateKey: NIOSSHPrivateKey
    private var didOfferKey = false

    init(username: String, privateKey: NIOSSHPrivateKey) {
        self.username = username
        self.privateKey = privateKey
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !didOfferKey, availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHTransportError.publicKeyAuthenticationUnavailable)
            return
        }

        didOfferKey = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "ssh-connection",
                offer: .privateKey(.init(privateKey: privateKey))
            )
        )
    }
}

private final class SSHParentErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let onError: (Error) -> Void

    init(onError: @escaping (Error) -> Void) {
        self.onError = onError
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onError(error)
        context.close(promise: nil)
    }
}

private final class SSHExecChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let standardInput: Data?
    private var resultAccumulator = SSHExecResultAccumulator()
    private var completion: ((Result<SSHExecCommandResult, Error>) -> Void)?

    init(
        command: String,
        standardInput: Data?,
        completion: @escaping (Result<SSHExecCommandResult, Error>) -> Void
    ) {
        self.command = command
        self.standardInput = standardInput
        self.completion = completion
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            context.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false),
            promise: nil
        )
        guard let standardInput else { return }
        if standardInput.isEmpty {
            context.close(mode: .output, promise: nil)
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: standardInput.count)
        buffer.writeBytes(standardInput)
        let promise = context.eventLoop.makePromise(of: Void.self)
        promise.futureResult.whenComplete { result in
            switch result {
            case .success:
                context.close(mode: .output, promise: nil)
            case .failure(let error):
                context.fireErrorCaught(error)
            }
        }
        context.writeAndFlush(
            wrapOutboundOut(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer))
            ),
            promise: promise
        )
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }

        switch payload.type {
        case .channel:
            resultAccumulator.append(Data(bytes), to: .standardOutput)
        case .stdErr:
            resultAccumulator.append(Data(bytes), to: .standardError)
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            resultAccumulator.recordExitStatus(exit.exitStatus)
            finishIfComplete()
        } else if let channelEvent = event as? ChannelEvent, case .inputClosed = channelEvent {
            resultAccumulator.recordEOF()
            finishIfComplete()
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        finishAtChannelClose()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    private func finishAtChannelClose() {
        finish(resultAccumulator.resultAtChannelClose())
    }

    private func finishIfComplete() {
        guard let result = resultAccumulator.resultIfComplete() else { return }
        finish(result)
    }

    private func finish(_ result: Result<SSHExecCommandResult, Error>) {
        guard let completion else { return }
        self.completion = nil
        completion(result)
    }
}

private final class SSHExecOperation {
    private let profile: WorkerProfile
    private let privateKey: NIOSSHPrivateKey
    private let command: String
    private let standardInput: Data?
    private var group: MultiThreadedEventLoopGroup?
    private var parentChannel: Channel?
    private var childChannel: Channel?
    private var completion: ((Result<Data, Error>) -> Void)?
    private var isFinished = false

    init(
        profile: WorkerProfile,
        privateKey: NIOSSHPrivateKey,
        command: String,
        standardInput: Data?
    ) {
        self.profile = profile
        self.privateKey = privateKey
        self.command = command
        self.standardInput = standardInput
    }

    func start(completion: @escaping (Result<Data, Error>) -> Void) {
        self.completion = completion
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let userAuth = PrivateKeyAuthenticationDelegate(username: profile.username, privateKey: privateKey)
        let serverAuth = PinnedHostKeyDelegate(expectedFingerprint: profile.expectedHostKeyFingerprint)
        let bootstrap = ClientBootstrap(group: group)
            // Under NIO's default 10s the connect failure lands exactly on
            // the coordinator's 10s attach grace; 8s keeps a dead tunnel
            // attributed to the connect, not the watchdog.
            .connectTimeout(.seconds(8))
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHParentErrorHandler { [weak self] error in self?.finish(.failure(error)) }
                    )
                }
            }

        bootstrap.connect(host: profile.host, port: profile.port).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                guard let self, !self.isFinished else {
                    channel.close(promise: nil)
                    return
                }
                self.parentChannel = channel
                self.openExecChannel(on: channel)
            case .failure(let error):
                self?.finish(.failure(error))
            }
        }
    }

    private func openExecChannel(on parent: Channel) {
        parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                finish(.failure(error))
            case .success(let sshHandler):
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] child, type in
                    guard let self, type == .session else {
                        return child.eventLoop.makeFailedFuture(SSHTransportError.invalidChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SSHExecChannelHandler(
                                command: self.command,
                                standardInput: self.standardInput
                            ) { [weak self] result in
                                self?.handleCommandResult(result)
                            }
                        )
                    }
                }
                promise.futureResult.whenComplete { [weak self] result in
                    switch result {
                    case .success(let child):
                        guard let self, !self.isFinished else {
                            child.close(promise: nil)
                            return
                        }
                        self.childChannel = child
                    case .failure(let error): self?.finish(.failure(error))
                    }
                }
            }
        }
    }

    private func handleCommandResult(_ result: Result<SSHExecCommandResult, Error>) {
        switch result {
        case .failure(let error):
            finish(.failure(error))
        case .success(let (status, stdout, stderr)):
            if status == 0 {
                finish(.success(stdout))
            } else {
                let message = String(decoding: stderr, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                finish(.failure(SSHTransportError.commandFailed(status: status, message: message)))
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !isFinished else { return }
        isFinished = true

        childChannel?.close(promise: nil)
        parentChannel?.close(promise: nil)
        childChannel = nil
        parentChannel = nil

        let completion = self.completion
        self.completion = nil
        if let group {
            self.group = nil
            group.shutdownGracefully { _ in completion?(result) }
        } else {
            completion?(result)
        }
    }
}

final class SSHWorkerClient {
    private let identityStore: SSHIdentityStore

    init(identityStore: SSHIdentityStore = SSHIdentityStore()) {
        self.identityStore = identityStore
    }

    func execute(
        _ command: String,
        on profile: WorkerProfile,
        standardInput: Data? = nil
    ) async throws -> Data {
        let privateKey = try identityStore.loadOrCreatePrivateKey()
        return try await execute(
            command,
            on: profile,
            privateKey: privateKey,
            standardInput: standardInput
        )
    }

    func execute(
        _ command: String,
        on profile: WorkerProfile,
        privateKey: NIOSSHPrivateKey,
        standardInput: Data? = nil
    ) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let operation = SSHExecOperation(
                profile: profile,
                privateKey: privateKey,
                command: command,
                standardInput: standardInput
            )
            operation.start { [operation] result in
                _ = operation
                continuation.resume(with: result)
            }
        }
    }
}

private final class SSHStreamingExecChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let onEvent: (SSHStreamingExecEvent) -> Void
    private let onReady: () -> Void
    private let onClosed: (Error?) -> Void
    private var didClose = false

    init(
        command: String,
        onEvent: @escaping (SSHStreamingExecEvent) -> Void,
        onReady: @escaping () -> Void,
        onClosed: @escaping (Error?) -> Void
    ) {
        self.command = command
        self.onEvent = onEvent
        self.onReady = onReady
        self.onClosed = onClosed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            context.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: "LANG",
                value: "en_US.UTF-8"
            ),
            promise: nil
        )
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false),
            promise: nil
        )
        onReady()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else {
            return
        }

        switch payload.type {
        case .channel:
            onEvent(.standardOutput(Data(bytes)))
        case .stdErr:
            onEvent(.standardError(Data(bytes)))
        default:
            break
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            onEvent(.exitStatus(exit.exitStatus))
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            onEvent(.exitSignal(signal.signalName))
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeOnce(error: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        closeOnce(error: error)
        context.close(promise: nil)
    }

    private func closeOnce(error: Error?) {
        guard !didClose else { return }
        didClose = true
        onClosed(error)
    }
}

/// One interactive SSH `exec` channel without a pseudo-terminal.
///
/// Calls to `send` are serialized on the child channel's event loop. Closing this
/// local connection never issues a remote stop command, so a chat broker remains
/// available for a cursor-based foreground reconnect.
final class SSHStreamingExecConnection {
    private struct LifecycleState {
        var group: MultiThreadedEventLoopGroup?
        var parentChannel: Channel?
        var childChannel: Channel?
        var didStart = false
        var didRequestExec = false
        var didReportConnected = false
        var isFinished = false
    }

    private struct Resources {
        let group: MultiThreadedEventLoopGroup?
        let parentChannel: Channel?
        let childChannel: Channel?
    }

    private let profile: WorkerProfile
    private let privateKey: NIOSSHPrivateKey
    private let command: String
    private let onEvent: (SSHStreamingExecEvent) -> Void
    private let onStateChange: (SSHStreamingExecState) -> Void
    private let lifecycleLock = NSLock()
    private let callbackQueue = DispatchQueue(
        label: "TerminalRelay.SSHStreamingExecConnection.callback"
    )
    private var lifecycle = LifecycleState()

    init(
        profile: WorkerProfile,
        privateKey: NIOSSHPrivateKey,
        command: String,
        onEvent: @escaping (SSHStreamingExecEvent) -> Void,
        onStateChange: @escaping (SSHStreamingExecState) -> Void
    ) {
        self.profile = profile
        self.privateKey = privateKey
        self.command = command
        self.onEvent = onEvent
        self.onStateChange = onStateChange
    }

    func connect() {
        let group: MultiThreadedEventLoopGroup? = withLifecycleState { state in
            guard !state.didStart, !state.isFinished else { return nil }
            state.didStart = true
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            state.group = group
            enqueueStateChange(.connecting)
            return group
        }
        guard let group else { return }

        let userAuth = PrivateKeyAuthenticationDelegate(
            username: profile.username,
            privateKey: privateKey
        )
        let serverAuth = PinnedHostKeyDelegate(
            expectedFingerprint: profile.expectedHostKeyFingerprint
        )
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(8))
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(
                            .init(
                                userAuthDelegate: userAuth,
                                serverAuthDelegate: serverAuth
                            )
                        ),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHParentErrorHandler { [weak self] error in
                            self?.finish(error: error)
                        }
                    )
                }
            }

        bootstrap.connect(host: profile.host, port: profile.port).whenComplete {
            [weak self] result in
            switch result {
            case .success(let channel):
                guard let self, self.registerParentChannel(channel) else {
                    channel.close(promise: nil)
                    return
                }
                self.openStreamingChannel(on: channel)
            case .failure(let error):
                self?.finish(error: error)
            }
        }
    }

    func send(
        _ data: Data,
        completion: @escaping (Result<Void, Error>) -> Void = { _ in }
    ) {
        guard !data.isEmpty else {
            completion(.success(()))
            return
        }
        guard let childChannel = withLifecycleState({ state -> Channel? in
            guard !state.isFinished, state.didReportConnected else { return nil }
            return state.childChannel
        }) else {
            completion(.failure(SSHTransportError.connectionClosed))
            return
        }

        childChannel.eventLoop.execute { [weak self] in
            guard let self, self.isCurrentChildChannel(childChannel) else {
                completion(.failure(SSHTransportError.connectionClosed))
                return
            }
            var buffer = childChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let promise = childChannel.eventLoop.makePromise(of: Void.self)
            promise.futureResult.whenComplete(completion)
            childChannel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                promise: promise
            )
        }
    }

    func disconnect() {
        finish(error: nil)
    }

    private func openStreamingChannel(on parent: Channel) {
        parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete {
            [weak self] result in
            guard let self, self.isCurrentParentChannel(parent) else { return }
            switch result {
            case .failure(let error):
                finish(error: error)
            case .success(let sshHandler):
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) {
                    [weak self] child, type in
                    guard let self, type == .session else {
                        return child.eventLoop.makeFailedFuture(
                            SSHTransportError.invalidChannelType
                        )
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SSHStreamingExecChannelHandler(
                                command: self.command,
                                onEvent: { [weak self] event in
                                    self?.enqueueEvent(event)
                                },
                                onReady: { [weak self] in
                                    self?.recordExecRequested()
                                },
                                onClosed: { [weak self] error in
                                    self?.finish(error: error)
                                }
                            )
                        )
                    }
                }
                promise.futureResult.whenComplete { [weak self] result in
                    switch result {
                    case .success(let child):
                        guard let self, self.registerChildChannel(child) else {
                            child.close(promise: nil)
                            return
                        }
                        self.reportConnectedIfReady()
                    case .failure(let error):
                        self?.finish(error: error)
                    }
                }
            }
        }
    }

    private func finish(error: Error?) {
        let resources: Resources? = withLifecycleState { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            let resources = Resources(
                group: state.group,
                parentChannel: state.parentChannel,
                childChannel: state.childChannel
            )
            state.group = nil
            state.parentChannel = nil
            state.childChannel = nil
            if let error {
                enqueueStateChange(.failed(SSHStreamingExecFailure.classify(error)))
            } else {
                enqueueStateChange(.disconnected)
            }
            return resources
        }
        guard let resources else { return }

        resources.childChannel?.close(promise: nil)
        resources.parentChannel?.close(promise: nil)
        resources.group?.shutdownGracefully { _ in }
    }

    private func registerParentChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            guard !state.isFinished else { return false }
            state.parentChannel = channel
            return true
        }
    }

    private func registerChildChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            guard !state.isFinished else { return false }
            state.childChannel = channel
            return true
        }
    }

    private func recordExecRequested() {
        withLifecycleState { state in
            guard !state.isFinished else { return }
            state.didRequestExec = true
        }
        reportConnectedIfReady()
    }

    private func reportConnectedIfReady() {
        let shouldReport = withLifecycleState { state in
            guard !state.isFinished,
                  state.childChannel != nil,
                  state.didRequestExec,
                  !state.didReportConnected else {
                return false
            }
            state.didReportConnected = true
            return true
        }
        if shouldReport {
            enqueueStateChange(.connected)
        }
    }

    private func isCurrentParentChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            !state.isFinished && state.parentChannel === channel
        }
    }

    private func isCurrentChildChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            !state.isFinished && state.childChannel === channel
        }
    }

    private func enqueueEvent(_ event: SSHStreamingExecEvent) {
        let onEvent = self.onEvent
        callbackQueue.async {
            onEvent(event)
        }
    }

    private func enqueueStateChange(_ state: SSHStreamingExecState) {
        let onStateChange = self.onStateChange
        callbackQueue.async {
            onStateChange(state)
        }
    }

    private func withLifecycleState<T>(
        _ body: (inout LifecycleState) -> T
    ) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body(&lifecycle)
    }

    deinit {
        disconnect()
    }
}

enum TerminalConnectionState: Equatable {
    case connecting
    case connected
    case disconnected
    case failed(String)
    case ended(String)
}

private final class SSHTerminalChannelHandler: ChannelInboundHandler {
    typealias InboundIn = SSHChannelData

    private let command: String
    private let initialSize: (columns: Int, rows: Int)
    private let onOutput: (Data) -> Void
    private let onReady: () -> Void
    private let onClosed: (Error?) -> Void

    init(
        command: String,
        initialSize: (columns: Int, rows: Int),
        onOutput: @escaping (Data) -> Void,
        onReady: @escaping () -> Void,
        onClosed: @escaping (Error?) -> Void
    ) {
        self.command = command
        self.initialSize = initialSize
        self.onOutput = onOutput
        self.onReady = onReady
        self.onClosed = onClosed
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure {
            context.fireErrorCaught($0)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        let pty = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: false,
            term: "xterm-256color",
            terminalCharacterWidth: initialSize.columns,
            terminalRowHeight: initialSize.rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        context.triggerUserOutboundEvent(pty, promise: nil)
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "en_US.UTF-8"),
            promise: nil
        )
        context.triggerUserOutboundEvent(
            SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false),
            promise: nil
        )
        onReady()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let payload = unwrapInboundIn(data)
        guard case .byteBuffer(var buffer) = payload.data,
              let bytes = buffer.readBytes(length: buffer.readableBytes),
              !bytes.isEmpty else {
            return
        }
        onOutput(Data(bytes))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let exit = event as? SSHChannelRequestEvent.ExitStatus {
            onOutput(Data("\r\n[Agent exited with status \(exit.exitStatus)]\r\n".utf8))
        } else if let signal = event as? SSHChannelRequestEvent.ExitSignal {
            onOutput(Data("\r\n[Agent closed: \(signal.signalName)]\r\n".utf8))
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClosed(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        onClosed(error)
        context.close(promise: nil)
    }
}

final class SSHTerminalConnection {
    private struct LifecycleState {
        var group: MultiThreadedEventLoopGroup?
        var parentChannel: Channel?
        var childChannel: Channel?
        var didStart = false
        var isFinished = false
        var desiredSize: (columns: Int, rows: Int)
    }

    private struct Resources {
        let group: MultiThreadedEventLoopGroup?
        let parentChannel: Channel?
        let childChannel: Channel?
    }

    private let profile: WorkerProfile
    private let privateKey: NIOSSHPrivateKey
    private let command: String
    private let onOutput: (Data) -> Void
    private let onStateChange: (TerminalConnectionState) -> Void
    private let lifecycleLock = NSLock()
    private let stateCallbackQueue = DispatchQueue(label: "TerminalRelay.SSHTerminalConnection.state")

    private var lifecycle: LifecycleState

    init(
        profile: WorkerProfile,
        privateKey: NIOSSHPrivateKey,
        command: String,
        initialSize: (columns: Int, rows: Int),
        onOutput: @escaping (Data) -> Void,
        onStateChange: @escaping (TerminalConnectionState) -> Void
    ) {
        self.profile = profile
        self.privateKey = privateKey
        self.command = command
        self.onOutput = onOutput
        self.onStateChange = onStateChange
        self.lifecycle = LifecycleState(desiredSize: initialSize)
    }

    func connect() {
        let group: MultiThreadedEventLoopGroup? = withLifecycleState { state in
            guard !state.didStart, !state.isFinished else { return nil }
            state.didStart = true
            let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            state.group = group
            enqueueStateChange(.connecting)
            return group
        }
        guard let group else { return }

        let userAuth = PrivateKeyAuthenticationDelegate(username: profile.username, privateKey: privateKey)
        let serverAuth = PinnedHostKeyDelegate(expectedFingerprint: profile.expectedHostKeyFingerprint)
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.seconds(8))
            .channelInitializer { [weak self] channel in
                channel.eventLoop.makeCompletedFuture {
                    let sshHandler = NIOSSHHandler(
                        role: .client(.init(userAuthDelegate: userAuth, serverAuthDelegate: serverAuth)),
                        allocator: channel.allocator,
                        inboundChildChannelInitializer: nil
                    )
                    try channel.pipeline.syncOperations.addHandler(sshHandler)
                    try channel.pipeline.syncOperations.addHandler(
                        SSHParentErrorHandler { [weak self] error in self?.finish(error: error) }
                    )
                }
            }

        bootstrap.connect(host: profile.host, port: profile.port).whenComplete { [weak self] result in
            switch result {
            case .success(let channel):
                guard let self, self.registerParentChannel(channel) else {
                    channel.close(promise: nil)
                    return
                }
                self.openTerminalChannel(on: channel)
            case .failure(let error):
                self?.finish(error: error)
            }
        }
    }

    func send(_ data: Data) {
        guard let childChannel = withLifecycleState({ state in
            state.isFinished ? nil : state.childChannel
        }) else { return }
        childChannel.eventLoop.execute {
            guard self.isCurrentChildChannel(childChannel) else { return }
            var buffer = childChannel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            childChannel.writeAndFlush(
                SSHChannelData(type: .channel, data: .byteBuffer(buffer)),
                promise: nil
            )
        }
    }

    func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        let childChannel = withLifecycleState { state -> Channel? in
            guard !state.isFinished else { return nil }
            state.desiredSize = (columns, rows)
            return state.childChannel
        }
        if let childChannel {
            sendLatestResize(on: childChannel)
        }
    }

    func disconnect() {
        finish(error: nil)
    }

    private func openTerminalChannel(on parent: Channel) {
        parent.pipeline.handler(type: NIOSSHHandler.self).whenComplete { [weak self] result in
            guard let self, self.isCurrentParentChannel(parent) else { return }
            switch result {
            case .failure(let error):
                finish(error: error)
            case .success(let sshHandler):
                let promise = parent.eventLoop.makePromise(of: Channel.self)
                sshHandler.createChannel(promise, channelType: .session) { [weak self] child, type in
                    guard let self,
                          type == .session,
                          let initialSize = self.desiredSizeIfActive() else {
                        return child.eventLoop.makeFailedFuture(SSHTransportError.invalidChannelType)
                    }
                    return child.eventLoop.makeCompletedFuture {
                        try child.pipeline.syncOperations.addHandler(
                            SSHTerminalChannelHandler(
                                command: self.command,
                                initialSize: initialSize,
                                onOutput: self.onOutput,
                                onReady: { [weak self] in self?.markReady() },
                                onClosed: { [weak self] error in self?.finish(error: error) }
                            )
                        )
                    }
                }
                promise.futureResult.whenComplete { [weak self] result in
                    switch result {
                    case .success(let child):
                        guard let self, self.registerChildChannel(child) else {
                            child.close(promise: nil)
                            return
                        }
                        self.sendLatestResize(on: child)
                    case .failure(let error): self?.finish(error: error)
                    }
                }
            }
        }
    }

    private func finish(error: Error?) {
        let resources: Resources? = withLifecycleState { state in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            let resources = Resources(
                group: state.group,
                parentChannel: state.parentChannel,
                childChannel: state.childChannel
            )
            state.group = nil
            state.parentChannel = nil
            state.childChannel = nil
            if let error {
                enqueueStateChange(.failed(error.localizedDescription))
            } else {
                enqueueStateChange(.disconnected)
            }
            return resources
        }
        guard let resources else { return }

        resources.childChannel?.close(promise: nil)
        resources.parentChannel?.close(promise: nil)
        resources.group?.shutdownGracefully { _ in }
    }

    private func registerParentChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            guard !state.isFinished else { return false }
            state.parentChannel = channel
            return true
        }
    }

    private func registerChildChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            guard !state.isFinished else { return false }
            state.childChannel = channel
            return true
        }
    }

    private func isCurrentParentChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            !state.isFinished && state.parentChannel === channel
        }
    }

    private func isCurrentChildChannel(_ channel: Channel) -> Bool {
        withLifecycleState { state in
            !state.isFinished && state.childChannel === channel
        }
    }

    private func desiredSizeIfActive() -> (columns: Int, rows: Int)? {
        withLifecycleState { state in
            state.isFinished ? nil : state.desiredSize
        }
    }

    private func markReady() {
        withLifecycleState { state in
            guard !state.isFinished else { return }
            enqueueStateChange(.connected)
        }
    }

    private func sendLatestResize(on childChannel: Channel) {
        childChannel.eventLoop.execute { [weak self] in
            guard let self else { return }
            let size: (columns: Int, rows: Int)? = self.withLifecycleState { state in
                guard !state.isFinished, state.childChannel === childChannel else { return nil }
                return state.desiredSize
            }
            guard let size else { return }

            childChannel.triggerUserOutboundEvent(
                SSHChannelRequestEvent.WindowChangeRequest(
                    terminalCharacterWidth: size.columns,
                    terminalRowHeight: size.rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0
                ),
                promise: nil
            )
        }
    }

    private func enqueueStateChange(_ state: TerminalConnectionState) {
        let onStateChange = self.onStateChange
        stateCallbackQueue.async {
            onStateChange(state)
        }
    }

    private func withLifecycleState<T>(_ body: (inout LifecycleState) -> T) -> T {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return body(&lifecycle)
    }

    deinit {
        disconnect()
    }
}
