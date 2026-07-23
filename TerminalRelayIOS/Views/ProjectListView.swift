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
}

struct ProjectListView: View {
    @ObservedObject var model: WorkerSessionModel
    let onAddWorker: () -> Void
    @State private var searchText = ""
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

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Projects", systemImage: "folder")
                } description: {
                    Text("Add a worker to load its projects and shared agent sessions.")
                } actions: {
                    Button("Add Worker", action: onAddWorker)
                        .buttonStyle(.borderedProminent)
                }
            } else {
                projectList
            }
        }
        .navigationTitle("Projects")
        .task(id: refreshTaskID) {
            if let workerFilterID,
               !model.profiles.contains(where: { $0.id == workerFilterID }) {
                self.workerFilterID = nil
            }
            await model.refreshProjectCatalogs()
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            workerFilter

            List {
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
                        NavigationLink {
                            ProjectDetailView(
                                workerID: project.workerID,
                                repositoryName: project.repositoryName,
                                model: model
                            )
                        } label: {
                            ProjectListRow(
                                repositoryName: project.repositoryName,
                                workerName: project.workerName,
                                sessions: project.sessions
                            )
                        }
                    }
                }
            }
            .refreshable { await model.refreshProjectCatalogs() }
        }
        .searchable(text: $searchText, prompt: "Search Projects")
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
                Label("Add Worker", systemImage: "plus")
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal.decrease")
                Text(workerFilterName)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.thinMaterial, in: Capsule())
            .contentShape(Rectangle())
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .systemBackground))
        .overlay(alignment: .bottom) {
            Divider()
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
}

private struct ProjectListRow: View {
    let repositoryName: String
    let workerName: String
    let sessions: [WorkerSessionSnapshot]

    private var activeTerminalCount: Int {
        sessions.filter { $0.repositoryName == repositoryName }.count
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(repositoryName)
                    .font(.body.weight(.medium))
                HStack(spacing: 5) {
                    Text(workerName)
                    Text("·")
                    if activeTerminalCount == 0 {
                        Text("No active terminals")
                    } else {
                        Text("\(activeTerminalCount) active \(activeTerminalCount == 1 ? "terminal" : "terminals")")
                            .foregroundStyle(.green)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProjectDetailView: View {
    let workerID: UUID
    let repositoryName: String
    @ObservedObject var model: WorkerSessionModel
    @State private var stopRequest: StopRequest?
    @State private var showsNewTerminalOptions = false

    private var sessions: [WorkerSessionSnapshot] {
        guard model.profile?.id == workerID else { return [] }
        return model.sessions
            .filter { $0.repositoryName == repositoryName }
            .sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private var canStartTerminal: Bool {
        AgentKind.allCases.contains { model.session(for: $0) == nil }
    }

    var body: some View {
        List {
            if sessions.isEmpty {
                ContentUnavailableView {
                    Label("No Active Terminals", systemImage: "terminal")
                } description: {
                    Text("Start a terminal for this project to work from your iPhone.")
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
                .disabled(!canStartTerminal)
            }
        }
        .confirmationDialog(
            "New Terminal",
            isPresented: $showsNewTerminalOptions,
            titleVisibility: .visible
        ) {
            ForEach(AgentKind.allCases) { kind in
                Button(kind.displayName) {
                    model.openTerminal(kind: kind, repositoryName: repositoryName)
                }
                .disabled(model.session(for: kind) != nil)
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
            model.openTerminal(kind: session.kind, repositoryName: repositoryName)
        } label: {
            HStack(spacing: 12) {
                AgentTaskIcon(kind: session.kind)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.kind.displayName)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(attachedClientLabel(session.attachedClientCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Active")

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
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

    private func attachedClientLabel(_ count: Int) -> String {
        switch count {
        case 0: "Ready"
        case 1: "1 client attached"
        default: "\(count) clients attached"
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
