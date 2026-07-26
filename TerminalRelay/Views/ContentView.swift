import AppKit
import SwiftUI

private enum SidebarDestination: Equatable {
    case project(UUID)
    case session(projectID: UUID, sessionID: UUID)
    case workers
    case settings
    case newProject(ProjectProfile)
    case editProject(UUID)
}

private struct SessionArchiveRequest: Identifiable {
    let id = UUID()
    let sessionIDs: Set<UUID>
}

private enum SidebarDragItem: Equatable {
    private static let projectPrefix = "terminal-relay-project:"
    private static let folderPrefix = "terminal-relay-folder:"
    private static let sessionPrefix = "terminal-relay-session:"

    case project(UUID)
    case folder(UUID)
    case session(UUID)

    var value: String {
        switch self {
        case .project(let id): Self.projectPrefix + id.uuidString
        case .folder(let id): Self.folderPrefix + id.uuidString
        case .session(let id): Self.sessionPrefix + id.uuidString
        }
    }

    init?(value: String) {
        if value.hasPrefix(Self.projectPrefix),
           let id = UUID(uuidString: String(value.dropFirst(Self.projectPrefix.count))) {
            self = .project(id)
        } else if value.hasPrefix(Self.folderPrefix),
                  let id = UUID(uuidString: String(value.dropFirst(Self.folderPrefix.count))) {
            self = .folder(id)
        } else if value.hasPrefix(Self.sessionPrefix),
                  let id = UUID(uuidString: String(value.dropFirst(Self.sessionPrefix.count))) {
            self = .session(id)
        } else {
            return nil
        }
    }
}

private enum SidebarDropPosition: Equatable {
    case before
    case after
}

@MainActor
private final class SidebarDragCoordinator: ObservableObject {
    private struct DropTarget {
        let frame: CGRect
        let accepts: (SidebarDragItem) -> Bool
        let position: (SidebarDragItem, CGPoint) -> SidebarDropPosition
        let onDrop: ([String], CGPoint) -> Bool
        let setDropPosition: (SidebarDropPosition?) -> Void
    }

    private var targets: [UUID: DropTarget] = [:]
    private var targetedID: UUID?
    private var targetedPosition: SidebarDropPosition?

    func register(
        id: UUID,
        frame: CGRect,
        accepts: @escaping (SidebarDragItem) -> Bool,
        position: @escaping (SidebarDragItem, CGPoint) -> SidebarDropPosition,
        onDrop: @escaping ([String], CGPoint) -> Bool,
        setDropPosition: @escaping (SidebarDropPosition?) -> Void
    ) {
        targets[id] = DropTarget(
            frame: frame,
            accepts: accepts,
            position: position,
            onDrop: onDrop,
            setDropPosition: setDropPosition
        )
    }

    func unregister(id: UUID) {
        targets[id]?.setDropPosition(nil)
        targets[id] = nil
        if targetedID == id {
            targetedID = nil
            targetedPosition = nil
        }
    }

    func update(item: SidebarDragItem, at location: CGPoint) {
        guard let (id, target) = target(at: location, accepting: item) else {
            setTarget(nil)
            return
        }
        let localLocation = CGPoint(
            x: location.x - target.frame.minX,
            y: location.y - target.frame.minY
        )
        setTarget(id, position: target.position(item, localLocation))
    }

    func finish(item: SidebarDragItem, at location: CGPoint) {
        if let (_, target) = target(at: location, accepting: item) {
            let localLocation = CGPoint(
                x: location.x - target.frame.minX,
                y: location.y - target.frame.minY
            )
            _ = target.onDrop([item.value], localLocation)
        }
        setTarget(nil)
    }

    func cancel() {
        setTarget(nil)
    }

    private func target(
        at location: CGPoint,
        accepting item: SidebarDragItem
    ) -> (key: UUID, value: DropTarget)? {
        targets
            .filter {
                $0.value.frame.contains(location)
                    && $0.value.accepts(item)
            }
            .min {
                ($0.value.frame.width * $0.value.frame.height)
                    < ($1.value.frame.width * $1.value.frame.height)
            }
    }

    private func setTarget(
        _ id: UUID?,
        position: SidebarDropPosition? = nil
    ) {
        guard targetedID != id || targetedPosition != position else { return }
        if let targetedID {
            targets[targetedID]?.setDropPosition(nil)
        }
        targetedID = id
        targetedPosition = position
        if let id, let position {
            targets[id]?.setDropPosition(position)
        }
    }
}

