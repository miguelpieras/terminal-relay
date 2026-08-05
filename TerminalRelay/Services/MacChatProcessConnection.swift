import Foundation

enum MacChatProcessConnectionError: LocalizedError, Equatable {
    case alreadyConnected
    case notConnected
    case launchFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .alreadyConnected:
            "The chat connection is already open."
        case .notConnected:
            "The chat connection is not open."
        case .launchFailed:
            "Terminal Relay could not start the secure chat connection."
        case .writeFailed:
            "Terminal Relay could not send data to the worker."
        }
    }
}

/// Owns one long-lived local process and its three independent standard streams.
///
/// The production caller launches `/usr/bin/ssh -T … chat-attach-v1`. Closing
/// this process detaches the local client; it does not invoke the worker's
/// exact-stop command.
final class MacChatProcessConnection {
    struct Callbacks {
        /// The receiver must invoke `consumed` exactly once after it has
        /// decoded or discarded the bytes. That acknowledgement is the
        /// stdout backpressure boundary.
        let receiveStandardOutput: (Data, @escaping @Sendable () -> Void) -> Void
        let receiveStandardError: (Data) -> Void
        let terminate: (Int32) -> Void
    }

    private final class Run {
        let id: UUID
        let process: Process
        let input: Pipe
        let output: Pipe
        let error: Pipe
        let callbacks: Callbacks
        var standardOutputEnded = false
        var standardErrorEnded = false
        var terminationStatus: Int32?
        var queuedStandardOutputBytes = 0
        var standardOutputPaused = false

        init(
            id: UUID,
            process: Process,
            input: Pipe,
            output: Pipe,
            error: Pipe,
            callbacks: Callbacks
        ) {
            self.id = id
            self.process = process
            self.input = input
            self.output = output
            self.error = error
            self.callbacks = callbacks
        }
    }

    private let lock = NSLock()
    private let callbackQueue = DispatchQueue(
        label: "com.mpieras.TerminalRelay.mac-chat-process-callbacks"
    )
    private let readerQueue = DispatchQueue(
        label: "com.mpieras.TerminalRelay.mac-chat-process-readers"
    )
    private var run: Run?
    static let standardOutputHighWaterBytes = 4 * 1_048_576
    static let standardOutputLowWaterBytes = 1 * 1_048_576

    var isConnected: Bool {
        lock.whileLocked { run?.process.isRunning == true }
    }

    var queuedStandardOutputByteCount: Int {
        lock.whileLocked { run?.queuedStandardOutputBytes ?? 0 }
    }

    func connect(
        configuration: SSHLaunchConfiguration,
        callbacks: Callbacks
    ) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let runID = UUID()

        process.executableURL = URL(fileURLWithPath: configuration.executable)
        process.arguments = configuration.arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        let candidate = Run(
            id: runID,
            process: process,
            input: input,
            output: output,
            error: error,
            callbacks: callbacks
        )
        let installed = lock.whileLocked { () -> Bool in
            guard run == nil else { return false }
            run = candidate
            return true
        }
        guard installed else {
            close(candidate)
            throw MacChatProcessConnectionError.alreadyConnected
        }

