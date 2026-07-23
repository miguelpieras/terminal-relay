import SwiftUI

private struct StopRequest: Identifiable {
    let kind: AgentKind
    let repositoryName: String
    let instanceToken: String

    var id: String { "\(kind.rawValue):\(repositoryName):\(instanceToken)" }
}

struct ProjectListView: View {
    @ObservedObject var model: WorkerSessionModel
    let onEditWorker: () -> Void
    @State private var stopRequest: StopRequest?

    var body: some View {
        List {
            if let profile = model.profile {
                Section("Worker") {
                    LabeledContent("SSH", value: "\(profile.username)@\(profile.host):\(profile.port)")
                }
            }

            Section("Projects") {
                if model.projects.isEmpty, !model.isLoading {
                    ContentUnavailableView(
                        "No projects found",
                        systemImage: "folder",
                        description: Text("Add a repository under /workspace on the worker, then refresh.")
                    )
                }

                ForEach(model.projects, id: \.self) { repositoryName in
                    ProjectRow(
                        repositoryName: repositoryName,
                        model: model,
                        onStop: { session in
                            stopRequest = StopRequest(
                                kind: session.kind,
                                repositoryName: repositoryName,
                                instanceToken: session.instanceToken
                            )
                        }
                    )
                }
            }
        }
        .navigationTitle(model.profile?.displayName ?? "Terminal Relay")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(action: onEditWorker) {
                    Label("Worker settings", systemImage: "gearshape")
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(model.isLoading)
            }
        }
        .task(id: model.profile?.id) {
            await model.refresh()
        }
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
}

private struct ProjectRow: View {
    let repositoryName: String
    @ObservedObject var model: WorkerSessionModel
    let onStop: (WorkerSessionSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(repositoryName, systemImage: "shippingbox")
                .font(.headline)

            ForEach(AgentKind.allCases) { kind in
                agentRow(kind)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func agentRow(_ kind: AgentKind) -> some View {
        let session = model.session(for: kind)
        let isHere = session?.repositoryName == repositoryName
        let isOccupiedElsewhere = session != nil && !isHere

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: kind.systemImage)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.displayName)
                        .font(.subheadline.weight(.semibold))
                    if isHere, let session {
                        Text("Running · \(session.attachedClientCount) attached")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if let session {
                        Text("Running in \(session.repositoryName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Not running")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(isHere ? "Attach" : "Start") {
                    model.openTerminal(kind: kind, repositoryName: repositoryName)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isOccupiedElsewhere)

                if isHere {
                    Button(role: .destructive) {
                        if let session {
                            onStop(session)
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Stop \(kind.displayName)")
                }
            }
        }
    }
}
