import OSLog

enum TranscriptPerformance {
    private static let signposter = OSSignposter(
        subsystem: "com.mpieras.TerminalRelay",
        category: "transcript-performance"
    )

    static func measureStoreApply<Result>(_ body: () throws -> Result) rethrows -> Result {
        let state = signposter.beginInterval("TranscriptStoreApply")
        defer { signposter.endInterval("TranscriptStoreApply", state) }
        return try body()
    }

    static func measureProjection<Result>(_ body: () -> Result) -> Result {
        let state = signposter.beginInterval("TranscriptProjection")
        defer { signposter.endInterval("TranscriptProjection", state) }
        return body()
    }

    static func measureTableMutation<Result>(_ body: () -> Result) -> Result {
        let state = signposter.beginInterval("TranscriptTableMutation")
        defer { signposter.endInterval("TranscriptTableMutation", state) }
        return body()
    }

    static func measureRowConfigure<Result>(_ body: () -> Result) -> Result {
        let state = signposter.beginInterval("TranscriptRowConfigure")
        defer { signposter.endInterval("TranscriptRowConfigure", state) }
        return body()
    }

    /// Numeric counters only. Never add transcript text, IDs, paths, command
    /// strings, worker identities, or any other user-controlled value here.
    static func emitCounters(
        queuedTransportBytes: Int = 0,
        changedRows: Int = 0,
        mountedRows: Int = 0,
        measuredRows: Int = 0
    ) {
        signposter.emitEvent(
            "TranscriptCounters",
            "queued=\(queuedTransportBytes, privacy: .public) changed=\(changedRows, privacy: .public) mounted=\(mountedRows, privacy: .public) measured=\(measuredRows, privacy: .public)"
        )
    }
}
