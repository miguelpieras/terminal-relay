import SwiftUI

struct ProjectWorkspaceView: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var workerSessionService: WorkerSessionService
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @EnvironmentObject private var projectGitService: ProjectGitService

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
    let onShowWorkers: () -> Void

    @State private var conflictingOccupant: SessionOccupant?
    @State private var isShowingCodexResets = false
    @State private var isWritingCommitMessage = false
    @State private var commitMessage = ""
    @State private var isShowingEnvironmentSidebar = !ScreenshotDemoMode.isEnabled

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

    private var gitSnapshot: ProjectGitSnapshot? {
        projectGitService.snapshot(for: project.id)
    }

    private var gitOperation: ProjectGitOperation? {
        projectGitService.currentOperations[project.id]
    }

    private var hasOpenProjectTerminal: Bool {
        projectSessions.contains { $0.status.occupiesSlot }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                if let warning = workerSessionService.updateWarning(for: worker.id) {
                    workerUpdateWarningBanner(warning)
                    Divider()
                }

                if let error = workerSessionService.error(for: worker.id) {
                    workerSessionErrorBanner(error)
                    Divider()
                }

                if let conflictingOccupant {
                    conflictBanner(conflictingOccupant)
                    Divider()
                }

                if let selectedSession {
                    TerminalPane(
                        session: selectedSession,
                        project: project,
                        worker: worker,
                        launchDefaults: launchDefaults
                    )
                    .id(selectedSession.terminalViewIdentity)
                } else {
                    readyState
                }
            }

            if isShowingEnvironmentSidebar {
                Divider()
                environmentSidebar
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(project.displayName)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    isShowingEnvironmentSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help(isShowingEnvironmentSidebar ? "Hide details sidebar" : "Show details sidebar")
            }
        }
        .task(id: usageTaskID) {
            guard !ScreenshotDemoMode.isEnabled else { return }
            guard selectedSession == nil else { return }
            await accountUsageService.refresh(worker: worker)
        }
        .task(id: project.id) {
            guard !ScreenshotDemoMode.isEnabled else { return }
            repeat {
                _ = await projectGitService.refresh(
                    project: project,
                    worker: worker,
                    fetchRemote: true
                )
                do {
                    try await Task.sleep(for: .seconds(12))
                } catch {
                    return
                }
            } while !Task.isCancelled
        }
    }

    private var environmentSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Details")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        _ = await projectGitService.refresh(
                            project: project,
                            worker: worker,
                            fetchRemote: true
                        )
                        projectGitService.refreshDeployment(project: project)
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(projectGitService.isBusy(projectID: project.id))
                .help("Refresh origin and deployment status")
            }
            .padding(.horizontal, 18)
            .frame(height: 50)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Button(action: onShowWorkers) {
                            HStack(spacing: 8) {
                                Image(systemName: "server.rack")
                                    .foregroundStyle(.secondary)
                                Text(worker.displayName)
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Manage workers")

                        Text(project.workingDirectory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Git")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        gitChangeSummary
                        branchStatus

                        if isWritingCommitMessage {
                            sidebarCommitComposer
                        } else {
                            Button(action: commitButtonAction) {
                                Text(commitButtonTitle)
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                            .frame(minHeight: 34)
                            .disabled(commitButtonDisabled)
                            .help(commitButtonHelp)
                        }

                        if gitNoticeText != nil {
                            sidebarGitNotice
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Deployment")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        deploymentRow
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 286)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    @ViewBuilder
    private var deploymentRow: some View {
        switch projectGitService.deploymentState(for: project.id) {
        case .some(.checking(let commitOID)):
            deploymentStatusRow(
                title: "Waiting for workflow",
                detail: "Commit \(shortOID(commitOID))",
                color: .secondary,
                isProgress: true
            )
        case .some(.run(let run)):
            if let url = URL(string: run.url) {
                Link(destination: url) {
                    deploymentStatusRow(
                        title: run.workflowName,
                        detail: workflowStatusText(run),
                        color: workflowStatusColor(run),
                        isProgress: !run.isCompleted,
                        showsLink: true
                    )
                }
                .buttonStyle(.plain)
            } else {
                deploymentStatusRow(
                    title: run.workflowName,
                    detail: workflowStatusText(run),
                    color: workflowStatusColor(run),
                    isProgress: !run.isCompleted
                )
            }
        case .some(.noWorkflow(let commitOID)):
            deploymentStatusRow(
                title: "No workflow run",
                detail: "Commit \(shortOID(commitOID))",
                color: .secondary
            )
        case .some(.unavailable(let message)):
            deploymentStatusRow(
                title: "Status unavailable",
                detail: message,
                color: .orange
            )
        case nil:
            deploymentStatusRow(
                title: "Reading deployment",
                detail: "Waiting for Git status",
                color: .secondary,
                isProgress: true
            )
        }
    }

    private func deploymentStatusRow(
        title: String,
        detail: String,
        color: Color,
        isProgress: Bool = false,
        showsLink: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            Group {
                if isProgress {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Circle()
                        .fill(color)
                        .frame(width: 7, height: 7)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            if showsLink {
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 48)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var gitChangeSummary: some View {
        if let gitSnapshot {
            HStack(spacing: 5) {
                Circle()
                    .fill(
                        gitSnapshot.hasChanges || gitSnapshot.behindCount > 0
                            ? Color.orange
                            : Color.green
                    )
                    .frame(width: 6, height: 6)
                Text(gitSnapshot.hasChanges
                    ? "\(gitSnapshot.changedFileCount) \(gitSnapshot.changedFileCount == 1 ? "change" : "changes")"
                    : "Clean")
                if gitSnapshot.aheadCount > 0 {
                    Text("· \(gitSnapshot.aheadCount) ahead")
                        .foregroundStyle(.orange)
                } else if gitSnapshot.hasPendingPush {
                    Text("· unpublished")
                        .foregroundStyle(.orange)
                }
                if gitSnapshot.behindCount > 0 {
                    Text(gitSnapshot.hasChanges
                        ? "· update waiting for clean tree"
                        : gitSnapshot.aheadCount > 0
                            ? "· local and remote history differ"
                            : "· syncing \(gitSnapshot.behindCount) remote \(gitSnapshot.behindCount == 1 ? "commit" : "commits")")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else if gitOperation == .refreshing {
            Text("Reading Git…")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        } else {
            Text("Git unavailable")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    private var branchStatus: some View {
        VStack(spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                Text(gitSnapshot?.currentBranch ?? "Reading branch…")
                    .lineLimit(1)
                    .foregroundStyle(
                        gitSnapshot?.currentBranch == "main"
                            ? Color.primary
                            : Color.orange
                    )
                Spacer(minLength: 4)
                Text(gitSnapshot?.currentBranch == "main" ? "local" : "expected main")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 7) {
                Image(systemName: "cloud")
                    .foregroundStyle(.secondary)
                Text("origin/main")
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("remote")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
    }

    private var sidebarCommitComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Commit message", text: $commitMessage)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commitAndPush)

            HStack {
                Button("Cancel") {
                    isWritingCommitMessage = false
                    commitMessage = ""
                }
                .buttonStyle(.borderless)
                .disabled(projectGitService.isBusy(projectID: project.id))

                Spacer()

                Button("Commit & push", action: commitAndPush)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(
                        commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || gitSnapshot?.currentBranch != "main"
                            || hasOpenProjectTerminal
                            || projectGitService.isBusy(projectID: project.id)
                    )
                    .help(commitButtonHelp)
            }
        }
        .padding(9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private var sidebarGitNotice: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(gitNoticeIsError ? Color.orange : Color.green)
                .frame(width: 6, height: 6)
                .padding(.top, 4)
            Text(gitNoticeText ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if projectGitService.operationResult(for: project.id) != nil, !needsPushRetry {
                Button {
                    projectGitService.clearOperationResult(for: project.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
            }
        }
    }

    private var readyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(AgentKind.allCases) { kind in
                        let hasActiveAgent = sessionManager.occupant(
                            for: worker,
                            kind: kind
                        ) != nil
                        let requiresNewSessionSignIn = accountUsageService
                            .requiresNewSessionSignIn(
                                workerID: worker.id,
                                kind: kind
                            )
                        AccountUsageCard(
                            worker: worker,
                            kind: kind,
                            accountFallback: worker.accountLabel(for: kind),
                            snapshot: accountUsageService.snapshot(for: worker.id, kind: kind),
                            isLoading: accountUsageService.isLoading(workerID: worker.id, kind: kind),
                            errorMessage: accountUsageService.error(for: worker.id, kind: kind),
                            hasActiveAgent: hasActiveAgent,
                            requiresNewSessionSignIn: requiresNewSessionSignIn,
                            buttonTitle: launchTitle(for: kind),
                            isButtonDisabled: isGitMutationInProgress
                                || workerSessionService.isStarting(worker: worker, kind: kind)
                                || workerSessionService.isStopping(worker: worker, kind: kind)
                                || (requiresNewSessionSignIn && !hasActiveAgent),
                            isAccountActionDisabled:
                                workerSessionService.isStarting(worker: worker, kind: kind)
                                || workerSessionService.isStopping(worker: worker, kind: kind),
                            onViewResets: kind == .codex ? { isShowingCodexResets = true } : nil,
                            action: { open(kind) }
                        )
                    }
                }
                .frame(maxWidth: 820)

                if isShowingCodexResets {
                    CodexResetCreditsView(worker: worker) {
                        isShowingCodexResets = false
                    }
                    .frame(maxWidth: 820)
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

    private var isGitMutationInProgress: Bool {
        switch gitOperation {
        case .switchingBranch, .committingAndPushing, .pushing:
            return true
        case .refreshing, nil:
            return false
        }
    }

    private var commitButtonTitle: String {
        guard let gitSnapshot else { return "Commit & push" }
        return !gitSnapshot.hasChanges && needsPushRetry ? "Push" : "Commit & push"
    }

    private var commitButtonDisabled: Bool {
        guard let gitSnapshot else { return true }
        return (!gitSnapshot.hasChanges && !needsPushRetry)
            || gitSnapshot.currentBranch != "main"
            || hasOpenProjectTerminal
            || projectGitService.isBusy(projectID: project.id)
    }

    private var commitButtonHelp: String {
        if let gitSnapshot, gitSnapshot.currentBranch != "main" {
            return "Terminal Relay commits and pushes only main; the worker is currently on \(gitSnapshot.currentBranch)"
        }
        if hasOpenProjectTerminal { return "Stop this project's terminals before changing its Git state" }
        if projectGitService.isBusy(projectID: project.id) { return "A Git operation is in progress" }
        return needsPushRetry ? "Push main" : "Commit all changes and push main"
    }

    private var needsPushRetry: Bool {
        if gitSnapshot?.hasPendingPush == true { return true }
        switch projectGitService.operationResult(for: project.id) {
        case .some(.committedLocally(pushError: _)), .some(.pushFailed(_)):
            return true
        default:
            return false
        }
    }

    private var gitNoticeIsError: Bool {
        if projectGitService.error(for: project.id) != nil { return true }
        switch projectGitService.operationResult(for: project.id) {
        case .some(.committedLocally(pushError: _)), .some(.pushFailed(_)):
            return true
        default:
            return false
        }
    }

    private var gitNoticeText: String? {
        projectGitService.error(for: project.id)
            ?? projectGitService.operationResult(for: project.id)?.message
    }

    private func commitButtonAction() {
        guard let gitSnapshot else { return }
        if !gitSnapshot.hasChanges, needsPushRetry {
            Task {
                _ = await projectGitService.push(project: project, worker: worker)
            }
        } else {
            isWritingCommitMessage.toggle()
        }
    }

    private func commitAndPush() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !hasOpenProjectTerminal else { return }

        Task {
            let succeeded = await projectGitService.commitAndPush(
                message: message,
                project: project,
                worker: worker
            )
            let committedLocally: Bool
            if case .some(.committedLocally(pushError: _)) = projectGitService.operationResult(for: project.id) {
                committedLocally = true
            } else {
                committedLocally = false
            }
            if succeeded || committedLocally {
                commitMessage = ""
                isWritingCommitMessage = false
            }
        }
    }

    private func workflowStatusText(_ run: GitHubWorkflowRun) -> String {
        if !run.isCompleted {
            return run.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
        return run.conclusion.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func workflowStatusColor(_ run: GitHubWorkflowRun) -> Color {
        guard run.isCompleted else { return .secondary }
        return run.succeeded ? .green : .red
    }

    private func shortOID(_ oid: String) -> String {
        String(oid.prefix(7))
    }

    private func launchTitle(for kind: AgentKind) -> String {
        let productName = kind == .claude ? "Claude Code" : kind.displayName
        if workerSessionService.isStarting(worker: worker, kind: kind) {
            return "Starting \(productName)"
        }
        return "Start \(productName)"
    }

    private func open(_ kind: AgentKind) {
        guard !isGitMutationInProgress else { return }

        Task {
            guard let result = await sessionManager.openAfterRefresh(
                project: project,
                on: worker,
                kind: kind,
                projects: projectStore.projects,
                launchDefaults: launchDefaults,
                using: workerSessionService
            ) else { return }
            handleOpenResult(result)
        }
    }

    private func handleOpenResult(_ result: SessionOpenResult) {
        if case .occupied(let occupant) = result {
            conflictingOccupant = occupant
        } else {
            conflictingOccupant = nil
        }
    }

    private func conflictBanner(_ occupant: SessionOccupant) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            Text("\(occupant.kind.displayName) is already running on \(occupant.repositoryName).")
                .font(.callout)

            Spacer(minLength: 12)

            if let projectID = occupant.projectID, let session = occupant.localSession {
                Button("Show \(occupant.repositoryName)") {
                    onSelectProject(projectID)
                    sessionManager.selectSession(session.id)
                    conflictingOccupant = nil
                }
                .buttonStyle(.borderless)
            }

            Button("Dismiss") {
                conflictingOccupant = nil
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 38)
        .background(Color.orange.opacity(0.08))
    }

    private func workerSessionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 12)
            Button {
                workerSessionService.dismissError(for: worker.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(Color.orange.opacity(0.08))
    }

    private func workerUpdateWarningBanner(_ message: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .lineLimit(2)
            Spacer(minLength: 12)
            Button {
                workerSessionService.dismissUpdateWarning(for: worker.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .background(Color.orange.opacity(0.08))
    }

}

private struct AccountUsageCard: View {
    let worker: ServerProfile
    let kind: AgentKind
    let accountFallback: String
    let snapshot: AccountUsageSnapshot?
    let isLoading: Bool
    let errorMessage: String?
    let hasActiveAgent: Bool
    let requiresNewSessionSignIn: Bool
    let buttonTitle: String
    let isButtonDisabled: Bool
    let isAccountActionDisabled: Bool
    let onViewResets: (() -> Void)?
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
                            .fill(
                                snapshot == nil
                                    ? (hasActiveAgent ? Color.orange : Color.secondary.opacity(0.35))
                                    : Color.green
                            )
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(accountStateLabel)
                    }
                    Text(accountDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                AccountChangeButton(
                    worker: worker,
                    kind: kind,
                    currentAccount: snapshot?.account,
                    hasActiveAgent: hasActiveAgent,
                    requiresNewSessionSignIn: requiresNewSessionSignIn,
                    isSessionOperationInProgress: isAccountActionDisabled,
                    controlSize: .small,
                    showsIcon: true
                )
            }

            Divider()

            if let snapshot {
                if snapshot.limits.isEmpty {
                    Text("Usage limits are temporarily unavailable.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 14) {
                        ForEach(snapshot.limits) { limit in
                            usageLimit(limit)
                        }
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
                Text(accountUnavailableMessage)
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

            if kind == .codex {
                Divider()

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Rate-limit resets")
                            .font(.callout.weight(.medium))
                        Text(resetAvailabilityText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if let onViewResets {
                        Button("View resets", action: onViewResets)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(snapshot?.codexResetCredits == nil || isLoading)
                    }
                }
            }

            Spacer(minLength: 0)

            Button(action: action) {
                Text(buttonTitle)
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

            ProgressView(value: limit.remainingPercent, total: 100)
                .tint(usageTint(for: limit.remainingPercent))

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

    private func usageTint(for remainingPercent: Double) -> Color {
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 25 { return .orange }
        return .accentColor
    }

    private var resetAvailabilityText: String {
        guard let count = snapshot?.codexResetCredits?.availableCount else {
            return "Unavailable"
        }
        return count == 1 ? "1 available" : "\(count) available"
    }

    private var accountStateLabel: String {
        if snapshot != nil { return "Account connected" }
        if requiresNewSessionSignIn { return "Sign in required" }
        return "Usage unavailable"
    }

    private var accountUnavailableMessage: String {
        if requiresNewSessionSignIn, hasActiveAgent {
            return "Sign in once, then restart this terminal to use the worker's shared \(productName) account."
        }
        return errorMessage ?? "Usage limits are unavailable."
    }
}

private struct CodexResetCreditsView: View {
    @EnvironmentObject private var accountUsageService: AccountUsageService

    let worker: ServerProfile
    let onClose: () -> Void

    @State private var selectedReset: ResetSelection?
    @State private var isRedeeming = false
    @State private var notice: ResetNotice?

    private var snapshot: AccountUsageSnapshot? {
        accountUsageService.snapshot(for: worker.id, kind: .codex)
    }

    private var summary: CodexRateLimitResetCredits? {
        snapshot?.codexResetCredits
    }

    private var listedCredits: [CodexRateLimitResetCredit] {
        summary?.credits ?? []
    }

    private var availableListedCreditCount: Int {
        listedCredits.lazy.filter(\.isAvailable).count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AgentBrandIcon(kind: .codex, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex rate-limit resets")
                        .font(.headline)
                    Text(snapshot?.account ?? worker.accountLabel(for: .codex))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let summary {
                    Text(summary.availableCount == 1 ? "1 available" : "\(summary.availableCount) available")
                        .font(.callout.weight(.semibold))
                }

                Button("Close", action: onClose)
                    .buttonStyle(.borderless)
                    .disabled(isRedeeming)
            }
            .padding(16)

            Divider()

            if let notice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(notice.title)
                            .font(.callout.weight(.semibold))
                        Text(notice.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Dismiss") { self.notice = nil }
                        .buttonStyle(.borderless)
                }
                .padding(12)
                .background(Color.blue.opacity(0.07))

                Divider()
            }

            if let selectedReset {
                HStack(spacing: 12) {
                    Text("Redeem \(selectedReset.name)? This cannot be undone.")
                        .font(.callout)
                    Spacer(minLength: 8)
                    Button("Cancel") { self.selectedReset = nil }
                        .disabled(isRedeeming)
                    Button("Redeem", role: .destructive) {
                        redeem(selectedReset)
                    }
                    .disabled(isRedeeming)
                }
                .padding(12)
                .background(Color.orange.opacity(0.07))

                Divider()
            }

            Group {
                if let summary {
                    resetContent(summary)
                } else if accountUsageService.isLoading(workerID: worker.id, kind: .codex) {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Reading earned resets…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Resets unavailable",
                        systemImage: "arrow.counterclockwise",
                        description: Text("Codex did not return earned reset information for this account.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                if isRedeeming {
                    ProgressView()
                        .controlSize(.small)
                    Text("Redeeming and refreshing limits…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(minHeight: isRedeeming ? 42 : 0)
        }
        .frame(minHeight: 300)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func resetContent(_ summary: CodexRateLimitResetCredits) -> some View {
        if summary.availableCount == 0 {
            ContentUnavailableView(
                "No resets available",
                systemImage: "checkmark.circle",
                description: Text("This Codex account has no earned rate-limit resets right now.")
            )
        } else if listedCredits.isEmpty {
            VStack(spacing: 14) {
                Text("\(summary.availableCount) earned \(summary.availableCount == 1 ? "reset is" : "resets are") available.")
                    .font(.title3.weight(.semibold))
                Text("Codex returned the count without individual reset details.")
                    .foregroundStyle(.secondary)
                Button("Redeem next reset") {
                    confirm(creditID: nil, name: "one earned reset")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isRedeeming)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(listedCredits) { credit in
                        resetRow(credit)
                    }

                    if summary.availableCount > availableListedCreditCount {
                        VStack(spacing: 8) {
                            Text("Showing \(availableListedCreditCount) of \(summary.availableCount) available resets")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Redeem next reset") {
                                confirm(creditID: nil, name: "the next earned reset")
                            }
                            .buttonStyle(.bordered)
                            .disabled(isRedeeming)
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(16)
            }
        }
    }

    private func resetRow(_ credit: CodexRateLimitResetCredit) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(creditTitle(credit))
                    .font(.callout.weight(.semibold))

                if let description = nonempty(credit.description) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text("Earned \(credit.grantedAt, style: .relative)")
                    if let expiresAt = credit.expiresAt {
                        Text("Expires \(expiresAt, style: .relative)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            if credit.isAvailable {
                Button("Redeem") {
                    confirm(creditID: credit.id, name: creditTitle(credit))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRedeeming)
            } else {
                Text(credit.status.capitalized)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private func confirm(creditID: String?, name: String) {
        selectedReset = ResetSelection(creditID: creditID, name: name)
    }

    private func redeem(_ selection: ResetSelection) {
        isRedeeming = true
        Task {
            do {
                let result = try await accountUsageService.redeemCodexReset(
                    worker: worker,
                    creditID: selection.creditID
                )
                notice = ResetNotice(result: result)
            } catch {
                notice = ResetNotice(
                    title: "Reset not redeemed",
                    message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
            selectedReset = nil
            isRedeeming = false
        }
    }

    private func creditTitle(_ credit: CodexRateLimitResetCredit) -> String {
        nonempty(credit.title) ?? "Rate-limit reset"
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct ResetSelection: Identifiable {
    let id = UUID()
    let creditID: String?
    let name: String
}

private struct ResetNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    init(result: CodexResetRedemptionResult) {
        guard result.limitsRefreshed else {
            switch result.outcome {
            case .reset, .alreadyRedeemed:
                self.init(
                    title: "Reset redeemed",
                    message: "The redemption completed, but current limits could not be refreshed. Refresh usage before redeeming another reset."
                )
            case .nothingToReset:
                self.init(
                    title: "Nothing to reset",
                    message: "There was no eligible rate-limit window, and current Codex limits could not be refreshed."
                )
            case .noCredit:
                self.init(
                    title: "No reset available",
                    message: "No earned reset was available, and current Codex limits could not be refreshed."
                )
            }
            return
        }

        switch result.outcome {
        case .reset:
            self.init(
                title: "Reset redeemed",
                message: "The earned reset was consumed and the Codex limits were refreshed."
            )
        case .alreadyRedeemed:
            self.init(
                title: "Reset already redeemed",
                message: "This redemption had already completed. The Codex limits were refreshed."
            )
        case .nothingToReset:
            self.init(
                title: "Nothing to reset",
                message: "There is no eligible Codex rate-limit window to reset right now."
            )
        case .noCredit:
            self.init(
                title: "No reset available",
                message: "This Codex account has no earned reset credit available."
            )
        }
    }
}

private struct TerminalPane: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var workerSessionService: WorkerSessionService
    @ObservedObject var session: TerminalSession

    let project: ProjectProfile
    let worker: ServerProfile
    let launchDefaults: AgentLaunchDefaults

    @State private var isConfirmingStop = false

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

                if let clientCount = session.remoteAttachedClientCount {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text("\(clientCount) \(clientCount == 1 ? "client" : "clients")")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if session.status.isLocallyAttached {
                    Button("Disconnect") {
                        sessionManager.disconnect(sessionID: session.id)
                    }
                    .buttonStyle(.borderless)
                } else if session.status.canReconnect {
                    Button("Reconnect") {
                        reconnect()
                    }
                    .buttonStyle(.borderless)
                } else if !session.status.occupiesSlot {
                    Button("Close") {
                        sessionManager.close(sessionID: session.id)
                    }
                    .buttonStyle(.borderless)
                }

                if session.status.occupiesSlot {
                    Button("Stop Agent…", role: .destructive) {
                        isConfirmingStop = true
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .disabled(session.status == .stopping)
                }
            }
            .font(.caption)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Color(nsColor: .controlBackgroundColor))

            ZStack {
                if session.status.canReconnect {
                    if case .disconnected = session.status {
                        ContentUnavailableView {
                            Label("Connection interrupted", systemImage: "network.slash")
                        } description: {
                            Text("The remote agent state is unknown. Reconnect will verify it on \(worker.displayName).")
                        } actions: {
                            Button("Reconnect", action: reconnect)
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView {
                            Label("Agent running remotely", systemImage: "network")
                        } description: {
                            Text("This terminal is disconnected. The agent is still running on \(worker.displayName).")
                        } actions: {
                            Button("Reconnect", action: reconnect)
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    TerminalHostView(session: session)
                }

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

            AgentComposerView(
                session: session,
                worker: worker
            )
        }
        .alert("Stop \(session.kind.displayName) agent?", isPresented: $isConfirmingStop) {
            Button("Cancel", role: .cancel) {}
            Button("Stop Agent", role: .destructive) {
                Task {
                    _ = await sessionManager.stopAgentAfterRefresh(
                        sessionID: session.id,
                        on: worker,
                        projects: projectStore.projects,
                        launchDefaults: launchDefaults,
                        using: workerSessionService
                    )
                }
            }
        } message: {
            Text("This ends the persistent remote agent for \(project.displayName). Disconnect instead if you want it to keep running.")
        }
    }

    private func reconnect() {
        Task {
            _ = await sessionManager.reconnectAfterRefresh(
                sessionID: session.id,
                project: project,
                on: worker,
                projects: projectStore.projects,
                launchDefaults: launchDefaults,
                using: workerSessionService
            )
        }
    }
}
