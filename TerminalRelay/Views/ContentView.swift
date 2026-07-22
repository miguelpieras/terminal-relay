import SwiftUI

private enum SidebarDestination: Equatable {
    case project(UUID)
    case session(projectID: UUID, sessionID: UUID)
}

private enum SidebarPalette {
    static let background = Color(red: 33.0 / 255.0, green: 33.0 / 255.0, blue: 33.0 / 255.0)
    static let primary = Color(red: 222.0 / 255.0, green: 222.0 / 255.0, blue: 222.0 / 255.0)
    static let secondary = Color(red: 116.0 / 255.0, green: 116.0 / 255.0, blue: 116.0 / 255.0)
    static let tertiary = Color(red: 89.0 / 255.0, green: 89.0 / 255.0, blue: 89.0 / 255.0)
    static let hover = Color(red: 41.0 / 255.0, green: 41.0 / 255.0, blue: 41.0 / 255.0)
    static let selected = Color(red: 51.0 / 255.0, green: 51.0 / 255.0, blue: 51.0 / 255.0)
    static let separator = Color(red: 52.0 / 255.0, green: 52.0 / 255.0, blue: 52.0 / 255.0)
    static let footerSeparator = Color(red: 56.0 / 255.0, green: 56.0 / 255.0, blue: 56.0 / 255.0)
}

struct ContentView: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager

    @State private var selectedProjectID: UUID?
    @State private var editorProject: ProjectProfile?
    @State private var projectPendingDeletion: ProjectProfile?
    @State private var isManagingWorkers = false
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var navigationHistory: [SidebarDestination] = []
    @State private var navigationIndex = -1

    private var selectedProject: ProjectProfile? {
        projectStore.project(id: selectedProjectID)
    }

    private var visibleProjects: [ProjectProfile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projectStore.projects }

        return projectStore.projects.filter { project in
            project.displayName.localizedCaseInsensitiveContains(query)
                || sessionManager.sessions(forProjectID: project.id).contains {
                    $0.displayTitle.localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var currentDestination: SidebarDestination? {
        guard let projectID = selectedProjectID else { return nil }
        if let sessionID = sessionManager.selectedSessionID,
           sessionManager.sessions(forProjectID: projectID).contains(where: { $0.id == sessionID }) {
            return .session(projectID: projectID, sessionID: sessionID)
        }
        return .project(projectID)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 268, ideal: 268, max: 268)
                .overlay(alignment: .topLeading) {
                    titlebarNavigationControls
                }
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
                navigate(to: .project(savedProject.id))
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
                sessionManager.selectedSessionID = nil
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
        VStack(spacing: 0) {
            sidebarHeader
            newProjectButton

            Rectangle()
                .fill(SidebarPalette.separator)
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleProjects) { project in
                        ProjectSidebarSection(
                            project: project,
                            searchQuery: searchQuery,
                            selectedSessionID: sessionManager.selectedSessionID,
                            onSelectProject: {
                                navigate(to: .project(project.id))
                            },
                            onSelectSession: { sessionID in
                                navigate(to: .session(projectID: project.id, sessionID: sessionID))
                            },
                            onEdit: { editorProject = project },
                            onRemove: { projectPendingDeletion = project }
                        )
                    }

                    if !searchQuery.isEmpty && visibleProjects.isEmpty {
                        Text("No matching projects or sessions")
                            .font(.system(size: 13.5))
                            .foregroundStyle(SidebarPalette.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.top, 18)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)

            sidebarFooter
        }
        .background(SidebarPalette.background)
    }

    @ViewBuilder
    private var sidebarHeader: some View {
        if isSearching {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SidebarPalette.secondary)

                TextField("Search", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(SidebarPalette.primary)

                Button {
                    searchQuery = ""
                    isSearching = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SidebarPalette.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
        } else {
            HStack(spacing: 0) {
                Menu {
                    Button("Manage Workers", systemImage: "server.rack") {
                        isManagingWorkers = true
                    }
                    Button("Settings…", systemImage: "gearshape") {
                        openSettings()
                    }
                } label: {
                    Text("Terminal Relay")
                        .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(SidebarPalette.primary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Spacer()

                Button {
                    isSearching = true
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 26, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(SidebarPalette.secondary)
                .help("Search projects and sessions")
            }
            .padding(.leading, 10)
            .padding(.trailing, 8)
            .frame(height: 42)
        }
    }

    private var newProjectButton: some View {
        SidebarActionButton(
            title: "New project",
            systemImage: "square.and.pencil",
            action: addProject
        )
        .keyboardShortcut("n", modifiers: .command)
    }

    private var titlebarNavigationControls: some View {
        HStack(spacing: 0) {
            Button(action: navigateBack) {
                Image(systemName: "chevron.left")
                    .frame(width: 24, height: 28)
            }
            .disabled(navigationIndex <= 0)
            .help("Back")

            Button(action: navigateForward) {
                Image(systemName: "chevron.right")
                    .frame(width: 24, height: 28)
            }
            .disabled(navigationIndex < 0 || navigationIndex >= navigationHistory.count - 1)
            .help("Forward")
        }
        .buttonStyle(.plain)
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(SidebarPalette.secondary)
        .padding(.leading, 107)
        .frame(height: 42)
        .offset(y: -43)
    }

    private var sidebarFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(SidebarPalette.footerSeparator)
                .frame(height: 1)

            HStack(spacing: 10) {
                Button {
                    openSettings()
                } label: {
                    HStack(spacing: 7) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.49, green: 0.28, blue: 0.63))
                            Text("MP")
                                .font(.system(size: 7.5, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 18, height: 18)

                        Text("Miguel Pieras")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(SidebarPalette.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    isManagingWorkers = true
                } label: {
                    Image(systemName: "server.rack")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Manage workers")
            }
            .padding(.horizontal, 9)
            .frame(height: 47)
        }
        .background(SidebarPalette.background)
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
            sessionManager.selectedSessionID = nil
        }
    }

    private func navigate(to destination: SidebarDestination) {
        if currentDestination != destination {
            if navigationHistory.isEmpty, let currentDestination {
                navigationHistory.append(currentDestination)
                navigationIndex = 0
            } else if navigationIndex < navigationHistory.count - 1 {
                navigationHistory.removeSubrange((navigationIndex + 1)..<navigationHistory.count)
            }

            navigationHistory.append(destination)
            navigationIndex = navigationHistory.count - 1
        }

        apply(destination)
    }

    private func navigateBack() {
        guard navigationIndex > 0 else { return }
        navigationIndex -= 1
        apply(navigationHistory[navigationIndex])
    }

    private func navigateForward() {
        guard navigationIndex >= 0, navigationIndex < navigationHistory.count - 1 else { return }
        navigationIndex += 1
        apply(navigationHistory[navigationIndex])
    }

    private func apply(_ destination: SidebarDestination) {
        switch destination {
        case .project(let projectID):
            selectedProjectID = projectID
            sessionManager.selectedSessionID = nil
        case .session(let projectID, let sessionID):
            selectedProjectID = projectID
            sessionManager.selectedSessionID = sessionManager
                .sessions(forProjectID: projectID)
                .contains(where: { $0.id == sessionID }) ? sessionID : nil
        }
    }
}

private struct SidebarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 15)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(SidebarPalette.primary)
            .padding(.leading, 4)
            .padding(.trailing, 6)
            .frame(height: 38)
            .background(
                isHovering ? SidebarPalette.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
        .onHover { isHovering = $0 }
    }
}

