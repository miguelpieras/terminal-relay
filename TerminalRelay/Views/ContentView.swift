import SwiftUI

private enum SidebarDestination: Equatable {
    case project(UUID)
    case session(projectID: UUID, sessionID: UUID)
    case workers
    case worker(UUID)
    case settings
    case newProject(ProjectProfile)
    case editProject(UUID)
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

private enum SidebarRowGeometry {
    static let horizontalMargin: CGFloat = 10
    static let contentLeadingPadding: CGFloat = 6
    static let contentTrailingPadding: CGFloat = 8
    static let height: CGFloat = 35
    static let iconSize: CGFloat = 13
    static let iconFrameWidth: CGFloat = 14
    static let iconSpacing: CGFloat = 9
    static let cornerRadius: CGFloat = 6
}

struct ContentView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager

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

    @State private var selectedProjectID: UUID?
    @State private var projectPendingDeletion: ProjectProfile?
    @State private var pageDestination: SidebarDestination?
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var navigationHistory: [SidebarDestination] = []
    @State private var navigationIndex = -1

    private var launchDefaults: AgentLaunchDefaults {
        AgentLaunchDefaults(
            codexModel: codexModel,
            codexReasoningEffort: codexReasoningEffort,
            claudeModel: claudeModel,
            claudeReasoningEffort: claudeReasoningEffort,
            fullAccessEnabled: fullAccessEnabled
        )
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
        if let pageDestination {
            return pageDestination
        }
        guard let projectID = selectedProjectID else { return nil }
        if let sessionID = sessionManager.selectedSessionID,
           sessionManager.sessions(forProjectID: projectID).contains(where: { $0.id == sessionID }) {
            return .session(projectID: projectID, sessionID: sessionID)
        }
        return .project(projectID)
    }

