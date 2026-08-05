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
                    text: String(repeating: "x", count: byteCount),
                    occurredAt: Int64(index)
                )
            )
        }
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
