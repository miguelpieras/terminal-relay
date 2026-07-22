import SwiftUI

struct WorkerEditorView: View {
    @State private var draft: ServerProfile

    let onSave: (ServerProfile) -> Void
    let onCancel: () -> Void

    init(
        profile: ServerProfile,
        onSave: @escaping (ServerProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Connection") {
                    TextField("Worker name", text: $draft.name, prompt: Text("Terminal Relay Worker 1"))
                    TextField("Host or SSH alias", text: $draft.host, prompt: Text("terminal-relay-worker-1"))
                    TextField("Username (optional)", text: $draft.username, prompt: Text("ubuntu"))
                    TextField("Port", value: $draft.port, format: .number)
                    TextField("Identity file (optional)", text: $draft.identityFile, prompt: Text("~/.ssh/id_ed25519"))
                }

                Section("Codex") {
                    TextField("Account label", text: $draft.codexAccountLabel, prompt: Text("Work Codex"))
                    TextField("Launch command", text: $draft.codexCommand, prompt: Text("codex"))
                        .font(.system(.body, design: .monospaced))
                }

                Section("Claude") {
                    TextField("Account label", text: $draft.claudeAccountLabel, prompt: Text("Work Claude"))
                    TextField("Launch command", text: $draft.claudeCommand, prompt: Text("claude"))
                        .font(.system(.body, design: .monospaced))
                }

                Section {
                    Label(
                        "Passwords and API keys are not stored. SSH authentication and agent accounts stay on the worker.",
                        systemImage: "lock.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmed(draft))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func trimmed(_ profile: ServerProfile) -> ServerProfile {
        var result = profile
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.host = result.host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = result.username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.identityFile = result.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        result.workingDirectory = result.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        result.codexAccountLabel = result.codexAccountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.claudeAccountLabel = result.claudeAccountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        result.codexCommand = result.codexCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        result.claudeCommand = result.claudeCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
