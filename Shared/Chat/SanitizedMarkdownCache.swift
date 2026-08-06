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

    // An 8 MiB transcript made entirely of newlines is split by the 256-line
    // row bound before it reaches the 4 KiB byte bound (roughly 33k rows).
    // Keep enough entry capacity for that worst-case shape; the cost limit
    // remains the actual memory ceiling.
    nonisolated static let defaultCountLimit = 40_000
    nonisolated static let defaultTotalCostLimit = 96 * 1_024 * 1_024

    private let sanitizedStorage = NSCache<NSString, NSString>()

    #if os(macOS)
    private final class PreparedBox: NSObject {
        let value: PreparedMarkdown

        init(_ value: PreparedMarkdown) {
            self.value = value
        }
    }

    private let preparedStorage = NSCache<NSString, PreparedBox>()
    private var inFlight: [String: Task<PreparedMarkdown, Never>] = [:]
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

    /// Returns a cache hit directly or prepares a miss on a detached task.
    /// Concurrent requests for the same row share one preparation.
    func preparedMarkdown(
        raw: String,
        priority: TaskPriority = .userInitiated
    ) async -> PreparedMarkdown {
        if let cached = lookupPrepared(raw: raw) {
            return cached
        }
        if let existing = inFlight[raw] {
            return await existing.value
        }

        let task = Task { @MainActor in
            await PreparedMarkdownRenderer.prepareOffMain(raw, priority: priority)
        }
        inFlight[raw] = task
        let prepared = await task.value
        inFlight[raw] = nil
        preparationCount += 1
        preparedStorage.setObject(
            PreparedBox(prepared),
            forKey: raw as NSString,
            cost: raw.utf8.count + prepared.estimatedCacheCost
        )
        return prepared
    }
    #endif

    /// Prepares `texts` off the main thread and stores the results, returning
    /// once every text is cached or `budget` elapses, whichever comes first.
    /// Texts still in flight when the budget expires keep warming in the
    /// background and enter the cache when they finish.
    func warm(texts: [String], budget: Duration = .milliseconds(150)) async {
        let pending = texts.filter { text in
            guard !text.isEmpty else { return false }
            #if os(macOS)
            return lookupPrepared(raw: text) == nil
            #else
            return lookup(raw: text) == nil
            #endif
        }
        guard !pending.isEmpty else { return }

        let warmTask = Task(priority: .utility) { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                var active = 0
                while active < 2, let text = iterator.next() {
                    group.addTask(priority: .utility) {
                        await self?.prepareAndInsert(text, priority: .utility)
                    }
                    active += 1
                }
                while await group.next() != nil {
                    if let text = iterator.next() {
                        group.addTask(priority: .utility) {
                            await self?.prepareAndInsert(text, priority: .utility)
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
        items: some Sequence<ConversationItem>
    ) -> [String] {
        items.flatMap { item -> [String] in
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
