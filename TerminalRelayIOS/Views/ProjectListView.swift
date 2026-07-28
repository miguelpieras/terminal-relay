import SwiftUI

private struct StopRequest: Identifiable {
    let kind: AgentKind
    let repositoryName: String
    let instanceToken: String

    var id: String { "\(kind.rawValue):\(repositoryName):\(instanceToken)" }
}

private struct WorkerProject: Identifiable {
    let workerID: UUID
    let workerName: String
    let repositoryName: String
    let sessions: [WorkerSessionSnapshot]
    let threads: [WorkerThreadSnapshot]

    var id: String {
        "\(workerID.uuidString):\(repositoryName)"
    }

    var selection: ProjectSelection {
        ProjectSelection(workerID: workerID, repositoryName: repositoryName)
    }
}

struct ProjectSelection: Hashable, Identifiable {
    let workerID: UUID
    let repositoryName: String

    var id: String {
        "\(workerID.uuidString):\(repositoryName)"
    }
}

struct ProjectListView: View {
    @ObservedObject var model: WorkerSessionModel
    let onAddWorker: () -> Void
    let onExploreDemo: () -> Void
    @Binding private var selection: ProjectSelection?
    private let usesSplitSelection: Bool
    @State private var searchText = ""
    @State private var showsSearch = false
    @State private var workerFilterID: UUID?

    private var projects: [WorkerProject] {
        model.profiles.flatMap { profile -> [WorkerProject] in
            guard workerFilterID == nil || workerFilterID == profile.id,
                  let overview = model.workerOverviews[profile.id] else {
                return []
            }
            return overview.projects.map { repositoryName in
                WorkerProject(
                    workerID: profile.id,
                    workerName: profile.displayName,
                    repositoryName: repositoryName,
                    sessions: overview.sessions.filter {
                        $0.repositoryName == repositoryName
                    },
                    threads: model.threads(
                        workerID: profile.id,
                        repositoryName: repositoryName,
                        archived: false
                    )
                )
            }
        }
        .sorted {
            let projectOrder = $0.repositoryName.localizedStandardCompare($1.repositoryName)
            if projectOrder == .orderedSame {
                return $0.workerName.localizedStandardCompare($1.workerName) == .orderedAscending
            }
            return projectOrder == .orderedAscending
        }
    }

    private var filteredProjects: [WorkerProject] {
        guard !searchText.isEmpty else { return projects }
        return projects.filter {
            $0.repositoryName.localizedCaseInsensitiveContains(searchText)
                || $0.workerName.localizedCaseInsensitiveContains(searchText)
                || ($0.threads + model.threads(
                    workerID: $0.workerID,
                    repositoryName: $0.repositoryName,
                    archived: true
                )).contains {
                    ($0.title ?? "").localizedCaseInsensitiveContains(searchText)
                }
        }
    }

    private var workerFilterName: String {
        guard let workerFilterID,
              let profile = model.profiles.first(where: { $0.id == workerFilterID }) else {
            return "All Workers"
        }
        return profile.displayName
    }

    private var refreshTaskID: String {
        model.profiles
            .map { "\($0.id.uuidString):\($0.host):\($0.port)" }
            .joined(separator: "|")
    }

    init(
        model: WorkerSessionModel,
        onAddWorker: @escaping () -> Void,
        onExploreDemo: @escaping () -> Void
    ) {
        self.model = model
        self.onAddWorker = onAddWorker
        self.onExploreDemo = onExploreDemo
        _selection = .constant(nil)
        usesSplitSelection = false
    }

