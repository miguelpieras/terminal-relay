import SwiftUI

struct ProjectWorkspaceView: View {
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

    let project: ProjectProfile
    let worker: ServerProfile
    let onSelectProject: (UUID) -> Void

    @State private var conflictingSession: TerminalSession?

    private var launchDefaults: AgentLaunchDefaults {
        AgentLaunchDefaults(
            codexModel: codexModel,
            codexReasoningEffort: codexReasoningEffort,
            claudeModel: claudeModel,
            claudeReasoningEffort: claudeReasoningEffort,
            fullAccessEnabled: fullAccessEnabled
        )
    }

    private var projectSessions: [TerminalSession] {
        sessionManager.sessions(forProjectID: project.id)
    }

    private var selectedSession: TerminalSession? {
        guard let selectedSessionID = sessionManager.selectedSessionID else { return nil }
        return projectSessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            agentBar
            Divider()

            if let selectedSession {
                TerminalPane(session: selectedSession)
                    .id(selectedSession.id)
            } else {
                readyState
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(project.displayName)
        .alert(item: $conflictingSession) { occupant in
            Alert(
                title: Text("\(occupant.kind.displayName) is already open"),
                message: Text(
                    "\(worker.displayName)'s \(occupant.kind.displayName) slot is being used by \(occupant.projectName)."
                ),
                primaryButton: .default(Text("Show \(occupant.projectName)")) {
                    onSelectProject(occupant.projectID)
                    sessionManager.selectedSessionID = occupant.id
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var agentBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "server.rack")
                .foregroundStyle(.tertiary)

            Text(worker.displayName)
                .font(.caption.weight(.medium))
            Text("·")
                .foregroundStyle(.tertiary)
            Text(project.workingDirectory)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 16)

            ForEach(AgentKind.allCases) { kind in
                agentButton(for: kind)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private func agentButton(for kind: AgentKind) -> some View {
        let session = sessionManager.session(projectID: project.id, kind: kind)
        Button {
            open(kind)
        } label: {
            HStack(spacing: 7) {
                Circle()
                    .fill(session?.status.occupiesSlot == true ? kind.tint : Color.secondary.opacity(0.22))
                    .frame(width: 7, height: 7)
                Image(systemName: kind.systemImage)
                Text(kind.displayName)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(session?.status.occupiesSlot == true ? Color.primary : Color.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                sessionManager.selectedSessionID == session?.id
                    ? Color.primary.opacity(0.09)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session?.status == .stopping)
        .help(session?.status.occupiesSlot == true ? "Show \(kind.displayName) terminal" : "Start \(kind.displayName)")
    }

    private var readyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "terminal")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("Ready to work on \(project.displayName)")
                    .font(.title3.weight(.semibold))
                Text("Start a remote terminal on \(worker.displayName).")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                ForEach(AgentKind.allCases) { kind in
                    Button {
                        open(kind)
                    } label: {
                        Label("Start \(kind.displayName)", systemImage: kind.systemImage)
                    }
                    .buttonStyle(.bordered)
                    .tint(kind.tint)
                }
            }

            Text(project.workingDirectory)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func open(_ kind: AgentKind) {
        let result = sessionManager.open(
            project: project,
            on: worker,
            kind: kind,
            launchDefaults: launchDefaults
        )

        if case .occupied(let occupant) = result {
            conflictingSession = occupant
        }
    }

}

private struct TerminalPane: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Label(session.accountLabel, systemImage: "person.crop.circle")
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(session.status.label)
                    .foregroundStyle(.secondary)

                if let terminalTitle = session.terminalTitle, !terminalTitle.isEmpty {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(terminalTitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(session.status.occupiesSlot ? "Stop" : "Close") {
                    sessionManager.close(sessionID: session.id)
                }
                .buttonStyle(.borderless)
                .disabled(session.status == .stopping)
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))

            ZStack {
                TerminalHostView(session: session)

                if session.status == .stopping {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Stopping remote session…")
                            .font(.callout)
                    }
                    .padding(20)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }
}
