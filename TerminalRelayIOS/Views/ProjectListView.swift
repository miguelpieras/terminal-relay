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

    private var activeKinds: [AgentKind] {
        sessions
            .filter { $0.repositoryName == repositoryName }
            .map(\.kind)
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
                if activeKinds.isEmpty {
                    Text("No active sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(activeKinds.map(\.displayName).joined(separator: " · "))
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

    var body: some View {
        List {
            ForEach(AgentKind.allCases) { kind in
                agentSection(kind)
            }
        }
        .navigationTitle(repositoryName)
        .refreshable { await model.refresh() }
        .alert(item: $stopRequest) { request in
            Alert(
                title: Text("Stop \(request.kind.displayName)?"),
                message: Text("This ends the agent running in \(request.repositoryName) for every attached client. Disconnect if you only want to leave this device."),
                primaryButton: .destructive(Text("Stop Agent")) {
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
    private func agentSection(_ kind: AgentKind) -> some View {
        let session = model.session(for: kind)
        let isHere = session?.repositoryName == repositoryName
        let isOccupiedElsewhere = session != nil && !isHere

        Section {
            LabeledContent {
                if isHere, let session {
                    Text("\(session.attachedClientCount) attached")
                        .foregroundStyle(.green)
                } else if let session {
                    Text(session.repositoryName)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not running")
                        .foregroundStyle(.secondary)
                }
            } label: {
                Label("Status", systemImage: kind.systemImage)
            }

            Button {
                model.openTerminal(kind: kind, repositoryName: repositoryName)
            } label: {
                Label(
                    isHere ? "Attach to \(kind.displayName)" : "Start \(kind.displayName)",
                    systemImage: isHere ? "rectangle.connected.to.line.below" : "play.fill"
                )
            }
            .disabled(isOccupiedElsewhere)

            if isHere, let session {
                Button(role: .destructive) {
                    stopRequest = StopRequest(
                        kind: session.kind,
                        repositoryName: repositoryName,
                        instanceToken: session.instanceToken
                    )
                } label: {
                    Label("Stop \(kind.displayName)", systemImage: "stop.fill")
                }
            }
        } header: {
            Text(kind.displayName)
        } footer: {
            if isHere, let session {
                if session.attachedClientCount == 1 {
                    Text("This session has one attached client.")
                } else {
                    Text("This session has \(session.attachedClientCount) attached clients.")
                }
            } else if let session {
                Text("\(kind.displayName) is already running in \(session.repositoryName).")
            }
        }
    }
}