private struct SidebarDropModifier: ViewModifier {
    @EnvironmentObject private var dragCoordinator: SidebarDragCoordinator
    @Binding var dropPosition: SidebarDropPosition?
    let accepts: (SidebarDragItem) -> Bool
    let position: (SidebarDragItem, CGPoint) -> SidebarDropPosition
    let onDrop: ([String], CGPoint) -> Bool

    @State private var targetID = UUID()

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { proxy in
                    Color.clear
                        .allowsHitTesting(false)
                        .onAppear {
                            register(frame: proxy.frame(in: .global))
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in
                            register(frame: frame)
                        }
                }
            }
            .onDisappear {
                dragCoordinator.unregister(id: targetID)
            }
    }

    private func register(frame: CGRect) {
        let displayedPosition = $dropPosition
        dragCoordinator.register(
            id: targetID,
            frame: frame,
            accepts: accepts,
            position: position,
            onDrop: onDrop,
            setDropPosition: { displayedPosition.wrappedValue = $0 }
        )
    }
}

private struct SidebarDragSourceModifier: ViewModifier {
    @EnvironmentObject private var dragCoordinator: SidebarDragCoordinator
    let item: SidebarDragItem

    @State private var isDragging = false

    func body(content: Content) -> some View {
        content
            .opacity(isDragging ? 0.72 : 1)
            .simultaneousGesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .global)
                    .onChanged { value in
                        isDragging = true
                        dragCoordinator.update(item: item, at: value.location)
                    }
                    .onEnded { value in
                        dragCoordinator.finish(item: item, at: value.location)
                        isDragging = false
                    }
            )
            .onDisappear {
                if isDragging {
                    dragCoordinator.cancel()
                }
            }
    }
}

private extension View {
    func sidebarDragSource(_ item: SidebarDragItem) -> some View {
        modifier(SidebarDragSourceModifier(item: item))
    }

    func sidebarDropDestination(
        dropPosition: Binding<SidebarDropPosition?>,
        accepts: @escaping (SidebarDragItem) -> Bool,
        position: @escaping (SidebarDragItem, CGPoint) -> SidebarDropPosition,
        onDrop: @escaping ([String], CGPoint) -> Bool
    ) -> some View {
        modifier(
            SidebarDropModifier(
                dropPosition: dropPosition,
                accepts: accepts,
                position: position,
                onDrop: onDrop
            )
        )
    }

    func sidebarDropIndicator(_ position: SidebarDropPosition?) -> some View {
        overlay {
            if let position {
                VStack(spacing: 0) {
                    if position == .after {
                        Spacer(minLength: 0)
                    }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(height: 2)
                    if position == .before {
                        Spacer(minLength: 0)
                    }
                }
                .allowsHitTesting(false)
            }
        }
    }
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
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var workerSessionService: WorkerSessionService
    @EnvironmentObject private var accountUsageService: AccountUsageService

    @StateObject private var accountAuthenticationService = AccountAuthenticationService()
    @StateObject private var sidebarDragCoordinator = SidebarDragCoordinator()

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
    @State private var searchQuery = ""
    @State private var navigationHistory: [SidebarDestination] = []
    @State private var navigationIndex = -1
    @State private var selectedSessionIDs: Set<UUID> = []
    @State private var sessionArchiveRequest: SessionArchiveRequest?
    @State private var isNamingSidebarFolder = false
    @State private var newSidebarFolderName = ""
    @State private var expandedSidebarFolderIDs: Set<UUID> = []
    @FocusState private var isProjectFilterFocused: Bool

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
        guard !query.isEmpty else { return projectStore.sidebarProjects }

        return projectStore.sidebarProjects.filter { project in
            project.displayName.localizedCaseInsensitiveContains(query)
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
        presentedContent
            .environmentObject(sidebarDragCoordinator)
            .sheet(
                item: $accountAuthenticationService.presentation,
                onDismiss: accountAuthenticationService.dismiss
            ) { presentation in
                AccountAuthenticationView(presentation: presentation)
                    .environmentObject(accountAuthenticationService)
                    .environmentObject(accountUsageService)
            }
    }

