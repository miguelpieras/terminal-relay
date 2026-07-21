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
            sessionManager.selectedSessionID = sessionManager.sessions(forProjectID: projectID).first?.id
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

            Section("Projects") {
                ForEach(projectStore.projects) { project in
                    Button {
                        selectedProjectID = project.id
                    } label: {
                        ProjectSidebarRow(
                            project: project,
                            worker: serverStore.server(id: project.serverID),
                            isSelected: selectedProjectID == project.id
                        )
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    .contextMenu {
                        Button("Edit") { editorProject = project }
                        Divider()
                        Button("Remove", role: .destructive) {
                            projectPendingDeletion = project
                        }
                    }
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

private struct ProjectSidebarRow: View {
    @EnvironmentObject private var sessionManager: SessionManager

    let project: ProjectProfile
    let worker: ServerProfile?
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(worker?.displayName ?? "Worker unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: 6) {
                ForEach(AgentKind.allCases) { kind in
                    ProjectSessionDot(
                        kind: kind,
                        session: sessionManager.session(projectID: project.id, kind: kind)
                    )
                }
            }
            .frame(width: 28, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .background(
            isSelected ? Color.primary.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

private struct ProjectSessionDot: View {
    let kind: AgentKind
    let session: TerminalSession?

    var body: some View {
        Circle()
            .fill(fillColor)
            .overlay {
                Circle()
                    .stroke(strokeColor, lineWidth: session?.status.occupiesSlot == true ? 0 : 1)
            }
            .frame(width: 7, height: 7)
            .help(helpText)
            .accessibilityLabel(helpText)
    }

    private var fillColor: Color {
        guard let session else { return Color.secondary.opacity(0.2) }
        return session.status.occupiesSlot ? kind.tint : Color.secondary.opacity(0.16)
    }

    private var strokeColor: Color {
        guard let session else { return Color.secondary.opacity(0.45) }
        switch session.status {
        case .exited: return .red.opacity(0.8)
        case .connecting, .running, .stopping: return .clear
        }
    }

    private var helpText: String {
        guard let session else { return "\(kind.displayName) terminal closed" }
        return session.status.occupiesSlot
            ? "\(kind.displayName) terminal open"
            : "\(kind.displayName) terminal exited"
    }
}
