import Foundation
import SwiftUI

struct WorkersView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @EnvironmentObject private var workerMetricsService: WorkerMetricsService

    let onSelectProject: (UUID) -> Void

    @State private var editorProfile: ServerProfile?
    @State private var workerPendingDeletion: ServerProfile?
    @State private var expandedWorkerIDs: Set<UUID> = []
    @State private var isRefreshingAll = false

    private var refreshTaskID: String {
        serverStore.servers
            .map { "\($0.id.uuidString)-\($0.destination)-\($0.port)" }
            .joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let editorProfile {
                WorkerEditorView(profile: editorProfile) { savedProfile in
                    serverStore.save(savedProfile)
                    projectStore.updateServers(serverStore.servers)
                    self.editorProfile = nil

                    Task {
                        async let accountRefresh: Void = accountUsageService.refresh(
                            worker: savedProfile,
                            force: true
                        )
                        async let metricsRefresh: Void = workerMetricsService.refresh(
                            worker: savedProfile,
                            force: true
                        )
                        _ = await (accountRefresh, metricsRefresh)
                    }
                } onCancel: {
                    self.editorProfile = nil
                }
            } else if serverStore.servers.isEmpty {
                ContentUnavailableView {
                    Label("No Workers", systemImage: "server.rack")
                } description: {
                    Text("Add a remote worker before creating a project.")
                } actions: {
                    Button("Add Worker") {
                        editorProfile = ServerProfile()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workerList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Workers")
        .task(id: refreshTaskID) {
            await refreshAll()
            await pollMetrics()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text(
                    editorProfile == nil
                        ? "Accounts, capacity, and linked apps across every remote worker."
                        : "SSH connection and remote agent accounts"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if editorProfile == nil {
                Button {
                    Task { await refreshAll(force: true) }
                } label: {
                    if isRefreshingAll {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshingAll)

                Button {
                    workerPendingDeletion = nil
                    editorProfile = ServerProfile()
                } label: {
                    Label("Add Worker", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
    }

    private var headerTitle: String {
        guard let editorProfile else { return "Workers" }
        let name = editorProfile.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Add Worker" : "Edit \(name)"
    }

    private var workerList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(serverStore.servers) { worker in
                    WorkerOverviewRow(
                        worker: worker,
                        projects: projectStore.projects(for: worker.id),
                        isExpanded: expandedWorkerIDs.contains(worker.id),
                        isConfirmingDeletion: workerPendingDeletion?.id == worker.id,
                        onToggleApps: { toggleApps(for: worker.id) },
                        onOpenProject: onSelectProject,
                        onEdit: {
                            workerPendingDeletion = nil
                            editorProfile = worker
                        },
                        onRequestDelete: {
                            workerPendingDeletion = worker
                        },
                        onCancelDelete: {
                            workerPendingDeletion = nil
                        },
                        onDelete: {
                            delete(worker)
                        }
                    )

                    if worker.id != serverStore.servers.last?.id {
                        Divider()
                            .padding(.horizontal, 12)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: 1_060)
            .frame(maxWidth: .infinity)
        }
    }

    private func toggleApps(for workerID: UUID) {
        if expandedWorkerIDs.contains(workerID) {
            expandedWorkerIDs.remove(workerID)
        } else {
            expandedWorkerIDs.insert(workerID)
        }
    }

    private func refreshAll(force: Bool = false) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        await withTaskGroup(of: Void.self) { group in
            for worker in serverStore.servers {
                group.addTask {
                    await accountUsageService.refresh(worker: worker, force: force)
                }
                group.addTask {
                    await workerMetricsService.refresh(worker: worker, force: force)
                }
            }
        }
    }

    private func pollMetrics() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }

            await withTaskGroup(of: Void.self) { group in
                for worker in serverStore.servers {
                    group.addTask {
                        await workerMetricsService.refresh(worker: worker, force: true)
                    }
                }
            }
        }
    }

    private func delete(_ worker: ServerProfile) {
        guard projectStore.projects(for: worker.id).isEmpty else { return }
        sessionManager.closeSessions(for: worker)
        serverStore.delete(id: worker.id)
        projectStore.updateServers(serverStore.servers)
        expandedWorkerIDs.remove(worker.id)
        workerPendingDeletion = nil
    }
}

private struct WorkerOverviewRow: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @EnvironmentObject private var workerMetricsService: WorkerMetricsService

    let worker: ServerProfile
    let projects: [ProjectProfile]
    let isExpanded: Bool
    let isConfirmingDeletion: Bool
    let onToggleApps: () -> Void
    let onOpenProject: (UUID) -> Void
    let onEdit: () -> Void
    let onRequestDelete: () -> Void
    let onCancelDelete: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(worker.displayName)
                        .font(.callout.weight(.semibold))
                    Text(connectionSummary)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu {
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button("Delete", systemImage: "trash", role: .destructive, action: onRequestDelete)
                        .disabled(!projects.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 20, height: 20)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .help("Worker actions")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            HStack(spacing: 12) {
                WorkerSectionLabel("Capacity")

                WorkerResourceSummary(
                    snapshot: workerMetricsService.snapshot(for: worker.id),
                    errorMessage: workerMetricsService.error(for: worker.id),
                    isLoading: workerMetricsService.isLoading(workerID: worker.id)
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            HStack(spacing: 12) {
                WorkerSectionLabel("Accounts")

                HStack(alignment: .top, spacing: 18) {
                    ForEach(AgentKind.allCases) { kind in
                        WorkerAccountStatus(
                            worker: worker,
                            kind: kind,
                            accountFallback: worker.accountLabel(for: kind),
                            snapshot: accountUsageService.snapshot(for: worker.id, kind: kind),
                            errorMessage: accountUsageService.error(for: worker.id, kind: kind),
                            isLoading: accountUsageService.isLoading(workerID: worker.id, kind: kind),
                            isSignInRequired: accountUsageService.isSignInRequired(
                                workerID: worker.id,
                                kind: kind
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Button(action: onToggleApps) {
                HStack(spacing: 12) {
                    WorkerSectionLabel("Apps")

                    HStack(spacing: 6) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)
                        Text(linkedAppsTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .frame(height: 28)

            if isExpanded {
                if projects.isEmpty {
                    Text("No apps are linked to this worker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 78)
                        .padding(.trailing, 12)
                        .padding(.bottom, 6)
                } else {
                    VStack(spacing: 2) {
                        ForEach(projects) { project in
                            LinkedAppRow(
                                project: project,
                                sessions: sessionManager.sessions(forProjectID: project.id),
                                onOpen: { onOpenProject(project.id) }
                            )
                        }
                    }
                    .padding(.leading, 66)
                    .padding(.trailing, 12)
                    .padding(.bottom, 6)
                }
            }

            if isConfirmingDeletion {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Remove this saved worker? Remote files will not be deleted.")
                        .font(.callout)
                    Spacer()
                    Button("Cancel", action: onCancelDelete)
                    Button("Delete Worker", role: .destructive, action: onDelete)
                }
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(Color.red.opacity(0.055))
            }
        }
    }

    private var linkedAppsTitle: String {
        projects.count == 1 ? "1 linked app" : "\(projects.count) linked apps"
    }

    private var connectionSummary: String {
        var value = worker.destination
        if worker.port != 22 { value += ":\(worker.port)" }
        return value
    }
}

private struct WorkerSectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.tertiary)
            .frame(width: 54, alignment: .leading)
    }
}

private struct WorkerResourceSummary: View {
    let snapshot: WorkerMetricsSnapshot?
    let errorMessage: String?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 6) {
            WorkerMetricStatus(
                title: "CPU",
                systemImage: "cpu",
                percentage: snapshot?.cpuUsedPercent,
                detail: snapshot == nil ? nil : "Host utilization",
                errorMessage: errorMessage,
                isLoading: isLoading
            )
            WorkerMetricStatus(
                title: "Memory",
                systemImage: "memorychip",
                percentage: snapshot?.memoryUsedPercent,
                detail: snapshot.map {
                    "\(byteCount($0.memoryUsedBytes)) of \(byteCount($0.memoryTotalBytes))"
                },
                errorMessage: errorMessage,
                isLoading: isLoading
            )
            WorkerMetricStatus(
                title: "Disk",
                systemImage: "internaldrive",
                percentage: snapshot?.diskUsedPercent,
                detail: snapshot.map {
                    "\(byteCount($0.diskUsedBytes)) of \(byteCount($0.diskTotalBytes))"
                },
                errorMessage: errorMessage,
                isLoading: isLoading
            )
        }
    }

    private func byteCount(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.countStyle = .binary
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: value)
    }
}

private struct WorkerMetricStatus: View {
    let title: String
    let systemImage: String
    let percentage: Double?
    let detail: String?
    let errorMessage: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2.weight(.medium))

                Spacer(minLength: 2)

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                } else if let percentage {
                    Text(percentText(percentage))
                        .font(.caption2.monospacedDigit().weight(.medium))
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                }
            }

            if let percentage {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                        Capsule()
                            .fill(metricTint(percentage))
                            .frame(
                                width: proxy.size.width
                                    * min(max(percentage, 0), 100) / 100
                            )
                    }
                }
                .frame(height: 2)
            } else {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(metricHelp)
    }

    private var metricHelp: String {
        if let percentage {
            return [title, percentText(percentage), detail]
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return "\(title) · \(isLoading ? "Reading…" : errorMessage ?? "Not checked")"
    }

    private func percentText(_ value: Double) -> String {
        let clamped = min(max(value, 0), 100)
        if clamped.rounded() == clamped {
            return String(format: "%.0f%%", clamped)
        }
        return String(format: "%.1f%%", clamped)
    }

    private func metricTint(_ value: Double) -> Color {
        if value >= 90 { return .red }
        if value >= 75 { return .orange }
        return .accentColor
    }
}