    init(
        model: WorkerSessionModel,
        selection: Binding<ProjectSelection?>,
        onAddWorker: @escaping () -> Void,
        onExploreDemo: @escaping () -> Void
    ) {
        self.model = model
        self.onAddWorker = onAddWorker
        self.onExploreDemo = onExploreDemo
        _selection = selection
        usesSplitSelection = true
    }

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Pair with the Terminal Relay app on your Mac to load projects and shared agent sessions.")
                } actions: {
                    Button("Scan Mac Pairing Code", action: onAddWorker)
                        .buttonStyle(.borderedProminent)

                    Button("Explore Demo", action: onExploreDemo)
                }
            } else {
                projectList
            }
        }
        .navigationTitle("Projects")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: refreshTaskID) {
            if let workerFilterID,
               !model.profiles.contains(where: { $0.id == workerFilterID }) {
                self.workerFilterID = nil
            }
            await model.refreshProjectCatalogs()
            await model.refreshAllThreads()
            reconcileSelection()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    return
                }
                if model.terminalRoute == nil {
                    await model.refreshProjectActivity()
                }
            }
        }
        .onChange(of: projects.map(\.selection)) { _, _ in
            reconcileSelection()
        }
    }

    @ViewBuilder
    private var projectList: some View {
        if #available(iOS 18.0, *) {
            if showsSearch {
                projectListContent
                    .searchable(
                        text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search Projects"
                    )
            } else {
                projectListContent
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .tracking || newPhase == .interacting {
                            showsSearch = true
                        }
                    }
            }
        } else {
            projectListContent
                .searchable(
                    text: $searchText,
                    placement: .navigationBarDrawer(displayMode: .automatic),
                    prompt: "Search Projects"
                )
        }
    }

    @ViewBuilder
    private var projectListContent: some View {
        if usesSplitSelection {
            List(selection: $selection) {
                projectRows
            }
            .refreshable { await model.refreshProjectCatalogs() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    workerFilter
                }
            }
        } else {
            List {
                projectRows
            }
            .refreshable { await model.refreshProjectCatalogs() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    workerFilter
                }
            }
        }
    }

    @ViewBuilder
    private var projectRows: some View {
        if projects.isEmpty {
            if !model.projectLoadingIDs.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading projects…")
                    Spacer()
                }
                .listRowBackground(Color.clear)
            } else {
                ContentUnavailableView(
                    "No Projects",
                    systemImage: "folder",
                    description: Text(emptyProjectsDescription)
                )
                .listRowBackground(Color.clear)
            }
        } else if filteredProjects.isEmpty {
            ContentUnavailableView.search(text: searchText)
                .listRowBackground(Color.clear)
        } else {
            ForEach(filteredProjects) { project in
                if usesSplitSelection {
                    ProjectListRow(
                        repositoryName: project.repositoryName,
                        workerName: model.profiles.count > 1 ? project.workerName : nil,
                        sessions: project.sessions
                    )
                    .tag(project.selection)
                } else {
                    NavigationLink {
                        ProjectDetailView(
                            workerID: project.workerID,
                            repositoryName: project.repositoryName,
                            model: model
                        )
                    } label: {
                        ProjectListRow(
                            repositoryName: project.repositoryName,
                            workerName: model.profiles.count > 1 ? project.workerName : nil,
                            sessions: project.sessions
                        )
                    }
                }
            }
        }
    }

    private var workerFilter: some View {
        Menu {
            Button {
                workerFilterID = nil
            } label: {
                if workerFilterID == nil {
                    Label("All Workers", systemImage: "checkmark")
                } else {
                    Text("All Workers")
                }
            }

            Divider()

            ForEach(model.profiles) { profile in
                Button {
                    workerFilterID = profile.id
                } label: {
                    if workerFilterID == profile.id {
                        Label(profile.displayName, systemImage: "checkmark")
                    } else {
                        Text(profile.displayName)
                    }
                }
            }

            Divider()

            Button(action: onAddWorker) {
                Label("Pair Another Worker", systemImage: "qrcode.viewfinder")
            }
        } label: {
            Image(systemName: workerFilterID == nil
                ? "line.3.horizontal.decrease.circle"
                : "line.3.horizontal.decrease.circle.fill"
            )
        }
        .accessibilityLabel("Filter projects by worker")
        .accessibilityValue(workerFilterName)
    }

    private var emptyProjectsDescription: String {
        if workerFilterID == nil {
            return "Add a repository under /workspace on a worker, then pull to refresh."
        }
        return "No repositories were found on \(workerFilterName)."
    }

    private func reconcileSelection() {
        guard usesSplitSelection else { return }
        selection = AdaptiveSelectionPolicy.project(
            current: selection,
            available: projects.map(\.selection)
        )
    }
}

private struct ProjectListRow: View {
    let repositoryName: String
    let workerName: String?
    let sessions: [WorkerSessionSnapshot]

    private var isWorking: Bool {
        sessions.contains { $0.isWorking() }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(repositoryName)
                    .font(.body.weight(.medium))
                if let workerName {
                    Text(workerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Working")
            }
        }
        .padding(.vertical, 2)
    }
}

struct ProjectDetailView: View {
    let workerID: UUID
    let repositoryName: String
    @ObservedObject var model: WorkerSessionModel
    @State private var stopRequest: StopRequest?
    @State private var showsNewTerminalOptions = false
    @State private var showsArchivedThreads = false
    @State private var threadPendingRename: WorkerThreadSnapshot?
    @State private var threadName = ""

    private var sessions: [WorkerSessionSnapshot] {
        guard model.profile?.id == workerID else { return [] }
        return model.sessions
            .filter { $0.repositoryName == repositoryName }
            .sorted {
                let titleOrder = ($0.title ?? "").localizedStandardCompare($1.title ?? "")
                if titleOrder == .orderedSame {
                    return $0.instanceToken < $1.instanceToken
                }
                return titleOrder == .orderedAscending
            }
    }

    private var dormantThreads: [WorkerThreadSnapshot] {
        model.threads(
            workerID: workerID,
            repositoryName: repositoryName,
            archived: false
        ).filter { !$0.isActive }
    }

    private var archivedThreads: [WorkerThreadSnapshot] {
        model.threads(
            workerID: workerID,
            repositoryName: repositoryName,
            archived: true
        )
    }

