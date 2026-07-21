import Foundation

enum AgentReasoningEffort: String, CaseIterable, Identifiable {
    case low
    case medium
    case high
    case xhigh
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .xhigh: "Extra high"
        case .max: "Max"
        }
    }
}

struct AgentLaunchDefaults: Equatable {
    enum StorageKey {
        static let codexModel = "agentLaunchDefaults.codexModel"
        static let codexReasoningEffort = "agentLaunchDefaults.codexReasoningEffort"
        static let claudeModel = "agentLaunchDefaults.claudeModel"
        static let claudeReasoningEffort = "agentLaunchDefaults.claudeReasoningEffort"
    }

    static let defaultCodexModel = "gpt-5.6-sol"
    static let defaultClaudeModel = "fable"

    static let standard = AgentLaunchDefaults(
        codexModel: defaultCodexModel,
        codexReasoningEffort: .max,
        claudeModel: defaultClaudeModel,
        claudeReasoningEffort: .max
    )

    let codexModel: String
    let codexReasoningEffort: AgentReasoningEffort
    let claudeModel: String
    let claudeReasoningEffort: AgentReasoningEffort

    init(
        codexModel: String,
        codexReasoningEffort: AgentReasoningEffort,
        claudeModel: String,
        claudeReasoningEffort: AgentReasoningEffort
    ) {
        self.codexModel = Self.normalizedModel(codexModel, fallback: Self.defaultCodexModel)
        self.codexReasoningEffort = codexReasoningEffort
        self.claudeModel = Self.normalizedModel(claudeModel, fallback: Self.defaultClaudeModel)
        self.claudeReasoningEffort = claudeReasoningEffort
    }

    func arguments(for kind: AgentKind) -> [String] {
        switch kind {
        case .codex:
            return [
                "--model", codexModel,
                "--config", "model_reasoning_effort=\"\(codexReasoningEffort.rawValue)\""
            ]
        case .claude:
            return [
                "--model", claudeModel,
                "--effort", claudeReasoningEffort.rawValue
            ]
        }
    }

    func summary(for kind: AgentKind) -> String {
        switch kind {
        case .codex:
            "\(codexModel) · \(codexReasoningEffort.displayName) reasoning"
        case .claude:
            "\(claudeModel) · \(claudeReasoningEffort.displayName) reasoning"
        }
    }

    private static func normalizedModel(_ model: String, fallback: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