    private var presentedContent: some View {
        lifecycleContent
            .alert("New Parent Folder", isPresented: $isNamingSidebarFolder) {
                TextField("Folder name", text: $newSidebarFolderName)
                Button("Cancel", role: .cancel) {
                    newSidebarFolderName = ""
                }
                Button("Create") {
                    createSidebarFolder()
                }
            } message: {
                Text("Create a parent folder for projects in the sidebar.")
            }
            .confirmationDialog(
                archiveConfirmationTitle,
                isPresented: isShowingArchiveConfirmation,
                titleVisibility: .visible
            ) {
                if let request = sessionArchiveRequest {
                    Button(
                        request.sessionIDs.count == 1 ? "Archive" : "Archive All",
                        role: .destructive
                    ) {
                        sessionArchiveRequest = nil
                        archiveSessions(request.sessionIDs)
                    }
                }
                Button("Cancel", role: .cancel) {
                    sessionArchiveRequest = nil
                }
            } message: {
                Text(
                    "Running agents will be stopped and the selected terminal rows will be removed. Project files are not deleted."
                )
            }
    }

    private var lifecycleContent: some View {
        navigationContent
            .onAppear {
                selectFirstProjectIfNeeded()
                clearInitialFilterFocus()
            }
            .onChange(of: projectStore.projects) { _, _ in selectFirstProjectIfNeeded() }
            .onChange(of: sessionManager.sessions.map(\.id)) { _, sessionIDs in
                selectedSessionIDs.formIntersection(sessionIDs)
            }
            .onChange(of: sessionManager.selectedSessionID) { _, sessionID in
                selectedSessionIDs = sessionID.map { [$0] } ?? []
            }
            .onChange(of: serverStore.servers) { _, workers in
                projectStore.updateServers(workers)
            }
            .onChange(of: selectedProjectID) { _, projectID in
                updateSelectedSession(for: projectID)
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await refreshWorkerSessions() }
            }
            .task(id: workerStatusTaskID) {
                repeat {
                    await refreshWorkerSessions()
                    do {
                        try await Task.sleep(for: .seconds(15))
                    } catch {
                        return
                    }
                } while !Task.isCancelled
            }
    }

    private var navigationContent: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 268, ideal: 268, max: 268)
                .overlay(alignment: .topLeading) {
                    titlebarNavigationControls
                }
        } detail: {
            detail
        }
        .environmentObject(accountAuthenticationService)
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
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            sidebarCreationButtons
            sidebarProjectFilter

            Rectangle()
                .fill(SidebarPalette.separator)
                .frame(height: 1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    sidebarProjectList

                    if !searchQuery.isEmpty && visibleProjects.isEmpty {
                        Text("No matching projects")
                            .font(.system(size: 13.5))
                            .foregroundStyle(SidebarPalette.tertiary)
                            .padding(.horizontal, 15)
                            .padding(.top, 18)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollIndicators(.hidden)
            .contextMenu {
                sidebarCreationMenu
            }

            sidebarFooter
        }
        .background(SidebarPalette.background)
    }

    @ViewBuilder
    private var sidebarProjectList: some View {
        if !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ForEach(visibleProjects) { project in
                projectSidebarSection(project, folderID: nil)
            }
        } else {
            ForEach(projectStore.rootProjects) { project in
                projectSidebarSection(project, folderID: nil)
            }

            ForEach(projectStore.sidebarFolders) { folder in
                SidebarFolderRow(
                    title: folder.name,
                    isExpanded: expandedSidebarFolderIDs.contains(folder.id),
                    onToggle: {
                        toggleSidebarFolder(folder.id)
                    },
                    acceptsDrop: { item in
                        switch item {
                        case .project:
                            return true
                        case .folder(let movingFolderID):
                            return movingFolderID != folder.id
                        case .session:
                            return false
                        }
                    },
                    onDrop: { values, location in
                        handleSidebarFolderDrop(
                            values,
                            at: location,
                            targetFolderID: folder.id
                        )
                    }
                )
                .sidebarDragSource(.folder(folder.id))
                .contextMenu {
                    sidebarCreationMenu
                    Divider()
                    Button("Delete Folder", role: .destructive) {
                        projectStore.deleteSidebarFolder(id: folder.id)
                    }
                }

                if expandedSidebarFolderIDs.contains(folder.id) {
                    ForEach(projectStore.projects(inSidebarFolder: folder.id)) { project in
                        projectSidebarSection(project, folderID: folder.id)
                    }
                }
            }
        }
    }

    private func projectSidebarSection(
        _ project: ProjectProfile,
        folderID: UUID?
    ) -> some View {
        ProjectSidebarSection(
            project: project,
            searchQuery: searchQuery,
            selectedSessionID: sessionManager.selectedSessionID,
            selectedSessionIDs: selectedSessionIDs,
            onSelectProject: {
                selectedSessionIDs.removeAll()
                navigate(to: .project(project.id))
            },
            onSelectSession: { sessionID, usesCommandModifier in
                selectSession(
                    sessionID,
                    for: project,
                    usesCommandModifier: usesCommandModifier
                )
            },
            onArchiveSession: presentArchiveConfirmation,
            onOpenTerminal: { kind in
                openTerminal(kind, for: project)
            },
            onNewProject: addProject,
            onNewParentFolder: beginCreatingSidebarFolder,
            onEdit: { navigate(to: .editProject(project.id)) },
            onRemove: { projectPendingDeletion = project },
            acceptsProjectDrop: { item in
                guard case .project(let movingProjectID) = item,
                      movingProjectID != project.id else {
                    return false
                }
                return true
            },
            onDropProject: { values, location in
                handleProjectDrop(
                    values,
                    at: location,
                    before: project.id,
                    intoSidebarFolder: folderID
                )
            }
        )
    }

    @ViewBuilder
    private var sidebarHeader: some View {
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
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .frame(height: 42)
    }

    private var sidebarCreationButtons: some View {
        HStack(spacing: 0) {
            SidebarActionButton(
                title: "New project",
                systemImage: "square.and.pencil",
                action: addProject
            )
            .keyboardShortcut("n", modifiers: .command)

            Button {
                beginCreatingSidebarFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(SidebarPalette.primary)
                    .frame(width: 30, height: SidebarRowGeometry.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, SidebarRowGeometry.horizontalMargin)
            .help("New parent folder")
            .accessibilityLabel("New Parent Folder")
        }
    }

    private var sidebarProjectFilter: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SidebarPalette.tertiary)

            TextField("Filter projects", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(SidebarPalette.primary)
                .focused($isProjectFilterFocused)
                .onSubmit {
                    isProjectFilterFocused = false
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(SidebarPalette.tertiary)
                .help("Clear project filter")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 27)
        .background(SidebarPalette.hover, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
    }

    @ViewBuilder
    private var sidebarCreationMenu: some View {
        Button("New Project", systemImage: "square.and.pencil", action: addProject)
        Button("New Parent Folder", systemImage: "folder.badge.plus") {
            beginCreatingSidebarFolder()
        }
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
            WorkersView(onSelectProject: { projectID in
                navigate(to: .project(projectID))
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
                onShowWorkers: { navigate(to: .workers) }
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

        Task {
            guard let result = await sessionManager.openAfterRefresh(
                project: project,
                on: worker,
                kind: kind,
                projects: projectStore.projects,
                launchDefaults: launchDefaults,
                using: workerSessionService
            ) else { return }
            handleOpenResult(result, for: project)
        }
    }

    private func handleOpenResult(
        _ result: SessionOpenResult,
        for project: ProjectProfile
    ) {
        switch result {
        case .opened(let session), .selectedExisting(let session):
            navigate(to: .session(projectID: session.projectID, sessionID: session.id))
        case .occupied(let occupant):
            if let session = occupant.localSession {
                navigate(to: .session(projectID: session.projectID, sessionID: session.id))
            } else {
                navigate(to: .project(project.id))
            }
        }
    }

    private func selectSession(
        _ sessionID: UUID,
        for project: ProjectProfile,
        usesCommandModifier: Bool
    ) {
        if usesCommandModifier {
            if selectedSessionIDs.contains(sessionID) {
                selectedSessionIDs.remove(sessionID)
            } else {
                selectedSessionIDs.insert(sessionID)
            }
            return
        }
        selectedSessionIDs = [sessionID]
        navigate(to: .session(projectID: project.id, sessionID: sessionID))

        guard let session = sessionManager.sessions(forProjectID: project.id)
            .first(where: { $0.id == sessionID }),
              session.status.canReconnect,
              let worker = serverStore.server(id: project.serverID) else {
            return
        }

        Task {
            _ = await sessionManager.reconnectAfterRefresh(
                sessionID: sessionID,
                project: project,
                on: worker,
                projects: projectStore.projects,
                launchDefaults: launchDefaults,
                using: workerSessionService
            )
        }
    }

    private var workerStatusTaskID: String {
        let workers = serverStore.servers.map(\.id.uuidString).sorted().joined(separator: ",")
        let projects = projectStore.projects
            .map { "\($0.id.uuidString):\($0.serverID.uuidString):\($0.displayName)" }
            .sorted()
            .joined(separator: ",")
        return "\(workers)|\(projects)"
    }

    private func refreshWorkerSessions() async {
        for worker in serverStore.servers {
            guard !Task.isCancelled else { return }
            let didRefresh = await sessionManager.refresh(
                worker: worker,
                projects: projectStore.projects,
                launchDefaults: launchDefaults,
                using: workerSessionService
            )
            if didRefresh {
                sessionManager.preloadRemoteSessions(for: worker)
            }
        }
    }

    private func selectFirstProjectIfNeeded() {
        if selectedProjectID == nil || projectStore.project(id: selectedProjectID) == nil {
            selectedProjectID = projectStore.sidebarProjects.first?.id
            sessionManager.selectedSessionID = nil
        }
    }

    private func updateSelectedSession(for projectID: UUID?) {
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

    private var archiveConfirmationTitle: String {
        guard let count = sessionArchiveRequest?.sessionIDs.count, count > 1 else {
            return "Archive terminal?"
        }
        return "Archive \(count) terminals?"
    }

    private var isShowingArchiveConfirmation: Binding<Bool> {
        Binding(
            get: { sessionArchiveRequest != nil },
            set: { isPresented in
                if !isPresented {
                    sessionArchiveRequest = nil
                }
            }
        )
    }

    private func createSidebarFolder() {
        guard let folder = projectStore.createSidebarFolder(named: newSidebarFolderName) else {
            return
        }
        expandedSidebarFolderIDs.insert(folder.id)
        newSidebarFolderName = ""
    }

    private func beginCreatingSidebarFolder() {
        newSidebarFolderName = ""
        isNamingSidebarFolder = true
    }

    private func clearInitialFilterFocus() {
        isProjectFilterFocused = false
        DispatchQueue.main.async {
            isProjectFilterFocused = false
        }
    }

    private func toggleSidebarFolder(_ folderID: UUID) {
        if expandedSidebarFolderIDs.contains(folderID) {
            expandedSidebarFolderIDs.remove(folderID)
        } else {
            expandedSidebarFolderIDs.insert(folderID)
        }
    }

    private func handleRootFolderDrop(_ values: [String], _: CGPoint) -> Bool {
        guard let value = values.first,
              case .project(let projectID) = SidebarDragItem(value: value) else {
            return false
        }
        projectStore.moveProject(id: projectID, intoSidebarFolder: nil)
        return true
    }

    private func handleSidebarFolderDrop(
        _ values: [String],
        at location: CGPoint,
        targetFolderID: UUID
    ) -> Bool {
        guard let value = values.first,
              let item = SidebarDragItem(value: value) else {
            return false
        }

        switch item {
        case .project(let projectID):
            projectStore.moveProject(id: projectID, intoSidebarFolder: targetFolderID)
            expandedSidebarFolderIDs.insert(targetFolderID)
        case .folder(let movingFolderID):
            guard movingFolderID != targetFolderID else { return true }
            let targetID = location.y > 15
                ? sidebarFolderID(after: targetFolderID)
                : targetFolderID
            projectStore.moveSidebarFolder(id: movingFolderID, before: targetID)
        case .session:
            return false
        }
        return true
    }

    private func handleProjectDrop(
        _ values: [String],
        at location: CGPoint,
        before targetProjectID: UUID,
        intoSidebarFolder folderID: UUID?
    ) -> Bool {
        guard let value = values.first,
              case .project(let projectID) = SidebarDragItem(value: value) else {
            return false
        }
        guard projectID != targetProjectID else { return true }
        guard projectStore.sidebarFolderID(containing: projectID) == folderID else {
            return false
        }
        let targetID = location.y > SidebarRowGeometry.height / 2
            ? nextProjectID(after: targetProjectID, inSidebarFolder: folderID)
            : targetProjectID
        projectStore.moveProject(
            id: projectID,
            before: targetID,
            intoSidebarFolder: folderID
        )
        return true
    }

    private func sidebarFolderID(after folderID: UUID) -> UUID? {
        guard let index = projectStore.sidebarFolders.firstIndex(where: { $0.id == folderID }) else {
            return nil
        }
        let nextIndex = projectStore.sidebarFolders.index(after: index)
        return nextIndex < projectStore.sidebarFolders.endIndex
            ? projectStore.sidebarFolders[nextIndex].id
            : nil
    }

    private func nextProjectID(after projectID: UUID, inSidebarFolder folderID: UUID?) -> UUID? {
        let projects = folderID.map(projectStore.projects(inSidebarFolder:))
            ?? projectStore.rootProjects
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else {
            return nil
        }
        let nextIndex = projects.index(after: index)
        return nextIndex < projects.endIndex ? projects[nextIndex].id : nil
    }

    private func presentArchiveConfirmation(_ sessionID: UUID) {
        let sessionIDs = selectedSessionIDs.contains(sessionID)
            ? selectedSessionIDs
            : Set([sessionID])
        sessionArchiveRequest = SessionArchiveRequest(sessionIDs: sessionIDs)
    }

    private func archiveSessions(_ sessionIDs: Set<UUID>) {
        Task {
            var archivedSessionIDs = Set<UUID>()

            for sessionID in sessionIDs {
                guard let session = sessionManager.sessions.first(where: { $0.id == sessionID }),
                      let worker = serverStore.servers.first(where: {
                          $0.concurrencyKey == session.serverKey
                      }) else {
                    continue
                }

                let didArchive: Bool
                if session.status.occupiesSlot {
                    didArchive = await sessionManager.stopAgentAfterRefresh(
                        sessionID: sessionID,
                        on: worker,
                        projects: projectStore.projects,
                        launchDefaults: launchDefaults,
                        using: workerSessionService
                    )
                    if didArchive {
                        sessionManager.close(sessionID: sessionID)
                    }
                } else {
                    sessionManager.close(sessionID: sessionID)
                    didArchive = true
                }

                if didArchive {
                    archivedSessionIDs.insert(sessionID)
                }
            }

            selectedSessionIDs.subtract(archivedSessionIDs)
        }
    }

    private func navigate(to destination: SidebarDestination) {
        projectPendingDeletion = nil
        isProjectFilterFocused = false

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
        case .workers, .settings, .newProject, .editProject:
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
            case .workers, .settings:
                return false
            }
        }
        navigationIndex = min(navigationIndex, navigationHistory.count - 1)
        selectedProjectID = nil

        if let destinationID = nextProjectID ?? projectStore.sidebarProjects.first?.id {
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
                Text("Open terminals will disconnect. Remote agents, the GitHub repository, and remote files will not be deleted.")
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
        .frame(maxWidth: .infinity)
        .onHover { isHovering = $0 }
    }
}

private struct SidebarFolderRow: View {
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let acceptsDrop: (SidebarDragItem) -> Bool
    let onDrop: ([String], CGPoint) -> Bool

    @State private var isHovering = false
    @State private var dropPosition: SidebarDropPosition?

    var body: some View {
        HStack(spacing: SidebarRowGeometry.iconSpacing) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundStyle(SidebarPalette.secondary)
                .frame(width: SidebarRowGeometry.iconFrameWidth)

            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(SidebarPalette.secondary)
                .lineLimit(1)

            Spacer()

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(SidebarPalette.secondary)
                .frame(width: 11)
        }
        .padding(.horizontal, SidebarRowGeometry.contentLeadingPadding)
        .frame(height: 30)
        .background(
            isHovering && dropPosition == nil ? SidebarPalette.hover : Color.clear,
            in: RoundedRectangle(cornerRadius: SidebarRowGeometry.cornerRadius)
        )
        .sidebarDropIndicator(dropPosition)
        .contentShape(Rectangle())
        .padding(.horizontal, SidebarRowGeometry.horizontalMargin)
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onToggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onToggle() }
        .sidebarDropDestination(
            dropPosition: $dropPosition,
            accepts: acceptsDrop,
            position: { item, location in
                if case .project = item {
                    return .after
                }
                return location.y > 15 ? .after : .before
            },
            onDrop: onDrop
        )
        .help("Drop a project folder here to move it into this parent folder")
    }
}

