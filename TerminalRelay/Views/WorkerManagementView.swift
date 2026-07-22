import Foundation
import SwiftUI

struct WorkersView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @EnvironmentObject private var workerMetricsService: WorkerMetricsService

    let focusedWorkerID: UUID?
    let onSelectProject: (UUID) -> Void
    let onShowAllWorkers: () -> Void

    @State private var editorProfile: ServerProfile?
    @State private var workerPendingDeletion: ServerProfile?
    @State private var expandedWorkerIDs: Set<UUID> = []
    @State private var isRefreshingAll = false

    private var refreshTaskID: String {
        displayedWorkers
            .map { "\($0.id.uuidString)-\($0.destination)-\($0.port)" }
            .joined(separator: "|")
    }

    private var focusedWorker: ServerProfile? {
        focusedWorkerID.flatMap(serverStore.server(id:))
    }

    private var displayedWorkers: [ServerProfile] {
        if let focusedWorker {
            return [focusedWorker]
        }
        return serverStore.servers
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
            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.title2.weight(.semibold))
                Text(
                    editorProfile == nil
                        ? headerSubtitle
                        : "SSH connection and remote agent accounts"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if editorProfile == nil {
                if focusedWorker != nil {
                    Button(action: onShowAllWorkers) {
                        Label("All Workers", systemImage: "server.rack")
                    }
                    .buttonStyle(.bordered)
                }

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
                .disabled(isRefreshingAll)

                if focusedWorker == nil {
                    Button {
                        workerPendingDeletion = nil
                        editorProfile = ServerProfile()
                    } label: {
                        Label("Add Worker", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.horizontal, 24)
        .frame(minHeight: 72)
    }

    private var headerTitle: String {
        guard let editorProfile else { return focusedWorker?.displayName ?? "Workers" }
        let name = editorProfile.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Add Worker" : "Edit \(name)"
    }

    private var headerSubtitle: String {
        guard let focusedWorker else {
            return "Accounts, capacity, and linked apps across every remote worker."
        }
        return "Accounts, capacity, and linked apps on \(focusedWorker.destination)."
    }

    private var workerList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(displayedWorkers) { worker in
                    WorkerOverviewCard(
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
                }
            }
            .padding(24)
            .frame(maxWidth: 980)
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
            for worker in displayedWorkers {
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
                for worker in displayedWorkers {
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

private struct WorkerOverviewCard: View {
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
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(worker.displayName)
                        .font(.headline)
                    Text(connectionSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Edit", action: onEdit)
                    .buttonStyle(.borderless)

                Button("Delete", role: .destructive, action: onRequestDelete)
                    .buttonStyle(.borderless)
                    .disabled(!projects.isEmpty)
                    .help(
                        projects.isEmpty
                            ? "Delete worker"
                            : "Reassign or remove this worker's linked apps first"
                    )
            }
            .padding(16)

            Divider()

            WorkerResourceSummary(
                snapshot: workerMetricsService.snapshot(for: worker.id),
                errorMessage: workerMetricsService.error(for: worker.id),
                isLoading: workerMetricsService.isLoading(workerID: worker.id)
            )
            .padding(16)

            Divider()

            HStack(alignment: .top, spacing: 12) {
                ForEach(AgentKind.allCases) { kind in
                    WorkerAccountStatus(
                        kind: kind,
                        accountFallback: worker.accountLabel(for: kind),
                        snapshot: accountUsageService.snapshot(for: worker.id, kind: kind),
                        errorMessage: accountUsageService.error(for: worker.id, kind: kind),
                        isLoading: accountUsageService.isLoading(workerID: worker.id, kind: kind)
                    )
                }
            }
            .padding(16)

            Divider()

            Button(action: onToggleApps) {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(linkedAppsTitle)
                        .font(.callout.weight(.medium))
                    Spacer()
                    Text("View details")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .frame(height: 42)

            if isExpanded {
                Divider()

                if projects.isEmpty {
                    Text("No apps are linked to this worker.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                } else {
                    VStack(spacing: 0) {
                        ForEach(projects) { project in
                            LinkedAppRow(
                                project: project,
                                sessions: sessionManager.sessions(forProjectID: project.id),
                                onOpen: { onOpenProject(project.id) }
                            )

                            if project.id != projects.last?.id {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
            }

            if isConfirmingDeletion {
                Divider()

                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Remove this saved worker? Remote files will not be deleted.")
                        .font(.callout)
                    Spacer()
                    Button("Cancel", action: onCancelDelete)
                    Button("Delete Worker", role: .destructive, action: onDelete)
                }
                .padding(16)
                .background(Color.red.opacity(0.055))
            }
        }
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

private struct WorkerResourceSummary: View {
    let snapshot: WorkerMetricsSnapshot?
    let errorMessage: String?
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 4)

                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if let percentage {
                Text(percentText(percentage))
                    .font(.title3.weight(.semibold))

                ProgressView(value: min(max(percentage, 0), 100), total: 100)
                    .tint(metricTint(percentage))

                Text(detail ?? "")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(isLoading ? "Reading…" : errorMessage ?? "Not checked")
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
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
    let kind: AgentKind
    let accountFallback: String
    let snapshot: AccountUsageSnapshot?
    let errorMessage: String?
    let isLoading: Bool

    private var productName: String {
        kind == .claude ? "Claude Code" : "Codex"
    }

    private var accountDetail: String {
        let account = snapshot?.account ?? accountFallback
        guard let plan = snapshot?.plan, !plan.isEmpty else { return account }
        return "\(account) · \(plan.capitalized)"
    }

    private var connectionState: (label: String, color: Color) {
        if errorMessage != nil { return ("Unavailable", .red) }
        if snapshot != nil { return (isLoading ? "Refreshing" : "Connected", .green) }
        if isLoading { return ("Checking", .orange) }
        return ("Not checked", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                AgentBrandIcon(kind: kind, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(productName)
                        .font(.callout.weight(.semibold))
                    Text(accountDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)

                HStack(spacing: 5) {
                    Circle()
                        .fill(connectionState.color)
                        .frame(width: 6, height: 6)
                    Text(connectionState.label)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot {
                VStack(spacing: 5) {
                    ForEach(snapshot.limits.prefix(2)) { limit in
                        HStack(alignment: .firstTextBaseline) {
                            Text(limit.name)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("\(limit.remainingPercentText)% left")
                                .fontWeight(.medium)
                        }
                        .font(.caption)
                    }

                    if kind == .codex, let resets = snapshot.codexResetCredits {
                        HStack {
                            Text("Earned resets")
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text("\(resets.availableCount) available")
                                .fontWeight(.medium)
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text(errorMessage ?? "Usage limits have not been read yet.")
                    .font(.caption)
                    .foregroundStyle(errorMessage == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }

        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
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
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.githubRepository)
                    .font(.callout.weight(.medium))
                Text(project.workingDirectory)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
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
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 50)
    }
}
