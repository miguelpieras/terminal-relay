import SwiftUI

struct AgentDefaultsView: View {
    @AppStorage(ApplicationSettings.StorageKey.keepRunningAfterLastWindowClosed)
    private var keepRunningAfterLastWindowClosed =
        ApplicationSettings.defaultKeepRunningAfterLastWindowClosed

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
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.title2.weight(.semibold))
                    Text("Manage app behavior and defaults for newly started terminals.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Defaults", action: restoreDefaults)
            }
            .padding(.horizontal, 24)
            .frame(minHeight: 72)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 7) {
                            Toggle(
                                "Keep running after closing the last window",
                                isOn: $keepRunningAfterLastWindowClosed
                            )
                            Text(
                                "Keeps Terminal Relay and its terminal sessions open. Quit the app to disconnect."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    } label: {
                        Label("Application", systemImage: "macwindow")
                    }

                    agentSettings(
                        kind: .codex,
                        title: "Codex",
                        model: $codexModel,
                        effort: $codexReasoningEffort
                    )

                    agentSettings(
                        kind: .claude,
                        title: "Claude Code",
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

                    Text("Running terminals keep their current settings until restarted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Settings")
    }

    private func agentSettings(
        kind: AgentKind,
        title: String,
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
                        ForEach(reasoningEfforts(for: kind)) { option in
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
            HStack(spacing: 7) {
                AgentBrandIcon(kind: kind, size: 18)
                Text(title)
            }
        }
    }

    private func restoreDefaults() {
        keepRunningAfterLastWindowClosed =
            ApplicationSettings.defaultKeepRunningAfterLastWindowClosed
        codexModel = AgentLaunchDefaults.standard.codexModel
        codexReasoningEffort = AgentLaunchDefaults.standard.codexReasoningEffort
        claudeModel = AgentLaunchDefaults.standard.claudeModel
        claudeReasoningEffort = AgentLaunchDefaults.standard.claudeReasoningEffort
        fullAccessEnabled = AgentLaunchDefaults.standard.fullAccessEnabled
    }

    private func reasoningEfforts(for kind: AgentKind) -> [AgentReasoningEffort] {
        if kind == .claude {
            return AgentReasoningEffort.allCases.filter { $0 != .ultra }
        }
        return AgentReasoningEffort.allCases
    }
}