private struct ProjectSidebarSection: View {
    @EnvironmentObject private var sessionManager: SessionManager

    let project: ProjectProfile
    let searchQuery: String
    let selectedSessionID: UUID?
    let selectedSessionIDs: Set<UUID>
    let onSelectProject: () -> Void
    let onSelectSession: (UUID, Bool) -> Void
    let onArchiveSession: (UUID) -> Void
    let onOpenTerminal: (AgentKind) -> Void
    let onNewProject: () -> Void
    let onNewParentFolder: () -> Void
    let onEdit: () -> Void
    let onRemove: () -> Void
    let acceptsProjectDrop: (SidebarDragItem) -> Bool
    let onDropProject: ([String], CGPoint) -> Bool

    @State private var isCollapsed = false
    @State private var isExpanded = false
    @State private var isProjectHovering = false
    @State private var projectDropPosition: SidebarDropPosition?

    private var allSessions: [TerminalSession] {
        sessionManager.sidebarSessions(forProjectID: project.id)
    }

    private var sessionsWithThreadIDs: [TerminalSession] {
        allSessions.filter { $0.threadID != nil }
    }

    private var localProjectURL: URL? {
        let fileManager = FileManager.default
        let homeDirectory = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            URL(fileURLWithPath: project.workingDirectory, isDirectory: true),
            homeDirectory.appendingPathComponent("dev/\(project.displayName)", isDirectory: true),
            homeDirectory.appendingPathComponent("Developer/\(project.displayName)", isDirectory: true),
            homeDirectory.appendingPathComponent("Projects/\(project.displayName)", isDirectory: true),
        ]

