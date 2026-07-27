import SwiftUI

private struct IPadSidebarProject: Identifiable {
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

struct IPadWorkspaceSidebar: View {
    @ObservedObject var model: WorkerSessionModel
    @Binding var selectedProject: ProjectSelection?
    let onAddWorker: () -> Void
    let onExploreDemo: () -> Void
    let onShowWorkers: () -> Void

    @State private var searchText = ""

    private var projects: [IPadSidebarProject] {
        model.profiles.flatMap { profile -> [IPadSidebarProject] in
            guard let overview = model.workerOverviews[profile.id] else { return [] }
            return overview.projects.map { repositoryName in
                IPadSidebarProject(
                    workerID: profile.id,
                    workerName: profile.displayName,
                    repositoryName: repositoryName,
                    sessions: overview.sessions
                        .filter { $0.repositoryName == repositoryName }
                        .sorted {
                            ($0.title ?? "").localizedStandardCompare($1.title ?? "")
                                == .orderedAscending
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

    private var filteredProjects: [IPadSidebarProject] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return projects }
        return projects.filter { project in
            project.repositoryName.localizedCaseInsensitiveContains(query)
                || project.workerName.localizedCaseInsensitiveContains(query)
                || project.sessions.contains {
                    ($0.title ?? "").localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var refreshTaskID: String {
        model.profiles
            .map { "\($0.id.uuidString):\($0.host):\($0.port)" }
            .joined(separator: "|")
    }

    var body: some View {
        List {
            if model.profiles.isEmpty {
                Section {
                    Button(action: onAddWorker) {
                        Label("Scan Mac Pairing Code", systemImage: "qrcode.viewfinder")
                    }

                    Button(action: onExploreDemo) {
                        Label("Explore Demo", systemImage: "play.circle")
                    }
                } footer: {
                    Text("The demo is local, uses example data, and never contacts a worker.")
                }
            } else if filteredProjects.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                Section("Projects & Terminals") {
                    ForEach(filteredProjects) { project in
                        projectRow(project)

                        ForEach(project.sessions) { session in
                            terminalRow(session, project: project)
                        }
                    }
                }
            }

            Section {
                Button(action: onShowWorkers) {
                    Label("Workers", systemImage: "server.rack")
                }

                Button(action: onAddWorker) {
                    Label("Pair Another Worker", systemImage: "plus")
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Terminal Relay")
        .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 280)
        .searchable(text: $searchText, prompt: "Projects or terminals")
        .refreshable {
            await model.refreshProjectCatalogs()
        }
        .task(id: refreshTaskID) {
            await model.refreshProjectCatalogs()
            reconcileSelection()
        }
        .onChange(of: projects.map(\.selection)) { _, _ in
            reconcileSelection()
        }
    }

    private func projectRow(_ project: IPadSidebarProject) -> some View {
        Button {
            if model.profile?.id != project.workerID {
                model.selectProfile(id: project.workerID)
            }
            selectedProject = project.selection
            model.terminalRoute = nil
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.repositoryName)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    if model.profiles.count > 1 {
                        Text(project.workerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if project.sessions.contains(where: { $0.isWorking() }) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Working")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            selectedProject == project.selection && model.terminalRoute == nil
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
    }

    private func terminalRow(
        _ session: WorkerSessionSnapshot,
        project: IPadSidebarProject
    ) -> some View {
        Button {
            if model.profile?.id != project.workerID {
                model.selectProfile(id: project.workerID)
            }
            selectedProject = project.selection
            model.openTerminal(session)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: session.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.kind == .codex ? .blue : .orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title ?? "\(session.kind.displayName) terminal")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(session.kind.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if session.isWorking() {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel("Working")
                } else if model.isUnread(session) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 7, height: 7)
                        .accessibilityLabel("New activity")
                }
            }
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected(session)
                ? Color.accentColor.opacity(0.14)
                : Color.clear
        )
    }

    private func isSelected(_ session: WorkerSessionSnapshot) -> Bool {
        guard let route = model.terminalRoute else { return false }
        return route.kind == session.kind
            && route.repositoryName == session.repositoryName
            && route.instanceToken == session.instanceToken
    }

    private func reconcileSelection() {
        selectedProject = AdaptiveSelectionPolicy.project(
            current: selectedProject,
            available: projects.map(\.selection)
        )
    }
}

struct DemoModeBanner: View {
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("Demo workspace · Local example data", systemImage: "play.circle.fill")
                .font(.subheadline.weight(.medium))

            Spacer()

            Button("Exit Demo", action: onExit)
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .foregroundStyle(.white)
        .background(Color.indigo)
    }
}