    var body: some View {
        List {
            if sessions.isEmpty && dormantThreads.isEmpty {
                ContentUnavailableView {
                    Label("No Threads", systemImage: "terminal")
                } description: {
                    Text("Start a terminal or create a Codex thread for this project.")
                }
                .listRowBackground(Color.clear)
            }
            if !sessions.isEmpty {
                Section("Active Terminals") {
                    ForEach(sessions) { session in
                        terminalRow(session)
                    }
                }
            }
            if !dormantThreads.isEmpty {
                Section("Paused Threads") {
                    ForEach(dormantThreads) { thread in
                        dormantThreadRow(thread)
                    }
                }
            }
            if !archivedThreads.isEmpty {
                Section {
                    DisclosureGroup(
                        "Archived Threads (\(archivedThreads.count))",
                        isExpanded: $showsArchivedThreads
                    ) {
                        ForEach(archivedThreads) { thread in
                            archivedThreadRow(thread)
                        }
                    }
                }
            }
        }
        .navigationTitle(repositoryName)
        .task {
            if model.profile?.id != workerID {
                model.selectProfile(id: workerID)
            }
            await model.refresh()
            await model.refreshThreads(
                workerID: workerID,
                repositoryName: repositoryName
            )
        }
        .refreshable {
            await model.refresh()
            await model.refreshThreads(
                workerID: workerID,
                repositoryName: repositoryName
            )
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsNewTerminalOptions = true
                } label: {
                    Label("New Terminal", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .confirmationDialog(
            "New Terminal",
            isPresented: $showsNewTerminalOptions,
            titleVisibility: .visible
        ) {
            Button("New Codex Thread") {
                Task {
                    await model.createThread(
                        workerID: workerID,
                        repositoryName: repositoryName
                    )
                }
            }
            ForEach(AgentKind.allCases) { kind in
                Button(kind.displayName) {
                    model.startTerminal(kind: kind, repositoryName: repositoryName)
                }
            }
        }
        .alert(item: $stopRequest) { request in
            Alert(
                title: Text("Stop Terminal?"),
                message: Text("This ends the agent running in \(request.repositoryName) for every attached client. Disconnect if you only want to leave this device."),
                primaryButton: .destructive(Text("Stop Terminal")) {
                    Task {
                        await model.stop(
                            kind: request.kind,
                            repositoryName: request.repositoryName,
                            expectedInstanceToken: request.instanceToken
                        )
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .alert(
            "Rename Thread",
            isPresented: Binding(
                get: { threadPendingRename != nil },
                set: { if !$0 { threadPendingRename = nil } }
            )
        ) {
            TextField("Thread name", text: $threadName)
            Button("Cancel", role: .cancel) {
                threadPendingRename = nil
            }
            Button("Rename") {
                guard let thread = threadPendingRename else { return }
                let name = threadName
                threadPendingRename = nil
                Task {
                    await model.renameThread(
                        workerID: workerID,
                        thread: thread,
                        name: name
                    )
                }
            }
        } message: {
            Text("This changes the provider thread name on this worker.")
        }
    }

    @ViewBuilder
    private func terminalRow(_ session: WorkerSessionSnapshot) -> some View {
        Button {
            model.openTerminal(session)
        } label: {
            HStack(spacing: 12) {
                AgentTaskIcon(kind: session.kind)

                Text(session.title ?? "Untitled terminal")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                if session.isWorking() {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                } else if model.isUnread(session) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("New activity")
                }
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                stopRequest = StopRequest(
                    kind: session.kind,
                    repositoryName: repositoryName,
                    instanceToken: session.instanceToken
                )
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                stopRequest = StopRequest(
                    kind: session.kind,
                    repositoryName: repositoryName,
                    instanceToken: session.instanceToken
                )
            } label: {
                Label("Stop Terminal", systemImage: "stop.fill")
            }
        }
    }

    private func dormantThreadRow(_ thread: WorkerThreadSnapshot) -> some View {
        Button {
            Task { await model.resumeThread(workerID: workerID, thread: thread) }
        } label: {
            HStack(spacing: 12) {
                AgentTaskIcon(kind: thread.kind)
                    .opacity(0.62)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title ?? "Untitled thread")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text("Paused · tap to resume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "play.fill")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            Button(role: .destructive) {
                Task {
                    await model.setThreadArchived(
                        workerID: workerID,
                        thread: thread,
                        archived: true
                    )
                }
            } label: {
                Label("Archive Thread", systemImage: "archivebox")
            }
        }
        .contextMenu {
            Button("Rename Thread") {
                threadName = thread.title ?? ""
                threadPendingRename = thread
            }
            Button("Archive Thread", role: .destructive) {
                Task {
                    await model.setThreadArchived(
                        workerID: workerID,
                        thread: thread,
                        archived: true
                    )
                }
            }
        }
    }

    private func archivedThreadRow(_ thread: WorkerThreadSnapshot) -> some View {
        HStack {
            Label(thread.title ?? "Untitled thread", systemImage: "archivebox")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Unarchive") {
                Task {
                    await model.setThreadArchived(
                        workerID: workerID,
                        thread: thread,
                        archived: false
                    )
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

private struct AgentTaskIcon: View {
    let kind: AgentKind

    private var tint: Color {
        switch kind {
        case .codex: .blue
        case .claude: .orange
        }
    }

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}