    private var projectForActions: ProjectProfile? {
        switch currentDestination {
        case .project(let projectID), .session(let projectID, _):
            return projectStore.project(id: projectID)
        default:
            return nil
        }
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
            if let project = projectForActions {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Edit Project", systemImage: "pencil") {
                            navigate(to: .editProject(project.id))
                        }

                        Button("Manage Workers", systemImage: "server.rack") {
                            navigate(to: .workers)
                        }

                        Divider()

                        Button("Delete Project", systemImage: "trash", role: .destructive) {
                            projectPendingDeletion = project
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .help("Project actions")
                }
            }
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
                            onOpenTerminal: { kind in
                                openTerminal(kind, for: project)
                            },
                            onEdit: { navigate(to: .editProject(project.id)) },
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
                        navigate(to: .workers)
                    }
                    Button("Settings…", systemImage: "gearshape") {
                        navigate(to: .settings)
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
                    navigate(to: .settings)
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
                    navigate(to: .workers)
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
        VStack(spacing: 0) {
            if let message = projectStore.persistenceError ?? projectStore.validationError {
                projectErrorBanner(message)
            }

            if let projectPendingDeletion {
                ProjectRemovalConfirmation(
                    project: projectPendingDeletion,
                    onCancel: { self.projectPendingDeletion = nil },
                    onRemove: { removeProject(projectPendingDeletion) }
                )
            } else {
                destinationDetail
            }
        }
    }

    private func projectErrorBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button {
                projectStore.dismissPersistenceError()
                projectStore.dismissValidationError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Color.orange.opacity(0.1))
    }

    @ViewBuilder
    private var destinationDetail: some View {
        switch currentDestination {
        case .workers:
            WorkersView(focusedWorkerID: nil, onSelectProject: { projectID in
                navigate(to: .project(projectID))
            }, onShowAllWorkers: {
                navigate(to: .workers)
            })
        case .worker(let workerID):
            WorkersView(focusedWorkerID: workerID, onSelectProject: { projectID in
                navigate(to: .project(projectID))
            }, onShowAllWorkers: {
                navigate(to: .workers)
            })
        case .settings:
            AgentDefaultsView()
        case .newProject(let project):
            projectEditor(project)
                .id(project.id)
        case .editProject(let projectID):
            if let project = projectStore.project(id: projectID) {
                projectEditor(project)
                    .id(project.id)
            } else {
                missingProject
            }
        case .project(let projectID), .session(let projectID, _):
            projectDetail(projectID: projectID)
        case nil:
            emptyProjectDetail
        }
    }

    @ViewBuilder
    private func projectDetail(projectID: UUID) -> some View {
        if let project = projectStore.project(id: projectID),
           let worker = serverStore.server(id: project.serverID) {
            ProjectWorkspaceView(
                project: project,
                worker: worker,
                onSelectProject: { navigate(to: .project($0)) },
                onShowWorker: { navigate(to: .worker(worker.id)) }
            )
            .id(project.id)
        } else {
            ContentUnavailableView(
                "Worker Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text("Reassign this project to an available worker.")
            )
        }
    }

    private func projectEditor(_ project: ProjectProfile) -> some View {
        ProjectEditorView(project: project, workers: serverStore.servers) { savedProject in
            let shouldOpenSavedProject = isShowingEditor(for: project.id)
            guard projectStore.save(savedProject) else {
                let message = projectStore.persistenceError
                    ?? projectStore.validationError
                    ?? "The project could not be saved."
                projectStore.dismissPersistenceError()
                projectStore.dismissValidationError()
                return message
            }

            replaceEditorHistory(projectID: project.id, with: savedProject.id)
            if shouldOpenSavedProject {
                apply(.project(savedProject.id))
            }
            return nil
        } onCancel: {
            returnFromEditor(project)
        }
    }

    private func isShowingEditor(for projectID: UUID) -> Bool {
        switch currentDestination {
        case .newProject(let draft):
            return draft.id == projectID
        case .editProject(let editingProjectID):
            return editingProjectID == projectID
        default:
            return false
        }
    }

    private func replaceEditorHistory(projectID: UUID, with savedProjectID: UUID) {
        navigationHistory = navigationHistory.map { destination in
            switch destination {
            case .newProject(let draft) where draft.id == projectID:
                return .project(savedProjectID)
            case .editProject(let editingProjectID) where editingProjectID == projectID:
                return .project(savedProjectID)
            default:
                return destination
            }
        }
    }

    private var emptyProjectDetail: some View {
        ContentUnavailableView {
            Label("No Projects", systemImage: "folder.badge.plus")
        } description: {
            Text("Create a project and assign it to a remote Terminal Relay worker.")
        } actions: {
            Button("New Project", action: addProject)
                .buttonStyle(.borderedProminent)
            Button("Manage Workers") { navigate(to: .workers) }
        }
    }

    private var missingProject: some View {
        ContentUnavailableView(
            "Project Unavailable",
            systemImage: "folder.badge.questionmark",
            description: Text("This project is no longer available in Terminal Relay.")
        )
    }

    private func addProject() {
        guard let worker = serverStore.servers.first else {
            navigate(to: .workers)
            return
        }

        navigate(to: .newProject(ProjectProfile(serverID: worker.id)))
    }

    private func openTerminal(_ kind: AgentKind, for project: ProjectProfile) {
        guard let worker = serverStore.server(id: project.serverID) else {
            navigate(to: .editProject(project.id))
            return
        }

        let result = sessionManager.open(
            project: project,
            on: worker,
            kind: kind,
            launchDefaults: launchDefaults
        )
        let session = result.session
        navigate(to: .session(projectID: session.projectID, sessionID: session.id))
    }

    private func selectFirstProjectIfNeeded() {
        if selectedProjectID == nil || projectStore.project(id: selectedProjectID) == nil {
            selectedProjectID = projectStore.projects.first?.id
            sessionManager.selectedSessionID = nil
        }
    }

    private func navigate(to destination: SidebarDestination) {
        projectPendingDeletion = nil

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
            pageDestination = nil
            selectedProjectID = projectID
            sessionManager.selectedSessionID = nil
        case .session(let projectID, let sessionID):
            pageDestination = nil
            selectedProjectID = projectID
            sessionManager.selectedSessionID = sessionManager
                .sessions(forProjectID: projectID)
                .contains(where: { $0.id == sessionID }) ? sessionID : nil
        case .workers, .worker, .settings, .newProject, .editProject:
            pageDestination = destination
        }
    }

    private func returnFromEditor(_ project: ProjectProfile) {
        if navigationIndex > 0 {
            navigateBack()
        } else if projectStore.project(id: project.id) != nil {
            apply(.project(project.id))
        } else if let selectedProjectID {
            apply(.project(selectedProjectID))
        } else {
            pageDestination = nil
        }
    }

    private func removeProject(_ project: ProjectProfile) {
        let nextProjectID = selectedProjectID.flatMap { selectedID in
            selectedID == project.id ? nil : projectStore.project(id: selectedID)?.id
        }

        sessionManager.closeSessions(forProjectID: project.id)
        projectStore.delete(id: project.id)
        projectPendingDeletion = nil
        sessionManager.selectedSessionID = nil

        navigationHistory.removeAll { destination in
            switch destination {
            case .project(let projectID), .session(let projectID, _), .editProject(let projectID):
                return projectID == project.id
            case .newProject(let draft):
                return draft.id == project.id
            case .workers, .worker, .settings:
                return false
            }
        }
        navigationIndex = min(navigationIndex, navigationHistory.count - 1)
        selectedProjectID = nil

        if let destinationID = nextProjectID ?? projectStore.projects.first?.id {
            navigate(to: .project(destinationID))
        } else {
            selectedProjectID = nil
            pageDestination = nil
            navigationHistory.removeAll()
            navigationIndex = -1
        }
    }
}

