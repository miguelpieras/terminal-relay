import Foundation
@testable import TerminalRelay

enum TranscriptPerformanceFixtures {
    static let oneMiB = 1_048_576

    static func messages(count: Int, totalBytes: Int) -> [ConversationItem] {
        precondition(count > 0)
        let base = totalBytes / count
        let remainder = totalBytes % count
        return (0..<count).map { index in
            let byteCount = base + (index < remainder ? 1 : 0)
            return .message(
                ChatMessage(
                    id: "fixture-message-\(index)",
                    role: index.isMultiple(of: 5) ? .user : .assistant,
                    text: uniqueText(byteCount: byteCount, itemIndex: index),
                    occurredAt: Int64(index)
                )
            )
        }
    }

    /// A maximum retained transcript that exercises the real production row
    /// mix without accidentally making every bounded tile share one Markdown
    /// cache key. It remains exactly 1,000 items / 8 MiB: replacing messages
    /// with code, tool, and diff records preserves each replaced item's bytes.
    static let mixedMaximumTranscript: [ConversationItem] = {
        let largeMessageBytes = 512 * 1_024
        var items = messages(
            count: 999,
            totalBytes: (8 * oneMiB) - largeMessageBytes
        )
        items.insert(
            .message(
                ChatMessage(
                    id: "fixture-large-message",
                    role: .assistant,
                    text: uniqueText(
                        byteCount: largeMessageBytes,
                        itemIndex: 10_000
                    ),
                    occurredAt: 500
                )
            ),
            at: 500
        )

        for index in [251, 751] {
            guard case .message(var message) = items[index] else { continue }
            let text = message.text
            message.contents = [
                MessageContent(
                    id: "\(message.id):content:0",
                    kind: .code,
                    text: text,
                    language: "text"
                )
            ]
            items[index] = .message(message)
        }

        if case .message(let replaced) = items[333] {
            items[333] = .tool(
                ToolActivity(
                    id: "fixture-tool-333",
                    turnID: "fixture-turn-333",
                    kind: .shell,
                    title: "Fixture command",
                    status: .completed,
                    input: nil,
                    output: replaced.text,
                    errorMessage: nil,
                    durationMilliseconds: 1,
                    exitCode: 0,
                    occurredAt: 333,
                    isTruncated: false,
                    originalByteCount: nil
                )
            )
        }
        if case .message(let replaced) = items[667] {
            items[667] = .diff(
                ChatDiff(
                    id: "fixture-diff-667",
                    turnID: "fixture-turn-667",
                    path: "Fixture.swift",
                    unifiedDiff: replaced.text,
                    occurredAt: 667,
                    isTruncated: false
                )
            )
        }
        return items
    }()

    private static func uniqueText(
        byteCount: Int,
        itemIndex: Int
    ) -> String {
        guard byteCount > 0 else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(byteCount)
        var segment = 0
        while bytes.count < byteCount {
            let chunk = String(
                format: "item-%04d-segment-%04d viewport bounded text ",
                itemIndex,
                segment
            ).utf8
            let remaining = byteCount - bytes.count
            bytes.append(contentsOf: chunk.prefix(remaining))
            segment += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static let newlineFree512KiB = String(repeating: "z", count: 512 * 1_024)

    static let nearMaximumDiff = String(
        repeating: "+fixture value\n",
        count: (oneMiB - 4_096) / 15
    )

    static let nearMaximumToolOutput = String(
        repeating: "o",
        count: oneMiB - 4_096
    )

    static let historyPrepend: [ConversationItem] = messages(
        count: 100,
        totalBytes: 100 * 128
    )

    static let tenSecondDeltas: [String] = Array(
        repeating: String(repeating: "d", count: 1_024),
        count: Int(ceil(10.0 / 0.033))
    )
}
