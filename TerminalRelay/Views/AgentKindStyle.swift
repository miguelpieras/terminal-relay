import SwiftUI

extension AgentKind {
    var tint: Color {
        switch self {
        case .codex: .blue
        case .claude: .orange
        }
    }
}