private struct ProjectSidebarSection: View {
    @EnvironmentObject private var sessionManager: SessionManager

    let project: ProjectProfile
    let searchQuery: String
    let selectedSessionID: UUID?
    let onSelectProject: () -> Void
    let onSelectSession: (UUID) -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void

    @State private var isExpanded = false
    @State private var isProjectHovering = false

    private var allSessions: [TerminalSession] {
        Array(sessionManager.sessions(forProjectID: project.id).reversed())
    }

    private var matchingSessions: [TerminalSession] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty,
              !project.displayName.localizedCaseInsensitiveContains(query) else {
            return allSessions
        }
        return allSessions.filter { $0.displayTitle.localizedCaseInsensitiveContains(query) }
    }

    private var visibleSessions: [TerminalSession] {
        if !searchQuery.isEmpty || isExpanded { return matchingSessions }
        return Array(matchingSessions.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelectProject) {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(SidebarPalette.primary)
                        .frame(width: 15)

                    Text(project.displayName)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(SidebarPalette.primary)
                        .lineLimit(1)

                    Spacer(minLength: 6)
                }
                .padding(.leading, 6)
                .padding(.trailing, 8)
                .frame(height: 35)
                .background(
                    isProjectHovering ? SidebarPalette.hover : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .onHover { isProjectHovering = $0 }
            .contextMenu {
                Button("Edit Project", action: onEdit)
                Divider()
                Button("Remove Project", role: .destructive, action: onRemove)
            }

            if matchingSessions.isEmpty {
                Text("No sessions")
                    .font(.system(size: 14))
                    .foregroundStyle(SidebarPalette.tertiary)
                    .padding(.leading, 40)
                    .padding(.trailing, 12)
                    .frame(height: 35, alignment: .leading)
            } else {
                ForEach(visibleSessions) { session in
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

                if searchQuery.isEmpty && matchingSessions.count > 5 {
                    Button(isExpanded ? "Show less" : "Show more") {
                        isExpanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(SidebarPalette.secondary)
                    .padding(.leading, 40)
                    .frame(height: 35)
                }
            }
        }
        .padding(.bottom, 8)
    }
}

private struct ProjectSessionRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(session.displayTitle)
                .font(.system(size: 14))
                .foregroundStyle(
                    session.status.occupiesSlot
                        ? SidebarPalette.primary
                        : SidebarPalette.secondary
                )
                .lineLimit(1)

            Spacer(minLength: 5)

            AgentBrandIcon(kind: session.kind, size: 14)
                .opacity(session.status.occupiesSlot ? 1 : 0.55)

            Circle()
                .fill(session.status.occupiesSlot ? session.kind.tint : Color.clear)
                .overlay {
                    Circle()
                        .stroke(
                            session.status.occupiesSlot
                                ? Color.clear
                                : SidebarPalette.secondary,
                            lineWidth: 1
                        )
                }
                .frame(width: 6, height: 6)
                .help(session.status.occupiesSlot ? "Terminal open" : session.status.label)
                .accessibilityLabel(
                    "\(session.kind.displayName), \(session.status.occupiesSlot ? "terminal open" : session.status.label)"
                )
        }
        .padding(.leading, 30)
        .padding(.trailing, 8)
        .frame(height: 35)
        .background(
            isSelected
                ? SidebarPalette.selected
                : (isHovering ? SidebarPalette.hover : Color.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