private struct ProjectRemovalConfirmation: View {
    let project: ProjectProfile
    let onCancel: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "trash.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.red)

            VStack(spacing: 7) {
                Text("Remove \(project.displayName)?")
                    .font(.title2.weight(.semibold))
                Text("Open terminals will stop. The GitHub repository and remote files will not be deleted.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 10) {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Remove Project", role: .destructive, action: onRemove)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct SidebarActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SidebarRowGeometry.iconSpacing) {
                Image(systemName: systemImage)
                    .font(.system(size: SidebarRowGeometry.iconSize, weight: .regular))
                    .frame(width: SidebarRowGeometry.iconFrameWidth)
                Text(title)
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(SidebarPalette.primary)
            .padding(.leading, SidebarRowGeometry.contentLeadingPadding)
            .padding(.trailing, SidebarRowGeometry.contentTrailingPadding)
            .frame(height: SidebarRowGeometry.height)
            .background(
                isHovering ? SidebarPalette.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: SidebarRowGeometry.cornerRadius)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SidebarRowGeometry.horizontalMargin)
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
    let onOpenTerminal: (AgentKind) -> Void
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
            HStack(spacing: 4) {
                Button(action: onSelectProject) {
                    HStack(spacing: SidebarRowGeometry.iconSpacing) {
                        Image(systemName: "folder")
                            .font(.system(size: SidebarRowGeometry.iconSize, weight: .regular))
                            .foregroundStyle(SidebarPalette.primary)
                            .frame(width: SidebarRowGeometry.iconFrameWidth)

                        Text(project.displayName)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(SidebarPalette.primary)
                            .lineLimit(1)

                        Spacer(minLength: 6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isProjectHovering {
                    ForEach(AgentKind.allCases) { kind in
                        Button {
                            onOpenTerminal(kind)
                        } label: {
                            AgentBrandIcon(kind: kind, size: 14)
                                .frame(width: 22, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(kind == .claude ? "Claude Code" : kind.displayName) in \(project.displayName)")
                        .accessibilityLabel("Open \(kind.displayName) terminal")
                    }
                }
            }
            .padding(.leading, SidebarRowGeometry.contentLeadingPadding)
            .padding(.trailing, SidebarRowGeometry.contentTrailingPadding)
            .frame(height: SidebarRowGeometry.height)
            .background(
                isProjectHovering ? SidebarPalette.hover : Color.clear,
                in: RoundedRectangle(cornerRadius: SidebarRowGeometry.cornerRadius)
            )
            .contentShape(Rectangle())
            .padding(.horizontal, SidebarRowGeometry.horizontalMargin)
            .onHover { isProjectHovering = $0 }
            .contextMenu {
                Button("Open Codex") { onOpenTerminal(.codex) }
                Button("Open Claude Code") { onOpenTerminal(.claude) }
                Divider()
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
            AgentBrandIcon(kind: session.kind, size: 12)
                .opacity(session.status.occupiesSlot ? 1 : 0.55)

            Text(session.displayTitle)
                .font(.system(size: 14))
                .foregroundStyle(
                    session.status.occupiesSlot
                        ? SidebarPalette.primary
                        : SidebarPalette.secondary
                )
                .lineLimit(1)

            Spacer(minLength: 5)

            sessionStatusIndicator
                .frame(width: 12, height: 12)
                .help(sessionStateLabel)
                .accessibilityLabel(
                    "\(session.kind.displayName), \(sessionStateLabel.lowercased())"
                )
        }
        .padding(.leading, 18)
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

    private var sessionStateLabel: String {
        if session.isWorking { return "Working" }
        if session.status == .running { return "Ready" }
        return session.status.label
    }

    @ViewBuilder
    private var sessionStatusIndicator: some View {
        if session.isWorking {
            ProgressView()
                .controlSize(.mini)
                .tint(SidebarPalette.secondary)
        } else {
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
        }
    }
}
