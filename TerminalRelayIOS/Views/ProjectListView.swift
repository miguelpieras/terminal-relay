import SwiftUI

private struct StopRequest: Identifiable {
    let kind: AgentKind
    let repositoryName: String
    let instanceToken: String

    var id: String { "\(kind.rawValue):\(repositoryName):\(instanceToken)" }
}

struct ProjectListView: View {
    @ObservedObject var model: WorkerSessionModel
    let onAddWorker: () -> Void
    @State private var searchText = ""

    private var filteredProjects: [String] {
        guard !searchText.isEmpty else { return model.projects }
        return model.projects.filter {
            $0.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if model.profile == nil {
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
        .task(id: model.profile?.id) {
            await model.refresh()
        }
    }

    private var projectList: some View {
        List {
            if model.projects.isEmpty {
                if model.isLoading {
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
                        description: Text("Add a repository under /workspace on this worker, then pull to refresh.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else if filteredProjects.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(filteredProjects, id: \.self) { repositoryName in
                    NavigationLink {
                        ProjectDetailView(
                            repositoryName: repositoryName,
                            model: model
                        )
                    } label: {
                        ProjectListRow(
                            repositoryName: repositoryName,
                            sessions: model.sessions
                        )
                    }
                }
            }
        }
        .refreshable { await model.refresh() }
        .searchable(text: $searchText, prompt: "Search Projects")
    }
}

private struct ProjectListRow: View {
    let repositoryName: String
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
                if activeTerminalCount == 0 {
                    Text("No active terminals")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(activeTerminalCount) active \(activeTerminalCount == 1 ? "terminal" : "terminals")")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ProjectDetailView: View {
    let repositoryName: String
    @ObservedObject var model: WorkerSessionModel
    @State private var stopRequest: StopRequest?

    private var sessions: [WorkerSessionSnapshot] {
        model.sessions
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
                } actions: {
                    newTerminalMenu
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(sessions) { session in
                    terminalRow(session)
                }
            }
        }
        .navigationTitle(repositoryName)
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                newTerminalMenu
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

    private var newTerminalMenu: some View {
        Menu {
            ForEach(AgentKind.allCases) { kind in
                Button {
                    model.openTerminal(kind: kind, repositoryName: repositoryName)
                } label: {
                    Label(kind.displayName, systemImage: kind.systemImage)
                }
                .disabled(model.session(for: kind) != nil)
            }
        } label: {
            Label("New Terminal", systemImage: "plus")
        }
        .disabled(!canStartTerminal)
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
