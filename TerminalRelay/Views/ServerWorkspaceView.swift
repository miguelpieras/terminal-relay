import SwiftUI

struct ProjectWorkspaceView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountUsageService: AccountUsageService

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
        .task(id: usageTaskID) {
            guard selectedSession == nil else { return }
            await accountUsageService.refresh(worker: worker)
        }
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
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private var readyState: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 6) {
                    Text("Ready to work on \(project.displayName)")
                        .font(.title3.weight(.semibold))
                    Text("Choose the account with the most capacity on \(worker.displayName).")
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 14) {
                    ForEach(AgentKind.allCases) { kind in
                        AccountUsageCard(
                            kind: kind,
                            accountFallback: worker.accountLabel(for: kind),
                            snapshot: accountUsageService.snapshot(for: worker.id, kind: kind),
                            isLoading: accountUsageService.isLoading(workerID: worker.id, kind: kind),
                            errorMessage: accountUsageService.error(for: worker.id, kind: kind),
                            buttonTitle: launchTitle(for: kind),
                            isButtonDisabled: sessionManager.activeSession(for: worker, kind: kind)?.status == .stopping
                        ) {
                            open(kind)
                        }
                    }
                }
                .frame(maxWidth: 820)

                HStack(spacing: 8) {
                    Text(project.workingDirectory)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)

                    Button {
                        Task {
                            await accountUsageService.refresh(worker: worker, force: true)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(AgentKind.allCases.contains {
                        accountUsageService.isLoading(workerID: worker.id, kind: $0)
                    })
                    .help("Refresh account usage")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var usageTaskID: String {
        "\(worker.id.uuidString)-\(selectedSession?.id.uuidString ?? "overview")"
    }

    private func launchTitle(for kind: AgentKind) -> String {
        let productName = kind == .claude ? "Claude Code" : kind.displayName
        guard let occupant = sessionManager.activeSession(for: worker, kind: kind) else {
            return "Start \(productName)"
        }
        return occupant.projectID == project.id
            ? "Show \(productName)"
            : "\(productName) in use"
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

private struct AccountUsageCard: View {
    let kind: AgentKind
    let accountFallback: String
    let snapshot: AccountUsageSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    let buttonTitle: String
    let isButtonDisabled: Bool
    let action: () -> Void

    private var productName: String {
        kind == .claude ? "Claude Code" : kind.displayName
    }

    private var accountDetail: String {
        let account = snapshot?.account ?? accountFallback
        guard let plan = snapshot?.plan, !plan.isEmpty else { return account }
        return "\(account) · \(plan.capitalized)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 12) {
                AgentBrandIcon(kind: kind, size: 42)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(productName)
                            .font(.headline)
                        Circle()
                            .fill(snapshot == nil ? Color.secondary.opacity(0.35) : Color.green)
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(snapshot == nil ? "Usage unavailable" : "Account connected")
                    }
                    Text(accountDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Divider()

            if let snapshot {
                VStack(spacing: 14) {
                    ForEach(snapshot.limits) { limit in
                        usageLimit(limit)
                    }
                }
            } else if isLoading {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Reading account limits…")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            } else {
                Text(errorMessage ?? "Usage limits are unavailable.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if snapshot != nil, isLoading {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Refreshing…")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            } else if snapshot != nil, errorMessage != nil {
                Label("Could not refresh", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: action) {
                HStack(spacing: 8) {
                    AgentBrandIcon(kind: kind, size: 20)
                    Text(buttonTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isButtonDisabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }

    private func usageLimit(_ limit: AccountUsageLimit) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.name)
                    .font(.callout.weight(.medium))
                Spacer(minLength: 8)
                Text("\(limit.remainingPercentText)% left")
                    .font(.callout.weight(.semibold))
            }

            ProgressView(value: limit.usedPercent, total: 100)
                .tint(kind.tint)

            HStack {
                Text("\(limit.usedPercentText)% used")
                Spacer(minLength: 8)
                if let resetsAt = limit.resetsAt {
                    Text("Resets \(resetsAt, style: .relative)")
                } else if let resetText = limit.resetText {
                    Text("Resets \(resetText)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
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
