import SwiftUI

struct AgentDefaultsView: View {
    @AppStorage(AgentLaunchDefaults.StorageKey.codexModel)
    private var codexModel = AgentLaunchDefaults.standard.codexModel

    @AppStorage(AgentLaunchDefaults.StorageKey.codexReasoningEffort)
    private var codexReasoningEffort = AgentLaunchDefaults.standard.codexReasoningEffort

    @AppStorage(AgentLaunchDefaults.StorageKey.claudeModel)
    private var claudeModel = AgentLaunchDefaults.standard.claudeModel

    @AppStorage(AgentLaunchDefaults.StorageKey.claudeReasoningEffort)
    private var claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort

    @AppStorage(AgentLaunchDefaults.StorageKey.fullAccessEnabled)
    private var fullAccessEnabled = AgentLaunchDefaults.standard.fullAccessEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Agent Defaults")
                    .font(.title2.weight(.semibold))
                Text("Applied to every newly started terminal on every worker.")
                    .foregroundStyle(.secondary)
            }

            agentSettings(
                title: "Codex",
                systemImage: AgentKind.codex.systemImage,
                tint: .blue,
                model: $codexModel,
                effort: $codexReasoningEffort
            )

            agentSettings(
                title: "Claude Code",
                systemImage: AgentKind.claude.systemImage,
                tint: .orange,
                model: $claudeModel,
                effort: $claudeReasoningEffort
            )

            GroupBox {
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Auto-approve full access", isOn: $fullAccessEnabled)
                    Text("Disables approval prompts and the agents' built-in permission boundaries on every worker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
            } label: {
                Label("Permissions", systemImage: "exclamationmark.shield.fill")
                    .foregroundStyle(fullAccessEnabled ? Color.red : Color.secondary)
            }

            HStack {
                Text("Running terminals keep their current settings until restarted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func agentSettings(
        title: String,
        systemImage: String,
        tint: Color,
        model: Binding<String>,
        effort: Binding<AgentReasoningEffort>
    ) -> some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text("Model")
                        .foregroundStyle(.secondary)
                    TextField("Model", text: model)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Reasoning")
                        .foregroundStyle(.secondary)
                    Picker("Reasoning", selection: effort) {
                        ForEach(AgentReasoningEffort.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 4)
        } label: {
            Label(title, systemImage: systemImage)
                .foregroundStyle(tint)
        }
    }

    private func restoreDefaults() {
        codexModel = AgentLaunchDefaults.standard.codexModel
        codexReasoningEffort = AgentLaunchDefaults.standard.codexReasoningEffort
        claudeModel = AgentLaunchDefaults.standard.claudeModel
        claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort
        fullAccessEnabled = AgentLaunchDefaults.standard.fullAccessEnabled
    }
}
