import SwiftUI

private struct IPadSidebarProject: Identifiable {
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
                        },
                    threads: model.threads(
                        workerID: profile.id,
                        repositoryName: repositoryName,
                        archived: false
                    ).filter { $0.activityState != .relayActive }
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
                || project.threads.contains {
                    ($0.title ?? "").localizedCaseInsensitiveContains(query)
                }
                || model.threads(
                    workerID: project.workerID,
                    repositoryName: project.repositoryName,
                    archived: true
                ).contains {
                    ($0.title ?? "").localizedCaseInsensitiveContains(query)
                }
        }
    }

    private var refreshTaskID: String {
        model.profiles
            .map { "\($0.id.uuidString):\($0.host):\($0.port)" }
            .joined(separator: "|")
    }

    private var catalogError: String? {
        model.profiles.compactMap {
            model.workerOverviews[$0.id]?.connectionError
        }
        .first
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
            } else if projects.isEmpty {
                if !model.projectLoadingIDs.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading projects…")
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                } else if let catalogError {
                    ContentUnavailableView(
                        "Couldn’t Load Projects",
                        systemImage: "exclamationmark.triangle",
                        description: Text(catalogError)
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ContentUnavailableView(
                        "No Projects",
                        systemImage: "folder",
                        description: Text(
                            "Add a repository under /workspace on a worker, then pull to refresh."
                        )
                    )
                    .listRowBackground(Color.clear)
                }
            } else if filteredProjects.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .listRowBackground(Color.clear)
            } else {
                Section("Projects & Conversations") {
                    ForEach(filteredProjects) { project in
                        projectRow(project)

                        ForEach(project.sessions) { session in
                            conversationRow(session, project: project)
                        }

                        ForEach(project.threads) { thread in
                            dormantThreadRow(thread, project: project)
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
        .searchable(text: $searchText, prompt: "Projects or conversations")
        .refreshable {
            await model.refreshProjectCatalogs()
            await model.refreshAllThreads()
        }
        .task(id: refreshTaskID) {
            await model.refreshProjectCatalogs()
            await model.refreshAllThreads()
            reconcileSelection()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    return
                }
                await model.refreshProjectActivity()
            }
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

    private func conversationRow(
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
                    Text(session.title ?? "\(session.kind.displayName) conversation")
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
                } else if model.isUnread(session, profileID: project.workerID) {
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

    private func dormantThreadRow(
        _ thread: WorkerThreadSnapshot,
        project: IPadSidebarProject
    ) -> some View {
        Button {
            selectedProject = project.selection
            Task {
                await model.resumeThread(workerID: project.workerID, thread: thread)
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: thread.kind.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue.opacity(0.65))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(thread.title ?? "Untitled thread")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(activityLabel(for: thread))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Image(systemName: "play.circle")
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!thread.capabilities.resume)
        .contextMenu {
            Button("Archive Thread", role: .destructive) {
                Task {
                    await model.setThreadArchived(
                        workerID: project.workerID,
                        thread: thread,
                        archived: true
                    )
                }
            }
            .disabled(!thread.capabilities.archive)
        }
    }

    private func activityLabel(for thread: WorkerThreadSnapshot) -> String {
        switch thread.activityState {
        case .inactive: "Paused"
        case .relayActive: "Active in Terminal Relay"
        case .externalActive: "Active elsewhere"
        case .unknown: "Activity unavailable"
        }
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
