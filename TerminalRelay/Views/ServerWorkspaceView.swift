import SwiftUI

struct ServerWorkspaceView: View {
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

    let server: ServerProfile

    private var launchDefaults: AgentLaunchDefaults {
        AgentLaunchDefaults(
            codexModel: codexModel,
            codexReasoningEffort: codexReasoningEffort,
            claudeModel: claudeModel,
            claudeReasoningEffort: claudeReasoningEffort,
            fullAccessEnabled: fullAccessEnabled
        )
    }

    private var serverSessions: [TerminalSession] {
        sessionManager.sessions(for: server)
    }

    private var selectedSession: TerminalSession? {
        guard let selectedSessionID = sessionManager.selectedSessionID else { return nil }
        return serverSessions.first { $0.id == selectedSessionID }
    }

    private var sessionIDs: [UUID] {
        serverSessions.map(\.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            serverHeader

            Divider()

            if serverSessions.isEmpty {
                emptyWorkspace
            } else {
                SessionTabStrip(sessions: serverSessions)
                Divider()

                if let selectedSession {
                    TerminalPane(session: selectedSession)
                        .id(selectedSession.id)
                } else {
                    ContentUnavailableView(
                        "Choose a Terminal",
                        systemImage: "terminal",
                        description: Text("Select a running session above.")
                    )
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: selectFirstSessionIfNeeded)
        .onChange(of: server.id) { _, _ in selectFirstSessionIfNeeded() }
        .onChange(of: sessionIDs) { _, _ in selectFirstSessionIfNeeded() }
    }

    private var serverHeader: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.secondary)
                    Text(server.displayName)
                        .font(.title2.weight(.semibold))
                }

                Text(connectionSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 20)

            ForEach(AgentKind.allCases) { kind in
                AgentLaunchControl(
                    server: server,
                    kind: kind,
                    session: sessionManager.session(server: server, kind: kind),
                    launchDefaults: launchDefaults
                )
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Image(systemName: "terminal.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Start a remote terminal")
                    .font(.title2.weight(.semibold))
                Text("Both tools can run together. A second session of the same tool is blocked on this server.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }

            HStack(spacing: 14) {
                ForEach(AgentKind.allCases) { kind in
                    EmptyAgentCard(server: server, kind: kind, launchDefaults: launchDefaults)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var connectionSummary: String {
        var result = server.destination
        if server.port != 22 { result += ":\(server.port)" }
        if !server.workingDirectory.isEmpty { result += "  ·  \(server.workingDirectory)" }
        return result
    }

    private func selectFirstSessionIfNeeded() {
        if selectedSession == nil {
            sessionManager.selectedSessionID = serverSessions.first?.id
        }
    }
}

private struct AgentLaunchControl: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let server: ServerProfile
    let kind: AgentKind
    let session: TerminalSession?
    let launchDefaults: AgentLaunchDefaults

    var body: some View {
        if let session {
            ExistingAgentLaunchControl(
                server: server,
                kind: kind,
                session: session,
                launchDefaults: launchDefaults
            )
        } else {
            Button {
                sessionManager.open(server: server, kind: kind, launchDefaults: launchDefaults)
            } label: {
                Label("Start \(kind.displayName)", systemImage: kind.systemImage)
            }
            .buttonStyle(.borderedProminent)
            .tint(kind.tint)
        }
    }
}

private struct ExistingAgentLaunchControl: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let server: ServerProfile
    let kind: AgentKind
    @ObservedObject var session: TerminalSession
    let launchDefaults: AgentLaunchDefaults

    var body: some View {
        Button {
            sessionManager.open(server: server, kind: kind, launchDefaults: launchDefaults)
        } label: {
            Label(buttonLabel, systemImage: kind.systemImage)
        }
        .buttonStyle(.borderedProminent)
        .tint(kind.tint)
        .disabled(session.status == .stopping)
    }

    private var buttonLabel: String {
        switch session.status {
        case .connecting, .running: "Show \(kind.displayName)"
        case .stopping: "Stopping \(kind.displayName)"
        case .exited: "Restart \(kind.displayName)"
        }
    }
}

private struct EmptyAgentCard: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let server: ServerProfile
    let kind: AgentKind
    let launchDefaults: AgentLaunchDefaults

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: kind.systemImage)
                    .font(.title2)
                    .foregroundStyle(kind.tint)
                Text(kind.displayName)
                    .font(.headline)
            }

            Text(server.accountLabel(for: kind))
                .foregroundStyle(.secondary)
            Text(launchDefaults.summary(for: kind))
                .font(.caption.weight(.medium))
                .foregroundStyle(kind.tint)
                .lineLimit(1)
            if launchDefaults.fullAccessEnabled {
                Text("Full access · auto-approved")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Text(server.command(for: kind))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Button("Start \(kind.displayName)") {
                sessionManager.open(server: server, kind: kind, launchDefaults: launchDefaults)
            }
            .buttonStyle(.borderedProminent)
            .tint(kind.tint)
        }
        .frame(width: 210, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct SessionTabStrip: View {
    @EnvironmentObject private var sessionManager: SessionManager
    let sessions: [TerminalSession]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(sessions) { session in
                    SessionTab(
                        session: session,
                        isSelected: sessionManager.selectedSessionID == session.id
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(.bar)
    }
}

private struct SessionTab: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var session: TerminalSession
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                sessionManager.selectedSessionID = session.id
            } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Image(systemName: session.kind.systemImage)
                    Text(session.kind.displayName)
                    Text(session.accountLabel)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                sessionManager.close(sessionID: session.id)
            } label: {
                Image(systemName: session.status == .stopping ? "clock" : "xmark")
                    .font(.caption.weight(.semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.status == .stopping)
            .padding(.trailing, 7)
            .help(session.status.occupiesSlot ? "Stop and close terminal" : "Close terminal")
        }
        .background(
            isSelected ? Color.accentColor.opacity(0.16) : Color.clear,
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15))
        }
    }

    private var statusColor: Color {
        switch session.status {
        case .connecting: .yellow
        case .running: .green
        case .stopping: .orange
        case .exited: .red
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
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

private extension AgentKind {
    var tint: Color {
        switch self {
        case .codex: .blue
        case .claude: .orange
        }
    }
}
