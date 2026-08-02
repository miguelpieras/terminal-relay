import Foundation

/// Main-actor cache of sanitized markdown sources keyed by raw text.
///
/// Sanitization always happens before insertion, so a cache hit is safe to
/// hand directly to the renderer. Hits let non-streaming rows parse
/// synchronously on their first layout pass, which gives every restored row
/// its final height on the first frame.
@MainActor
final class SanitizedMarkdownCache {
    static let shared = SanitizedMarkdownCache()

    private let storage = NSCache<NSString, NSString>()

    init(countLimit: Int = 300) {
        storage.countLimit = countLimit
    }

    func lookup(raw: String) -> String? {
        storage.object(forKey: raw as NSString) as String?
    }

    func insert(raw: String, sanitized: String) {
        storage.setObject(sanitized as NSString, forKey: raw as NSString)
    }

    /// Sanitizes `texts` off the main thread and stores the results, returning
    /// once every text is cached or `budget` elapses, whichever comes first.
    /// Texts still in flight when the budget expires keep warming in the
    /// background and enter the cache when they finish.
    func warm(texts: [String], budget: Duration = .milliseconds(150)) async {
        let pending = texts.filter { !$0.isEmpty && lookup(raw: $0) == nil }
        guard !pending.isEmpty else { return }

        let warmTask = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                var active = 0
                while active < 4, let text = iterator.next() {
                    group.addTask { await self?.sanitizeAndInsert(text) }
                    active += 1
                }
                while await group.next() != nil {
                    if let text = iterator.next() {
                        group.addTask { await self?.sanitizeAndInsert(text) }
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

    private func sanitizeAndInsert(_ text: String) async {
        let result = await MarkdownSafety.sanitizedSourceOffMain(text)
        insert(raw: text, sanitized: result.source)
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
            return message.contents.compactMap { content in
                switch content.kind {
                case .code, .imagePlaceholder:
                    return nil
                case .plainText, .generic:
                    return message.role == .user ? nil : content.text
                case .markdown:
                    return content.text
                }
            }
        }
    }
}