        return candidates.first { candidate in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    private var projectReferencePath: String {
        localProjectURL?.path ?? project.workingDirectory
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
                .onTapGesture {
                    onSelectProject()
                    isCollapsed.toggle()
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    onSelectProject()
                    isCollapsed.toggle()
                }

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

                Button {
                    isCollapsed.toggle()
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(SidebarPalette.secondary)
                        .frame(width: 18, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isCollapsed ? "Show project terminals" : "Hide project terminals")
                .accessibilityLabel(
                    isCollapsed ? "Expand \(project.displayName)" : "Collapse \(project.displayName)"
                )
            }
            .padding(.leading, SidebarRowGeometry.contentLeadingPadding)
            .padding(.trailing, SidebarRowGeometry.contentTrailingPadding)
            .frame(height: SidebarRowGeometry.height)
            .background(
                isProjectHovering && projectDropPosition == nil
                    ? SidebarPalette.hover
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: SidebarRowGeometry.cornerRadius)
            )
            .sidebarDropIndicator(projectDropPosition)
            .contentShape(Rectangle())
            .padding(.horizontal, SidebarRowGeometry.horizontalMargin)
            .onHover { isProjectHovering = $0 }
            .sidebarDragSource(.project(project.id))
            .sidebarDropDestination(
                dropPosition: $projectDropPosition,
                accepts: acceptsProjectDrop,
                position: { _, location in
                    location.y > SidebarRowGeometry.height / 2 ? .after : .before
                },
                onDrop: onDropProject
            )
            .contextMenu {
                Button("New Project", systemImage: "square.and.pencil", action: onNewProject)
                Button("New Parent Folder", systemImage: "folder.badge.plus", action: onNewParentFolder)
                Divider()
                Button("Open Codex") { onOpenTerminal(.codex) }
                Button("Open Claude Code") { onOpenTerminal(.claude) }
                Divider()
                projectReferenceMenu
                Divider()
                Button("Edit Project", action: onEdit)
                Divider()
                Button("Remove Project", role: .destructive, action: onRemove)
            }

            if !isCollapsed {
                if matchingSessions.isEmpty {
                    Text("No sessions")
                        .font(.system(size: 14))
                        .foregroundStyle(SidebarPalette.tertiary)
                        .padding(.leading, 40)
                        .padding(.trailing, 12)
                        .frame(height: 35, alignment: .leading)
                } else {
                    ForEach(visibleSessions) { session in
                        ProjectSessionRow(
                            session: session,
                            isSelected: selectedSessionID == session.id
                                || selectedSessionIDs.contains(session.id),
                            archiveCount: selectedSessionIDs.contains(session.id)
                                ? max(1, selectedSessionIDs.count)
                                : 1,
                            onSelect: {
                                onSelectSession(
                                    session.id,
                                    NSEvent.modifierFlags.contains(.command)
                                )
                            },
                            onArchive: {
                                onArchiveSession(session.id)
                            },
                            acceptsDrop: { item in
                                guard case .session(let movingSessionID) = item,
                                      movingSessionID != session.id,
                                      let movingSession = sessionManager.sessions.first(where: {
                                          $0.id == movingSessionID
                                      }) else {
                                    return false
                                }
                                return movingSession.projectID == project.id
                            },
                            onDrop: { values, location in
                                handleSessionDrop(
                                    values,
                                    at: location,
                                    before: session.id
                                )
                            }
                        )
                        .contextMenu {
                            Button(
                                "New Project",
                                systemImage: "square.and.pencil",
                                action: onNewProject
                            )
                            Button(
                                "New Parent Folder",
                                systemImage: "folder.badge.plus",
                                action: onNewParentFolder
                            )
                            Divider()
                            Group {
                                if session.status.isLocallyAttached {
                                    Button("Disconnect") {
                                        sessionManager.disconnect(sessionID: session.id)
                                    }
                                } else if session.status.canReconnect {
                                    Button("Reconnect") {
                                        onSelectSession(session.id, false)
                                    }
                                } else {
                                    Button("Close Session") {
                                        sessionManager.close(sessionID: session.id)
                                    }
                                }
                            }
                            .disabled(session.status == .stopping)
                            Divider()
                            Button("Copy Thread ID", systemImage: "number") {
                                if let threadID = session.threadID {
                                    copyToPasteboard(threadID)
                                }
                            }
                            .disabled(session.threadID == nil)
                            Button("Copy Path", systemImage: "document.on.document") {
                                copyToPasteboard(projectReferencePath)
                            }
                            Button("Open in Finder", systemImage: "folder") {
                                openProjectInFinder()
                            }
                            .disabled(localProjectURL == nil)
                            Divider()
                            Button("Archive Terminal", role: .destructive) {
                                onArchiveSession(session.id)
                            }
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
        }
        .padding(.bottom, 8)
        .onChange(of: searchQuery) { _, query in
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                isCollapsed = false
            }
        }
    }

    @ViewBuilder
    private var projectReferenceMenu: some View {
        if sessionsWithThreadIDs.count == 1,
           let threadID = sessionsWithThreadIDs.first?.threadID {
            Button("Copy Thread ID", systemImage: "number") {
                copyToPasteboard(threadID)
            }
        } else if sessionsWithThreadIDs.count > 1 {
            Menu {
                ForEach(sessionsWithThreadIDs) { session in
                    Button(session.displayTitle) {
                        if let threadID = session.threadID {
                            copyToPasteboard(threadID)
                        }
                    }
                }
            } label: {
                Label("Copy Thread ID", systemImage: "number")
            }
        } else {
            Button("Copy Thread ID", systemImage: "number") {}
                .disabled(true)
        }

        Button("Copy Path", systemImage: "document.on.document") {
            copyToPasteboard(projectReferencePath)
        }

        Button("Open in Finder", systemImage: "folder") {
            openProjectInFinder()
        }
        .disabled(localProjectURL == nil)
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func openProjectInFinder() {
        guard let localProjectURL else { return }
        NSWorkspace.shared.open(localProjectURL)
    }

    private func handleSessionDrop(
        _ values: [String],
        at location: CGPoint,
        before targetSessionID: UUID
    ) -> Bool {
        guard let value = values.first,
              case .session(let sessionID) = SidebarDragItem(value: value),
              let movingSession = sessionManager.sessions.first(where: { $0.id == sessionID }),
              movingSession.projectID == project.id else {
            return false
        }
        guard sessionID != targetSessionID else { return true }

        let targetID: UUID?
        if location.y > SidebarRowGeometry.height / 2,
           let index = allSessions.firstIndex(where: { $0.id == targetSessionID }) {
            targetID = allSessions
                .dropFirst(index + 1)
                .first(where: { $0.id != sessionID })?
                .id
        } else {
            targetID = targetSessionID
        }
        sessionManager.moveSidebarSession(id: sessionID, before: targetID)
        return true
    }
}

private struct ProjectSessionRow: View {
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let archiveCount: Int
    let onSelect: () -> Void
    let onArchive: () -> Void
    let acceptsDrop: (SidebarDragItem) -> Bool
    let onDrop: ([String], CGPoint) -> Bool

    @State private var isHovering = false
    @State private var dropPosition: SidebarDropPosition?

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onSelect) {
                HStack(spacing: 7) {
                    AgentBrandIcon(kind: session.kind, size: 17)
                        .frame(width: 18, height: 18)
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

                    if session.isWorking {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(SidebarPalette.secondary)
                            .frame(width: 12, height: 12)
                            .help("Working")
                            .accessibilityLabel("\(session.kind.displayName), working")
                    }
                }
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(.plain)

            if isHovering {
                Button(action: onArchive) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SidebarPalette.secondary)
                        .frame(width: 19, height: 25)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(session.status == .stopping)
                .help(
                    archiveCount == 1
                        ? "Archive terminal"
                        : "Archive \(archiveCount) selected terminals"
                )
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 35)
        .background(
            isSelected
                ? SidebarPalette.selected
                : (
                    isHovering && dropPosition == nil
                        ? SidebarPalette.hover
                        : Color.clear
                ),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .sidebarDropIndicator(dropPosition)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .sidebarDragSource(.session(session.id))
        .sidebarDropDestination(
            dropPosition: $dropPosition,
            accepts: acceptsDrop,
            position: { _, location in
                location.y > SidebarRowGeometry.height / 2 ? .after : .before
            },
            onDrop: onDrop
        )
        .accessibilityLabel("\(session.displayTitle), \(sessionStateLabel.lowercased())")
    }

    private var sessionStateLabel: String {
        if session.isWorking { return "Working" }
        if session.status == .running { return "Ready" }
        return session.status.label
    }

}
