import SwiftUI

struct WorkerManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var editorProfile: ServerProfile?
    @State private var workerPendingDeletion: ServerProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Workers")
                        .font(.title2.weight(.semibold))
                    Text("Remote machines that host Terminal Relay projects.")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    editorProfile = ServerProfile()
                } label: {
                    Label("Add Worker", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(20)

            Divider()

            List {
                ForEach(serverStore.servers) { worker in
                    WorkerRow(
                        worker: worker,
                        projectCount: projectStore.projects(for: worker.id).count,
                        onEdit: { editorProfile = worker },
                        onDelete: { workerPendingDeletion = worker }
                    )
                }
            }
            .listStyle(.inset)
            .overlay {
                if serverStore.servers.isEmpty {
                    ContentUnavailableView(
                        "No Workers",
                        systemImage: "server.rack",
                        description: Text("Add a remote worker before creating a project.")
                    )
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 660, height: 480)
        .sheet(item: $editorProfile) { profile in
            WorkerEditorView(profile: profile) { savedProfile in
                serverStore.save(savedProfile)
                projectStore.updateServers(serverStore.servers)
                editorProfile = nil
            } onCancel: {
                editorProfile = nil
            }
        }
        .confirmationDialog(
            "Delete \(workerPendingDeletion?.displayName ?? "worker")?",
            isPresented: Binding(
                get: { workerPendingDeletion != nil },
                set: { if !$0 { workerPendingDeletion = nil } }
            )
        ) {
            Button("Delete Worker", role: .destructive) {
                guard let worker = workerPendingDeletion else { return }
                sessionManager.closeSessions(for: worker)
                serverStore.delete(id: worker.id)
                projectStore.updateServers(serverStore.servers)
                workerPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                workerPendingDeletion = nil
            }
        } message: {
            Text("Its saved SSH connection will be removed. Remote files are never deleted.")
        }
    }
}

private struct WorkerRow: View {
    let worker: ServerProfile
    let projectCount: Int
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(worker.displayName)
                    .font(.callout.weight(.medium))
                Text(connectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(projectCount == 1 ? "1 project" : "\(projectCount) projects")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Edit", action: onEdit)
                .buttonStyle(.borderless)

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(projectCount > 0)
            .help(projectCount > 0 ? "Reassign or remove this worker's projects first" : "Delete worker")
        }
        .padding(.vertical, 6)
    }

    private var connectionSummary: String {
        var value = worker.destination
        if worker.port != 22 { value += ":\(worker.port)" }
        return value
    }
}
