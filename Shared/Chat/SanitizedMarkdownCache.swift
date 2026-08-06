import Foundation

/// Main-actor cache for the final Markdown work consumed by transcript rows.
///
/// On macOS, completed rows cache their fully prepared attributed text, not
/// merely sanitized Markdown source. A cache hit therefore performs no parse
/// and mounts as one `Text` node. The cache is bounded by estimated memory
/// cost while retaining enough entries for the client's complete 8 MiB text
/// budget when the transcript is projected into small scroll tiles.
@MainActor
final class SanitizedMarkdownCache {
    static let shared = SanitizedMarkdownCache()

    // An 8 MiB transcript made entirely of newlines reaches the 128-line row
    // bound before the 1 KiB byte bound (roughly 68k Markdown rows after
    // fence-continuation reserve). Count does not allocate storage eagerly;
    // the independent cost limit remains the actual memory ceiling.
    nonisolated static let defaultCountLimit = 75_000
    nonisolated static let defaultTotalCostLimit = 96 * 1_024 * 1_024

    private let sanitizedStorage = NSCache<NSString, NSString>()

    #if os(macOS)
    private final class PreparedBox: NSObject {
        let value: PreparedMarkdown

        init(_ value: PreparedMarkdown) {
            self.value = value
        }
    }

    private struct InFlightPreparation {
        let id: UUID
        let task: Task<PreparedMarkdown?, Never>
        var waiters: Set<UUID>
    }

    private let preparedStorage = NSCache<NSString, PreparedBox>()
    private var inFlightPreparations: [String: InFlightPreparation] = [:]
    private(set) var preparationCount = 0
    #endif

    init(
        countLimit: Int = SanitizedMarkdownCache.defaultCountLimit,
        totalCostLimit: Int = SanitizedMarkdownCache.defaultTotalCostLimit
    ) {
        sanitizedStorage.countLimit = countLimit
        #if os(macOS)
        sanitizedStorage.totalCostLimit = min(totalCostLimit, 16 * 1_024 * 1_024)
        #else
        sanitizedStorage.totalCostLimit = totalCostLimit
        #endif
        #if os(macOS)
        preparedStorage.countLimit = countLimit
        preparedStorage.totalCostLimit = totalCostLimit
        #endif
    }

    func lookup(raw: String) -> String? {
        #if os(macOS)
        if let prepared = lookupPrepared(raw: raw) {
            return prepared.sanitizedSource
        }
        #endif
        return sanitizedStorage.object(forKey: raw as NSString) as String?
    }

    func insert(raw: String, sanitized: String) {
        let cost = raw.utf8.count + sanitized.utf8.count + 128
        sanitizedStorage.setObject(
            sanitized as NSString,
            forKey: raw as NSString,
            cost: cost
        )
    }

    #if os(macOS)
    func lookupPrepared(raw: String) -> PreparedMarkdown? {
        preparedStorage.object(forKey: raw as NSString)?.value
    }

