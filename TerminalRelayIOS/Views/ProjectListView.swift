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
                    }
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

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Terminals", systemImage: "terminal")
                } description: {
                    Text("Start a terminal for this project to work from this device.")
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(sessions) { session in
                    terminalRow(session)
                }
            }
        }
        .navigationTitle(repositoryName)
        .task {
            if model.profile?.id != workerID {
                model.selectProfile(id: workerID)
            }
            await model.refresh()
        }
        .refreshable { await model.refresh() }
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
