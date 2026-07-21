import Foundation

enum AgentKind: String, CaseIterable, Codable, Hashable, Identifiable {
    case codex
    case claude

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }

    var defaultCommand: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        }
    }

    var systemImage: String {
        switch self {
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claude: "sparkles"
        }
    }
}