    /// Returns a cache hit directly or prepares a miss through the process-wide
    /// cancellable gate. A recycled visible row can therefore withdraw queued
    /// work instead of leaving stale user-initiated preparation ahead of the
    /// current viewport.
    func preparedMarkdown(
        raw: String,
        priority: TaskPriority = .userInitiated
    ) async -> PreparedMarkdown? {
        guard !Task.isCancelled else { return nil }
        if let cached = lookupPrepared(raw: raw) {
            return cached
        }

        let waiterID = UUID()
        let preparationTask: Task<PreparedMarkdown?, Never>
        if var existing = inFlightPreparations[raw] {
            existing.waiters.insert(waiterID)
            inFlightPreparations[raw] = existing
            preparationTask = existing.task
        } else {
            let preparationID = UUID()
            let task = Task { @MainActor [weak self] in
                let prepared = await PreparedMarkdownRenderer.prepareOffMain(
                    raw,
                    priority: priority
                )
                return self?.completePreparation(
                    raw: raw,
                    id: preparationID,
                    prepared: prepared
                ) ?? prepared
            }
            inFlightPreparations[raw] = InFlightPreparation(
                id: preparationID,
                task: task,
                waiters: [waiterID]
            )
            preparationTask = task
        }

        return await withTaskCancellationHandler {
            let prepared = await preparationTask.value
            return Task.isCancelled ? nil : prepared
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPreparationWaiter(raw: raw, waiterID: waiterID)
            }
        }
    }

    private func completePreparation(
        raw: String,
        id: UUID,
        prepared: PreparedMarkdown?
    ) -> PreparedMarkdown? {
        guard inFlightPreparations[raw]?.id == id else {
            return lookupPrepared(raw: raw) ?? prepared
        }
        inFlightPreparations.removeValue(forKey: raw)
        if let cached = lookupPrepared(raw: raw) {
            return cached
        }
        guard let prepared else { return nil }
        preparationCount += 1
        preparedStorage.setObject(
            PreparedBox(prepared),
            forKey: raw as NSString,
            cost: raw.utf8.count + prepared.estimatedCacheCost
        )
        return prepared
    }

    private func cancelPreparationWaiter(raw: String, waiterID: UUID) {
        guard var preparation = inFlightPreparations[raw],
              preparation.waiters.remove(waiterID) != nil else { return }
        guard !preparation.waiters.isEmpty else {
            inFlightPreparations.removeValue(forKey: raw)
            preparation.task.cancel()
            return
        }
        inFlightPreparations[raw] = preparation
    }
    #endif

    /// Prepares `texts` off the main thread and stores the results, returning
    /// once every text is cached or `budget` elapses, whichever comes first.
    /// Texts still in flight when the budget expires keep warming in the
    /// background and enter the cache when they finish.
    func warm(
        texts: [String],
        budget: Duration = .milliseconds(150),
        priority: TaskPriority = .utility
    ) async {
        let pending = await Task.detached(priority: priority) {
            Self.uniqueNonemptyTexts(texts)
        }.value
        guard !Task.isCancelled, !pending.isEmpty else { return }

        // Batch orchestration is detached as well as parsing. A cache warm can
        // receive thousands of projected rows; iterating them and advancing a
        // task group on the UI actor would itself compete with scrolling.
        let warmTask = Task.detached(priority: priority) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                var active = 0
                while active < 2, let text = iterator.next() {
                    group.addTask(priority: priority) {
                        await self?.prepareAndInsert(text, priority: priority)
                    }
                    active += 1
                }
                while await group.next() != nil {
                    if let text = iterator.next() {
                        group.addTask(priority: priority) {
                            await self?.prepareAndInsert(text, priority: priority)
                        }
                    }
                }
            }
        }

        // Race completion against the budget without blocking on stragglers:
        // whichever side finishes first resumes the caller, and the warm task
        // keeps filling the cache in the background either way.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let gate = ResumeOnceGate(continuation)
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: budget)
                gate.resume()
            }
            Task { @MainActor in
                await warmTask.value
                deadline.cancel()
                gate.resume()
            }
        }
    }

    /// Cancellable viewport-priority warming. At most two row preparations
    /// are started at once; cancelling a superseded viewport band prevents
    /// the remaining offscreen rows from entering the global preparation
    /// queue. Work already parsing is allowed to finish and populate cache.
    func prefetch(
        texts: [String],
        priority: TaskPriority = .userInitiated
    ) async {
        let pending = await Task.detached(priority: priority) {
            Self.uniqueNonemptyTexts(texts)
        }.value
        guard !Task.isCancelled, !pending.isEmpty else { return }

        let prefetchTask = Task.detached(priority: priority) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                var active = 0
                while active < 2, let text = iterator.next() {
                    group.addTask(priority: priority) { [weak self] in
                        guard !Task.isCancelled else { return }
                        await self?.prepareAndInsert(text, priority: priority)
                    }
                    active += 1
                }
                while await group.next() != nil {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    if let text = iterator.next() {
                        group.addTask(priority: priority) { [weak self] in
                            guard !Task.isCancelled else { return }
                            await self?.prepareAndInsert(text, priority: priority)
                        }
                    }
                }
            }
        }
        await withTaskCancellationHandler {
            await prefetchTask.value
        } onCancel: {
            prefetchTask.cancel()
        }
    }

    nonisolated private static func uniqueNonemptyTexts(
        _ texts: [String]
    ) -> [String] {
        var seen = Set<String>()
        return texts.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    @MainActor
    private final class ResumeOnceGate {
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func prepareAndInsert(
        _ text: String,
        priority: TaskPriority
    ) async {
        #if os(macOS)
        _ = await preparedMarkdown(raw: text, priority: priority)
        #else
        let result = await MarkdownSafety.sanitizedSourceOffMain(text)
        insert(raw: text, sanitized: result.source)
        #endif
    }

    /// The exact strings the transcript renders through RichMarkdownView,
    /// oldest first. Must mirror ChatMessageView's content routing: code and
    /// image placeholders never hit the markdown renderer, and a user
    /// message's plain text renders as Text.
    nonisolated static func warmableTexts(
        items: some Sequence<ConversationItem>,
        suffixLimit: Int? = nil
    ) -> [String] {
        let values = Array(items)
        if let suffixLimit {
            guard suffixLimit > 0 else { return [] }
            var newestFirst: [String] = []
            newestFirst.reserveCapacity(suffixLimit)
            for item in values.reversed() {
                guard case .message(let message) = item,
                      !message.isStreaming else { continue }
                for content in message.contents.reversed() {
                    switch content.kind {
                    case .code, .imagePlaceholder:
                        continue
                    case .plainText, .generic:
                        guard message.role != .user else { continue }
                    case .markdown:
                        break
                    }
                    #if os(macOS)
                    let remaining = suffixLimit - newestFirst.count
                    let suffix = TranscriptTextProjection.markdownSegmentSuffix(
                        of: content.text,
                        limit: remaining
                    )
                    newestFirst.append(
                        contentsOf: suffix.reversed().map(\.renderedText)
                    )
                    #else
                    newestFirst.append(content.text)
                    #endif
                    if newestFirst.count == suffixLimit {
                        return Array(newestFirst.reversed())
                    }
                }
            }
            return Array(newestFirst.reversed())
        }

        return values.flatMap { item -> [String] in
            guard case .message(let message) = item, !message.isStreaming else {
                return []
            }
            return message.contents.flatMap { content -> [String] in
                switch content.kind {
                case .code, .imagePlaceholder:
                    return []
                case .plainText, .generic:
                    guard message.role != .user else { return [] }
                case .markdown:
                    break
                }
                #if os(macOS)
                return TranscriptTextProjection.markdownSegments(of: content.text)
                    .map(\.renderedText)
                #else
                // iOS still renders one RichMarkdownView for the original
                // content value, so its warm key must remain the full string.
                return [content.text]
                #endif
            }
        }
    }
}