private struct WorkerAccountStatus: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountAuthenticationService: AccountAuthenticationService

    let worker: ServerProfile
    let kind: AgentKind
    let accountFallback: String
    let snapshot: AccountUsageSnapshot?
    let errorMessage: String?
    let isLoading: Bool
    let isSignInRequired: Bool

    private var productName: String {
        kind == .claude ? "Claude Code" : "Codex"
    }

    private var accountDetail: String {
        let account = snapshot?.account ?? accountFallback
        guard let plan = snapshot?.plan, !plan.isEmpty else { return account }
        return "\(account) · \(plan.capitalized)"
    }

    private var connectionState: (label: String, color: Color) {
        if isSignInRequired { return ("Signed out", .orange) }
        if errorMessage != nil { return ("Unavailable", .red) }
        if snapshot != nil { return (isLoading ? "Refreshing" : "Connected", .green) }
        if isLoading { return ("Checking", .orange) }
        return ("Not checked", .secondary)
    }

    private var hasActiveAgent: Bool {
        sessionManager.occupant(for: worker, kind: kind) != nil
    }

    private var isAccountActionDisabled: Bool {
        hasActiveAgent && !isSignInRequired
    }

    var body: some View {
        HStack(spacing: 7) {
            AgentBrandIcon(kind: kind, size: 18)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(productName)
                        .font(.caption.weight(.semibold))
                    Circle()
                        .fill(connectionState.color)
                        .frame(width: 5, height: 5)
                }
                Text(accountDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(accountHelp)

            Spacer(minLength: 4)

            if let snapshot {
                Text(limitSummary(snapshot))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(connectionState.label)
                    .font(.caption2)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }

            Button(snapshot == nil ? "Sign In" : "Change") {
                accountAuthenticationService.begin(
                    worker: worker,
                    kind: kind,
                    currentAccount: snapshot?.account
                )
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
            .disabled(isAccountActionDisabled || accountAuthenticationService.isRunning)
            .help(accountActionHelp)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func limitSummary(_ snapshot: AccountUsageSnapshot) -> String {
        let limits = snapshot.limits.prefix(2).map {
            "\($0.name) \($0.remainingPercentText)%"
        }
        return limits.isEmpty ? connectionState.label : limits.joined(separator: " · ")
    }

    private var accountHelp: String {
        var lines = ["\(productName): \(connectionState.label)", accountDetail]
        if let snapshot {
            lines.append(contentsOf: snapshot.limits.prefix(2).map {
                "\($0.name): \($0.remainingPercentText)% left"
            })
            if kind == .codex, let resets = snapshot.codexResetCredits {
                lines.append("Earned resets: \(resets.availableCount) available")
            }
        } else if let errorMessage {
            lines.append(errorMessage)
        }
        return lines.joined(separator: "\n")
    }

    private var accountActionHelp: String {
        if isAccountActionDisabled {
            return "Stop the active \(productName) agent before changing its account."
        }
        return snapshot == nil
            ? "Sign in to \(productName) on \(worker.displayName)"
            : "Change the \(productName) account on \(worker.displayName)"
    }
}

private struct LinkedAppRow: View {
    let project: ProjectProfile
    let sessions: [TerminalSession]
    let onOpen: () -> Void

    private var activeKinds: [AgentKind] {
        AgentKind.allCases.filter { kind in
            sessions.contains { $0.kind == kind && $0.status.occupiesSlot }
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "folder")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.githubRepository)
                    .font(.caption.weight(.medium))
                Text(project.workingDirectory)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            ForEach(activeKinds) { kind in
                HStack(spacing: 4) {
                    AgentBrandIcon(kind: kind, size: 14)
                    Circle()
                        .fill(kind.tint)
                        .frame(width: 5, height: 5)
                }
                .help("\(kind.displayName) terminal open")
            }

            Button("Open", action: onOpen)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .frame(minHeight: 34)
    }
}
