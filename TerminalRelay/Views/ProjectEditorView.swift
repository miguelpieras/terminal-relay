import SwiftUI

struct ProjectEditorView: View {
    @State private var draft: ProjectProfile

    let workers: [ServerProfile]
    let onSave: (ProjectProfile) -> Void
    let onCancel: () -> Void

    init(
        project: ProjectProfile,
        workers: [ServerProfile],
        onSave: @escaping (ProjectProfile) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _draft = State(initialValue: project)
        self.workers = workers
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(draft.name.isEmpty ? "New Project" : "Project Settings")
                        .font(.title2.weight(.semibold))
                    Text("Choose the repository, worker, and remote workspace.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            Form {
                Section("Project") {
                    TextField("Name", text: $draft.name, prompt: Text("Website API"))
                    TextField(
                        "GitHub repository",
                        text: $draft.githubRepository,
                        prompt: Text("owner/repository")
                    )
                }

                Section("Remote workspace") {
                    Picker("Worker", selection: $draft.serverID) {
                        ForEach(workers) { worker in
                            Text(worker.displayName).tag(worker.id)
                        }
                    }

                    TextField(
                        "Directory",
                        text: $draft.workingDirectory,
                        prompt: Text("/workspace/project-name")
                    )
                        .font(.system(.body, design: .monospaced))
                }

                Section {
                    Label(
                        "Repository access will use the Terminal Relay GitHub App. No GitHub credential is saved with the project.",
                        systemImage: "lock.shield"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

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
                .disabled(!draft.isValid || !draft.hasAssignedServer(in: workers))
            }
            .padding(16)
        }
        .frame(width: 560, height: 500)
    }

    private func trimmed(_ project: ProjectProfile) -> ProjectProfile {
        var result = project
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.githubRepository = result.githubRepository.trimmingCharacters(in: .whitespacesAndNewlines)
        result.workingDirectory = result.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }
}
