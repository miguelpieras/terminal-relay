import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var selectedProjectID: UUID?
    @State private var editorProject: ProjectProfile?
    @State private var projectPendingDeletion: ProjectProfile?
    @State private var isManagingWorkers = false

    private var selectedProject: ProjectProfile? {
        projectStore.project(id: selectedProjectID)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: addProject) {
                    Image(systemName: "plus")
                }
                .help("New project")

                Menu {
                    Button("Edit Project", systemImage: "pencil") {
                        editorProject = selectedProject
                    }
                    .disabled(selectedProject == nil)

                    Button("Manage Workers", systemImage: "server.rack") {
                        isManagingWorkers = true
                    }

                    Divider()

                    Button("Delete Project", systemImage: "trash", role: .destructive) {
                        projectPendingDeletion = selectedProject
                    }
                    .disabled(selectedProject == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .help("Project actions")
            }
        }
        .sheet(item: $editorProject) { project in
            ProjectEditorView(project: project, workers: serverStore.servers) { savedProject in
                guard projectStore.save(savedProject) else { return }
                selectedProjectID = savedProject.id
                editorProject = nil
            } onCancel: {
                editorProject = nil
            }
        }
        .sheet(isPresented: $isManagingWorkers) {
            WorkerManagementView()
        }
        .confirmationDialog(
            "Remove \(projectPendingDeletion?.displayName ?? "project") from Terminal Relay?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            )
        ) {
            Button("Remove Project", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                sessionManager.closeSessions(forProjectID: project.id)
                projectStore.delete(id: project.id)
                selectedProjectID = projectStore.projects.first?.id
                projectPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                projectPendingDeletion = nil
            }
        } message: {
            Text("Open terminals will stop. The remote repository and files will not be deleted.")
        }
        .alert(
            "Terminal Relay",
            isPresented: Binding(
                get: { projectStore.persistenceError != nil || projectStore.validationError != nil },
                set: {
                    if !$0 {
                        projectStore.dismissPersistenceError()
                        projectStore.dismissValidationError()
                    }
                }
            )
        ) {
            Button("OK") {
                projectStore.dismissPersistenceError()
                projectStore.dismissValidationError()
            }
        } message: {
            Text(projectStore.persistenceError ?? projectStore.validationError ?? "Unknown project error")
        }
        .onAppear(perform: selectFirstProjectIfNeeded)
        .onChange(of: projectStore.projects) { _, _ in selectFirstProjectIfNeeded() }
        .onChange(of: serverStore.servers) { _, workers in
            projectStore.updateServers(workers)
        }
        .onChange(of: selectedProjectID) { _, projectID in
            guard let projectID else {
                sessionManager.selectedSessionID = nil
                return
            }

            let selectedSessionBelongsToProject = sessionManager
                .sessions(forProjectID: projectID)
                .contains { $0.id == sessionManager.selectedSessionID }
            if !selectedSessionBelongsToProject {
                sessionManager.selectedSessionID = nil
            }
        }
    }

    private var sidebar: some View {
        List {
            HStack {
                Text("Terminal Relay")
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 12))
            .listRowSeparator(.hidden)

            Button(action: addProject) {
                Label("New Project", systemImage: "square.and.pencil")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 12))

            Section {
                ForEach(projectStore.projects) { project in
                    ProjectSidebarSection(
                        project: project,
                        isProjectSelected: selectedProjectID == project.id,
                        selectedSessionID: sessionManager.selectedSessionID,
                        onSelectProject: {
                            selectedProjectID = project.id
                            sessionManager.selectedSessionID = nil
                        },
                        onSelectSession: { sessionID in
                            selectedProjectID = project.id
                            sessionManager.selectedSessionID = sessionID
                        },
                        onEdit: { editorProject = project },
                        onRemove: { projectPendingDeletion = project }
                    )
                    .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()

                Button {
                    isManagingWorkers = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "server.rack")
                            .frame(width: 18)
                        Text("Workers")
                        Spacer()
                        Text("\(serverStore.servers.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                }
                .buttonStyle(.plain)
            }
            .background(.bar)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let project = selectedProject,
           let worker = serverStore.server(id: project.serverID) {
            ProjectWorkspaceView(
                project: project,
                worker: worker,
                onSelectProject: { selectedProjectID = $0 }
            )
        } else if projectStore.projects.isEmpty {
            ContentUnavailableView {
                Label("No Projects", systemImage: "folder.badge.plus")
            } description: {
                Text("Create a project and assign it to a remote Terminal Relay worker.")
            } actions: {
                Button("New Project", action: addProject)
                    .buttonStyle(.borderedProminent)
                Button("Manage Workers") { isManagingWorkers = true }
            }
        } else {
            ContentUnavailableView(
                "Worker Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Reassign this project to an available worker.")
            )
        }
    }

    private func addProject() {
        guard let worker = serverStore.servers.first else {
            isManagingWorkers = true
            return
        }

        editorProject = ProjectProfile(serverID: worker.id)
    }

    private func selectFirstProjectIfNeeded() {
        if selectedProjectID == nil || projectStore.project(id: selectedProjectID) == nil {
            selectedProjectID = projectStore.projects.first?.id
        }
    }
}

private struct ProjectSidebarSection: View {
    @EnvironmentObject private var sessionManager: SessionManager

    let project: ProjectProfile
    let isProjectSelected: Bool
    let selectedSessionID: UUID?
    let onSelectProject: () -> Void
    let onSelectSession: (UUID) -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    private var sessions: [TerminalSession] {
        Array(sessionManager.sessions(forProjectID: project.id).reversed())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button(action: onSelectProject) {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)

                    Text(project.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Spacer(minLength: 6)
                }
                .padding(.horizontal, 7)
                .frame(height: 32)
                .background(
                    isProjectSelected && selectedSessionID == nil
                        ? Color.primary.opacity(0.09)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Edit Project", action: onEdit)
                Divider()
                Button("Remove Project", role: .destructive, action: onRemove)
            }

            ForEach(sessions) { session in
                Button {
                    onSelectSession(session.id)
                } label: {
                    ProjectSessionRow(
                        session: session,
                        isSelected: selectedSessionID == session.id
                    )
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(session.status.occupiesSlot ? "Stop Session" : "Close Session") {
                        sessionManager.close(sessionID: session.id)
                    }
                    .disabled(session.status == .stopping)
                }
            }
        }
    }
}

private struct ProjectSessionRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: 25, height: 1)

            Text(session.displayTitle)
                .font(.callout)
                .foregroundStyle(session.status.occupiesSlot ? .primary : .secondary)
                .lineLimit(1)

            Spacer(minLength: 5)

            Image(systemName: session.kind.systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(session.status.occupiesSlot ? session.kind.tint : Color.secondary)

            Circle()
                .fill(session.status.occupiesSlot ? session.kind.tint : Color.secondary.opacity(0.16))
                .overlay {
                    if !session.status.occupiesSlot {
                        Circle()
                            .stroke(Color.secondary.opacity(0.55), lineWidth: 1)
                    }
                }
                .frame(width: 7, height: 7)
                .help(session.status.occupiesSlot ? "Terminal open" : session.status.label)
                .accessibilityLabel(
                    "\(session.kind.displayName), \(session.status.occupiesSlot ? "terminal open" : session.status.label)"
                )
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 30)
        .background(
            isSelected ? Color.primary.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
    }
}
