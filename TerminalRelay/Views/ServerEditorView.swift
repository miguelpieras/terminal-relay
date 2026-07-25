import AppKit
import SwiftUI

struct WorkerEditorView: View {
    @State private var draft: ServerProfile
    @State private var copiedBootstrapCommand = false

    let onSave: (ServerProfile) -> Void
    let onCancel: () -> Void
    private let isRegistering: Bool

    init(
        profile: ServerProfile,
        onSave: @escaping (ServerProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: profile)
        self.onSave = onSave
        self.onCancel = onCancel
        isRegistering = profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if isRegistering {
                    Section("Set up a new worker") {
                        Text(
                            "For a fresh Ubuntu host you can already reach as root, run this from a configured Terminal Relay repository checkout. Setup installs the runtime and registers the worker here automatically."
                        )
                        .foregroundStyle(.secondary)

                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(bootstrapCommand)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)

                            Spacer(minLength: 8)

                            Button(copiedBootstrapCommand ? "Copied" : "Copy") {
                                copyBootstrapCommand()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Section(isRegistering ? "Or register an existing worker" : "Connection") {
                    TextField("Worker name", text: $draft.name, prompt: Text("My Worker"))
                    TextField("Host or SSH alias", text: $draft.host, prompt: Text("worker.example.com"))
                    TextField("Username", text: $draft.username, prompt: Text("terminal-relay"))
                    TextField("Port", value: $draft.port, format: .number)
                    TextField("Identity file (optional)", text: $draft.identityFile, prompt: Text("~/.ssh/id_ed25519"))
                }

                Section("Account labels (optional)") {
                    TextField("Codex", text: $draft.codexAccountLabel, prompt: Text("Work Codex"))
                    TextField("Claude", text: $draft.claudeAccountLabel, prompt: Text("Work Claude"))
                }

                Section {
                    Label(
                        isRegistering
                            ? "Manual registration saves connection details only. The host must already have the Terminal Relay runtime installed."
                            : "Passwords and API keys are not stored. SSH authentication and agent accounts stay on the worker.",
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
                Button(isRegistering ? "Register Worker" : "Save") {
                    onSave(trimmed(draft))
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.isValid)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: bootstrapCommand) { _, _ in
            copiedBootstrapCommand = false
        }
    }

    private var bootstrapCommand: String {
        let host = draft.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let identityFile = draft.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments = ["./Scripts/bootstrap-worker.sh"]
        if !identityFile.isEmpty {
            arguments += [
                "--identity",
                SSHCommandBuilder.shellQuote((identityFile as NSString).expandingTildeInPath)
            ]
        }
        if draft.port != 22 {
            arguments += ["--port", String(draft.port)]
        }
        arguments.append(
            SSHCommandBuilder.shellQuote("root@\(host.isEmpty ? "worker.example.com" : host)")
        )
        return arguments.joined(separator: " ")
    }

    private func copyBootstrapCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(bootstrapCommand, forType: .string)
        copiedBootstrapCommand = true
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
