import SwiftUI

struct AgentBrandIcon: View {
    let kind: AgentKind
    var size: CGFloat = 20

    var body: some View {
        Image(kind.brandAssetName)
            .renderingMode(.original)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private extension AgentKind {
    var brandAssetName: String {
        switch self {
        case .codex: "CodexIcon"
        case .claude: "ClaudeIcon"
        }
    }
}