        installStandardOutputHandler(on: output.fileHandleForReading, runID: runID)
        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.readerQueue.async {
                self?.readAvailable(
                    from: handle,
                    standardError: true,
                    runID: runID
                )
            }
        }
        process.terminationHandler = { [weak self] process in
            self?.readerQueue.async {
                self?.finishReadingAfterProcessEnded(
                    runID: runID,
                    status: process.terminationStatus
                )
            }
        }

        do {
            try process.run()
        } catch {
            _ = takeRun(id: runID)
            close(candidate)
            throw MacChatProcessConnectionError.launchFailed
        }
    }

    func send(_ data: Data) throws {
        let handle = lock.whileLocked { run?.input.fileHandleForWriting }
        guard let handle else {
            throw MacChatProcessConnectionError.notConnected
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw MacChatProcessConnectionError.writeFailed
        }
    }

    func disconnect() {
        guard let active = lock.whileLocked({ run }) else { return }
        try? active.input.fileHandleForWriting.close()
        if active.process.isRunning {
            active.process.terminate()
        } else {
            processEnded(runID: active.id, status: active.process.terminationStatus)
        }
    }

    private func receive(_ data: Data, fromStandardError: Bool, runID: UUID) {
        if !fromStandardError {
            receiveStandardOutput(data, runID: runID)
            return
        }
        let callback = lock.whileLocked { () -> ((Data) -> Void)? in
            guard let run, run.id == runID else { return nil }
            return run.callbacks.receiveStandardError
        }
        if let callback {
            callbackQueue.async {
                callback(data)
            }
        }
    }

    private func receiveStandardOutput(_ data: Data, runID: UUID) {
        let callback = lock.whileLocked {
            () -> ((Data, @escaping @Sendable () -> Void) -> Void)? in
            guard let run, run.id == runID else { return nil }
            run.queuedStandardOutputBytes += data.count
            if run.queuedStandardOutputBytes >= Self.standardOutputHighWaterBytes,
               !run.standardOutputPaused {
                run.standardOutputPaused = true
                run.output.fileHandleForReading.readabilityHandler = nil
            }
            TranscriptPerformance.emitCounters(
                queuedTransportBytes: run.queuedStandardOutputBytes
            )
            return run.callbacks.receiveStandardOutput
        }
        guard let callback else { return }
        callbackQueue.async { [weak self] in
            callback(data) { [weak self] in
                self?.standardOutputConsumed(data.count, runID: runID)
            }
        }
    }

    private func standardOutputConsumed(_ byteCount: Int, runID: UUID) {
        let handle = lock.whileLocked { () -> FileHandle? in
            guard let run, run.id == runID else { return nil }
            run.queuedStandardOutputBytes = max(
                0,
                run.queuedStandardOutputBytes - byteCount
            )
            TranscriptPerformance.emitCounters(
                queuedTransportBytes: run.queuedStandardOutputBytes
            )
            guard run.standardOutputPaused,
                  run.queuedStandardOutputBytes <= Self.standardOutputLowWaterBytes,
                  !run.standardOutputEnded,
                  run.process.isRunning else {
                return nil
            }
            run.standardOutputPaused = false
            return run.output.fileHandleForReading
        }
        if let handle {
            installStandardOutputHandler(on: handle, runID: runID)
        }
    }

    private func installStandardOutputHandler(on handle: FileHandle, runID: UUID) {
        handle.readabilityHandler = { [weak self] handle in
            self?.readerQueue.async {
                self?.readAvailable(
                    from: handle,
                    standardError: false,
                    runID: runID
                )
            }
        }
    }

    private func readAvailable(
        from handle: FileHandle,
        standardError: Bool,
        runID: UUID
    ) {
        guard lock.whileLocked({ run?.id == runID }) else { return }
        let data = handle.availableData
        if data.isEmpty {
            streamEnded(standardError: standardError, runID: runID)
        } else {
            receive(
                data,
                fromStandardError: standardError,
                runID: runID
            )
        }
    }

    private func finishReadingAfterProcessEnded(runID: UUID, status: Int32) {
        guard let active = lock.whileLocked({ () -> Run? in
            guard let run, run.id == runID else { return nil }
            return run
        }) else {
            return
        }

        active.output.fileHandleForReading.readabilityHandler = nil
        active.error.fileHandleForReading.readabilityHandler = nil

        let remainingOutput = active.output.fileHandleForReading.readDataToEndOfFile()
        if !remainingOutput.isEmpty {
            receive(
                remainingOutput,
                fromStandardError: false,
                runID: runID
            )
        }
        streamEnded(standardError: false, runID: runID)

        let remainingError = active.error.fileHandleForReading.readDataToEndOfFile()
        if !remainingError.isEmpty {
            receive(
                remainingError,
                fromStandardError: true,
                runID: runID
            )
        }
        streamEnded(standardError: true, runID: runID)
        processEnded(runID: runID, status: status)
    }

    private func streamEnded(standardError: Bool, runID: UUID) {
        let finished = lock.whileLocked { () -> Run? in
            guard let run, run.id == runID else { return nil }
            if standardError {
                run.standardErrorEnded = true
            } else {
                run.standardOutputEnded = true
            }
            return takeFinishedRunIfReadyLocked(run)
        }
        complete(finished)
    }

    private func processEnded(runID: UUID, status: Int32) {
        let finished = lock.whileLocked { () -> Run? in
            guard let run, run.id == runID else { return nil }
            run.terminationStatus = status
            return takeFinishedRunIfReadyLocked(run)
        }
        complete(finished)
    }

    private func takeFinishedRunIfReadyLocked(_ candidate: Run) -> Run? {
        guard candidate.standardOutputEnded,
              candidate.standardErrorEnded,
              candidate.terminationStatus != nil,
              run === candidate else {
            return nil
        }
        run = nil
        return candidate
    }

    private func complete(_ finished: Run?) {
        guard let finished, let status = finished.terminationStatus else { return }
        close(finished)
        callbackQueue.async {
            finished.callbacks.terminate(status)
        }
    }

    private func takeRun(id: UUID) -> Run? {
        lock.whileLocked {
            guard let run, run.id == id else { return nil }
            self.run = nil
            return run
        }
    }

    private func close(_ run: Run) {
        run.output.fileHandleForReading.readabilityHandler = nil
        run.error.fileHandleForReading.readabilityHandler = nil
        run.process.terminationHandler = nil
        try? run.input.fileHandleForWriting.close()
        try? run.output.fileHandleForReading.close()
        try? run.error.fileHandleForReading.close()
    }
}

private extension NSLock {
    func whileLocked<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}
