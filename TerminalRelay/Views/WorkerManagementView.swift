import Foundation
import SwiftUI

private enum WorkersPalette {
    static let page = Color(red: 21.0 / 255.0, green: 23.0 / 255.0, blue: 25.0 / 255.0)
    static let card = Color(red: 30.0 / 255.0, green: 32.0 / 255.0, blue: 34.0 / 255.0)
    static let cardHighlight = Color.white.opacity(0.012)
    static let border = Color(red: 50.0 / 255.0, green: 52.0 / 255.0, blue: 54.0 / 255.0)
    static let divider = Color(red: 45.0 / 255.0, green: 47.0 / 255.0, blue: 49.0 / 255.0)
    static let primary = Color(red: 245.0 / 255.0, green: 246.0 / 255.0, blue: 247.0 / 255.0)
    static let secondary = Color(red: 166.0 / 255.0, green: 169.0 / 255.0, blue: 172.0 / 255.0)
    static let tertiary = Color(red: 137.0 / 255.0, green: 140.0 / 255.0, blue: 144.0 / 255.0)
    static let blue = Color(red: 60.0 / 255.0, green: 134.0 / 255.0, blue: 245.0 / 255.0)
    static let green = Color(red: 86.0 / 255.0, green: 201.0 / 255.0, blue: 84.0 / 255.0)
    static let orange = Color(red: 1, green: 177.0 / 255.0, blue: 25.0 / 255.0)
    static let red = Color(red: 236.0 / 255.0, green: 98.0 / 255.0, blue: 84.0 / 255.0)
}

private enum WorkerHealth {
    case online
    case warning
    case offline
    case checking

    var label: String {
        switch self {
        case .online: "Online"
        case .warning: "Warning"
        case .offline: "Offline"
        case .checking: "Checking"
        }
    }

    var color: Color {
        switch self {
        case .online: WorkersPalette.green
        case .warning, .checking: WorkersPalette.orange
        case .offline: WorkersPalette.red
        }
    }
}

struct WorkersView: View {
    @EnvironmentObject private var serverStore: ServerStore
    @EnvironmentObject private var projectStore: ProjectStore
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @EnvironmentObject private var workerMetricsService: WorkerMetricsService

    let onSelectProject: (UUID) -> Void

    @State private var editorProfile: ServerProfile?
    @State private var pairingWorker: ServerProfile?
    @State private var workerPendingDeletion: ServerProfile?
    @State private var expandedWorkerIDs: Set<UUID> = []
    @State private var isRefreshingAll = false

    private let horizontalPadding: CGFloat = 38

    private var refreshTaskID: String {
        serverStore.servers
            .map { "\($0.id.uuidString)-\($0.destination)-\($0.port)" }
            .joined(separator: "|")
    }

    var body: some View {
        ZStack {
            WorkersPalette.page
                .ignoresSafeArea()

            if let editorProfile {
                editor(editorProfile)
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("")
        .sheet(item: $pairingWorker) { worker in
            MobilePairingView(worker: worker)
        }
        .task(id: refreshTaskID) {
            await refreshAll()
            await pollMetrics()
        }
    }

    private var overview: some View {
        GeometryReader { proxy in
            let contentWidth = max(
                proxy.size.width - horizontalPadding * 2,
                900
            )

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, 32)

                    if serverStore.servers.isEmpty {
                        emptyState
                    } else {
                        summary
                            .padding(.bottom, 22)

                        LazyVStack(spacing: 17) {
                            ForEach(serverStore.servers) { worker in
                                WorkerOverviewCard(
                                    worker: worker,
                                    projects: projectStore.projects(for: worker.id),
                                    health: health(for: worker),
                                    isExpanded: expandedWorkerIDs.contains(worker.id),
                                    isConfirmingDeletion: workerPendingDeletion?.id == worker.id,
                                    onToggleApps: { toggleApps(for: worker.id) },
                                    onOpenProject: onSelectProject,
                                    onPairMobile: {
                                        workerPendingDeletion = nil
                                        pairingWorker = worker
                                    },
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
                    }
                }
                .frame(
                    minWidth: contentWidth,
                    idealWidth: contentWidth,
                    maxWidth: contentWidth,
                    minHeight: max(proxy.size.height - 54, 0),
                    alignment: .topLeading
                )
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 22)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func editor(_ profile: ServerProfile) -> some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, horizontalPadding)
                .padding(.top, 22)
                .padding(.bottom, 18)

            Rectangle()
                .fill(WorkersPalette.divider)
                .frame(height: 1)

            WorkerEditorView(profile: profile) { savedProfile in
                serverStore.save(savedProfile)
                projectStore.updateServers(serverStore.servers)
                editorProfile = nil

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
                editorProfile = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 11) {
            VStack(alignment: .leading, spacing: 7) {
                Text(headerTitle)
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(WorkersPalette.primary)

                Text(
                    editorProfile == nil
                        ? "Accounts, capacity, and linked apps across every remote worker."
                        : "SSH connection and remote agent accounts"
                )
                .font(.system(size: 15))
                .foregroundStyle(WorkersPalette.secondary)
            }

            Spacer(minLength: 28)

            if editorProfile == nil {
                Button {
                    Task { await refreshAll(force: true) }
                } label: {
                    HStack(spacing: 9) {
                        if isRefreshingAll {
                            ProgressView()
                                .controlSize(.small)
                                .tint(WorkersPalette.primary)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 13, weight: .medium))
                        }
                        Text("Refresh")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(WorkersPalette.primary)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(
                        Color.white.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(WorkersPalette.border, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRefreshingAll)

                Button {
                    workerPendingDeletion = nil
                    editorProfile = newWorkerProfile()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .regular))
                        Text("Add worker")
                            .font(.system(size: 15, weight: .medium))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 40)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 20.0 / 255.0, green: 105.0 / 255.0, blue: 239.0 / 255.0),
                                Color(red: 9.0 / 255.0, green: 83.0 / 255.0, blue: 218.0 / 255.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.blue.opacity(0.9), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var headerTitle: String {
        guard let editorProfile else { return "Workers" }
        let name = editorProfile.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Add Worker" : "Edit \(name)"
    }

    private var summary: some View {
        WorkersSummaryBar(
            totalWorkers: serverStore.servers.count,
            onlineWorkers: serverStore.servers.count(where: isSummaryOnline),
            workersWithIssues: serverStore.servers.count(where: hasSummaryIssue),
            averageCPU: averageMetric {
                workerMetricsService.snapshot(for: $0.id)?.cpuUsedPercent
            },
            averageMemory: averageMetric {
                workerMetricsService.snapshot(for: $0.id)?.memoryUsedPercent
            },
            averageDisk: averageMetric {
                workerMetricsService.snapshot(for: $0.id)?.diskUsedPercent
            }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Workers", systemImage: "server.rack")
        } description: {
            Text("Set up a worker, or register one that is already prepared.")
        } actions: {
            Button("Add Worker") {
                editorProfile = newWorkerProfile()
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private func newWorkerProfile() -> ServerProfile {
        ServerProfile(
            username: "terminal-relay",
            workingDirectory: WorkerRegistrationURL.workingDirectory,
            codexCommand: WorkerRegistrationURL.codexCommand,
            claudeCommand: WorkerRegistrationURL.claudeCommand
        )
    }

    private func health(for worker: ServerProfile) -> WorkerHealth {
        if workerMetricsService.error(for: worker.id) != nil {
            return .offline
        }

        let hasUnavailableAccount = AgentKind.allCases.contains { kind in
            accountUsageService.error(for: worker.id, kind: kind) != nil
                && !accountUsageService.requiresNewSessionSignIn(
                    workerID: worker.id,
                    kind: kind
                )
        }
        if hasUnavailableAccount {
            return .offline
        }

        let requiresSignIn = AgentKind.allCases.contains { kind in
            accountUsageService.requiresNewSessionSignIn(
                workerID: worker.id,
                kind: kind
            )
        }
        if requiresSignIn {
            return .warning
        }

        if workerMetricsService.snapshot(for: worker.id) != nil {
            return .online
        }

        let isCheckingAccounts = AgentKind.allCases.contains { kind in
            accountUsageService.isLoading(workerID: worker.id, kind: kind)
        }
        if workerMetricsService.isLoading(workerID: worker.id) || isCheckingAccounts {
            return .checking
        }

        return .warning
    }

    private func averageMetric(_ value: (ServerProfile) -> Double?) -> Double? {
        let values = serverStore.servers.compactMap(value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func isSummaryOnline(_ worker: ServerProfile) -> Bool {
        workerMetricsService.snapshot(for: worker.id) != nil
            && workerMetricsService.error(for: worker.id) == nil
            && !AgentKind.allCases.contains { kind in
                accountUsageService.requiresNewSessionSignIn(
                    workerID: worker.id,
                    kind: kind
                )
            }
    }

    private func hasSummaryIssue(_ worker: ServerProfile) -> Bool {
        workerMetricsService.error(for: worker.id) != nil
            || AgentKind.allCases.contains { kind in
                accountUsageService.requiresNewSessionSignIn(
                    workerID: worker.id,
                    kind: kind
                )
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

private struct WorkersSummaryBar: View {
    let totalWorkers: Int
    let onlineWorkers: Int
    let workersWithIssues: Int
    let averageCPU: Double?
    let averageMemory: Double?
    let averageDisk: Double?

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - 5, 0)

            HStack(spacing: 0) {
                SummaryStat(
                    marker: .systemImage("person.2"),
                    value: String(totalWorkers),
                    label: "Total workers"
                )
                .frame(width: availableWidth * 0.169)

                summaryDivider

                SummaryStat(
                    marker: .dot(WorkersPalette.green),
                    value: String(onlineWorkers),
                    label: "Online"
                )
                .frame(width: availableWidth * 0.150)

                summaryDivider

                SummaryStat(
                    marker: .dot(WorkersPalette.orange),
                    value: String(workersWithIssues),
                    label: "With issues"
                )
                .frame(width: availableWidth * 0.156)

                summaryDivider

                SummaryStat(
                    marker: .systemImage("waveform.path.ecg.rectangle"),
                    value: percentage(averageCPU),
                    label: "Avg. CPU"
                )
                .frame(width: availableWidth * 0.169)

                summaryDivider

                SummaryStat(
                    marker: .systemImage("memorychip"),
                    value: percentage(averageMemory),
                    label: "Avg. Memory"
                )
                .frame(width: availableWidth * 0.176)

                summaryDivider

                SummaryStat(
                    marker: .systemImage("internaldrive"),
                    value: percentage(averageDisk),
                    label: "Avg. Disk"
                )
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 112)
        .background(
            LinearGradient(
                colors: [WorkersPalette.cardHighlight, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(WorkersPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WorkersPalette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var summaryDivider: some View {
        Rectangle()
            .fill(WorkersPalette.divider)
            .frame(width: 1, height: 48)
    }

    private func percentage(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f%%", min(max(value, 0), 100))
    }
}

private struct SummaryStat: View {
    enum Marker {
        case systemImage(String)
        case dot(Color)
    }

    let marker: Marker
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 14) {
            Group {
                switch marker {
                case .systemImage(let name):
                    Image(systemName: name)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(WorkersPalette.secondary)
                case .dot(let color):
                    Circle()
                        .fill(color)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 22)

            VStack(alignment: .leading, spacing: 6) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(WorkersPalette.primary)
                    .lineLimit(1)

                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(WorkersPalette.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct WorkerOverviewCard: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @EnvironmentObject private var workerMetricsService: WorkerMetricsService
    @EnvironmentObject private var workerSessionService: WorkerSessionService

    let worker: ServerProfile
    let projects: [ProjectProfile]
    let health: WorkerHealth
    let isExpanded: Bool
    let isConfirmingDeletion: Bool
    let onToggleApps: () -> Void
    let onOpenProject: (UUID) -> Void
    let onPairMobile: () -> Void
    let onEdit: () -> Void
    let onRequestDelete: () -> Void
    let onCancelDelete: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let availableWidth = max(proxy.size.width - 4, 0)

                HStack(spacing: 0) {
                    WorkerIdentityColumn(
                        worker: worker,
                        health: health,
                        issueKind: primaryIssueKind,
                        issueLabel: primaryIssueLabel,
                        currentAccount: primaryIssueKind.flatMap {
                            accountUsageService.snapshot(for: worker.id, kind: $0)?.account
                        },
                        hasActiveAgent: primaryIssueKind.map {
                            sessionManager.occupant(for: worker, kind: $0) != nil
                        } ?? false,
                        requiresNewSessionSignIn: primaryIssueKind.map {
                            accountUsageService.requiresNewSessionSignIn(
                                workerID: worker.id,
                                kind: $0
                            )
                        } ?? false,
                        isSessionOperationInProgress: primaryIssueKind.map {
                            workerSessionService.isStarting(worker: worker, kind: $0)
                                || workerSessionService.isStopping(worker: worker, kind: $0)
                        } ?? false
                    )
                    .frame(width: availableWidth * 0.237)

                    cardDivider

                    WorkerCapacityColumn(
                        snapshot: workerMetricsService.snapshot(for: worker.id),
                        errorMessage: workerMetricsService.error(for: worker.id),
                        isLoading: workerMetricsService.isLoading(workerID: worker.id)
                    )
                    .frame(width: availableWidth * 0.221)

                    cardDivider

                    WorkerAccountColumn(
                        worker: worker,
                        kind: .codex,
                        accountFallback: worker.accountLabel(for: .codex),
                        snapshot: accountUsageService.snapshot(for: worker.id, kind: .codex),
                        errorMessage: accountUsageService.error(for: worker.id, kind: .codex),
                        isLoading: accountUsageService.isLoading(workerID: worker.id, kind: .codex),
                        requiresNewSessionSignIn: accountUsageService.requiresNewSessionSignIn(
                            workerID: worker.id,
                            kind: .codex
                        )
                    )
                    .frame(width: availableWidth * 0.185)

                    cardDivider

                    WorkerAccountColumn(
                        worker: worker,
                        kind: .claude,
                        accountFallback: worker.accountLabel(for: .claude),
                        snapshot: accountUsageService.snapshot(for: worker.id, kind: .claude),
                        errorMessage: accountUsageService.error(for: worker.id, kind: .claude),
                        isLoading: accountUsageService.isLoading(workerID: worker.id, kind: .claude),
                        requiresNewSessionSignIn: accountUsageService.requiresNewSessionSignIn(
                            workerID: worker.id,
                            kind: .claude
                        )
                    )
                    .frame(width: availableWidth * 0.201)

                    cardDivider

                    WorkerLinkedAppsColumn(
                        projects: projects,
                        isExpanded: isExpanded,
                        onToggle: onToggleApps,
                        onPairMobile: onPairMobile,
                        onEdit: onEdit,
                        onRequestDelete: onRequestDelete
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 126)

            if isExpanded {
                Rectangle()
                    .fill(WorkersPalette.divider)
                    .frame(height: 1)

                if projects.isEmpty {
                    Text("No apps are linked to this worker.")
                        .font(.system(size: 13))
                        .foregroundStyle(WorkersPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                } else {
                    VStack(spacing: 0) {
                        ForEach(projects) { project in
                            LinkedAppRow(
                                project: project,
                                sessions: sessionManager.sessions(forProjectID: project.id),
                                onOpen: { onOpenProject(project.id) }
                            )

                            if project.id != projects.last?.id {
                                Rectangle()
                                    .fill(WorkersPalette.divider)
                                    .frame(height: 1)
                                    .padding(.leading, 54)
                            }
                        }
                    }
                }
            }

            if isConfirmingDeletion {
                Rectangle()
                    .fill(WorkersPalette.divider)
                    .frame(height: 1)

                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(WorkersPalette.red)
                    Text("Remove this saved worker? Remote files will not be deleted.")
                        .font(.system(size: 13))
                        .foregroundStyle(WorkersPalette.primary)
                    Spacer()
                    Button("Cancel", action: onCancelDelete)
                    Button("Delete Worker", role: .destructive, action: onDelete)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(WorkersPalette.red.opacity(0.06))
            }
        }
        .background(
            LinearGradient(
                colors: [WorkersPalette.cardHighlight, Color.clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .background(WorkersPalette.card)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(WorkersPalette.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var cardDivider: some View {
        Rectangle()
            .fill(WorkersPalette.divider)
            .frame(width: 1)
            .padding(.vertical, 25)
    }

    private var primaryIssueKind: AgentKind? {
        AgentKind.allCases.first { kind in
            accountUsageService.requiresNewSessionSignIn(
                workerID: worker.id,
                kind: kind
            ) || accountUsageService.error(for: worker.id, kind: kind) != nil
        }
    }

    private var primaryIssueLabel: String? {
        guard let kind = primaryIssueKind else { return nil }
        if accountUsageService.requiresNewSessionSignIn(
            workerID: worker.id,
            kind: kind
        ) {
            return "Signed out"
        }
        return "Unavailable"
    }
}

private struct WorkerIdentityColumn: View {
    let worker: ServerProfile
    let health: WorkerHealth
    let issueKind: AgentKind?
    let issueLabel: String?
    let currentAccount: String?
    let hasActiveAgent: Bool
    let requiresNewSessionSignIn: Bool
    let isSessionOperationInProgress: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "server.rack")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(WorkersPalette.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(worker.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(WorkersPalette.primary)
                    .lineLimit(1)

                Text(connectionSummary)
                    .font(.system(size: 11))
                    .foregroundStyle(WorkersPalette.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 5)

                Spacer(minLength: 7)

                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(health.color)
                            .frame(width: 9, height: 9)
                        Text(health.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WorkersPalette.primary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 23)
                    .background(
                        health.color.opacity(0.13),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .fixedSize()

                    if let issueLabel {
                        Text(issueLabel)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(WorkersPalette.red)
                            .lineLimit(1)
                            .fixedSize()
                    }

                    if let issueKind {
                        AccountChangeButton(
                            worker: worker,
                            kind: issueKind,
                            currentAccount: currentAccount,
                            hasActiveAgent: hasActiveAgent,
                            requiresNewSessionSignIn: requiresNewSessionSignIn,
                            isSessionOperationInProgress: isSessionOperationInProgress,
                            controlSize: .mini,
                            showsIcon: false
                        )
                        .fixedSize()
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.leading, 19)
        .padding(.trailing, 13)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var connectionSummary: String {
        var value = worker.destination
        if worker.port != 22 { value += ":\(worker.port)" }
        return value
    }
}

private struct WorkerCapacityColumn: View {
    let snapshot: WorkerMetricsSnapshot?
    let errorMessage: String?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            WorkerMetricCell(
                title: "CPU",
                percentage: snapshot?.cpuUsedPercent,
                detail: snapshot == nil ? nil : "Host utilization",
                errorMessage: errorMessage,
                isLoading: isLoading
            )
            WorkerMetricCell(
                title: "Memory",
                percentage: snapshot?.memoryUsedPercent,
                detail: snapshot.map {
                    "\(byteCount($0.memoryUsedBytes)) of \(byteCount($0.memoryTotalBytes))"
                },
                errorMessage: errorMessage,
                isLoading: isLoading
            )
            WorkerMetricCell(
                title: "Disk",
                percentage: snapshot?.diskUsedPercent,
                detail: snapshot.map {
                    "\(byteCount($0.diskUsedBytes)) of \(byteCount($0.diskTotalBytes))"
                },
                errorMessage: errorMessage,
                isLoading: isLoading
            )
        }
        .padding(.horizontal, 17)
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

private struct WorkerMetricCell: View {
    let title: String
    let percentage: Double?
    let detail: String?
    let errorMessage: String?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(WorkersPalette.secondary)
                .lineLimit(1)

            Group {
                if isLoading && percentage == nil {
                    ProgressView()
                        .controlSize(.mini)
                } else if let percentage {
                    Text(percentText(percentage))
                        .monospacedDigit()
                } else {
                    Text("—")
                        .foregroundStyle(errorMessage == nil ? WorkersPalette.secondary : WorkersPalette.red)
                }
            }
            .font(.system(size: 15))
            .foregroundStyle(WorkersPalette.primary)
            .padding(.top, 15)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                    if let percentage {
                        Capsule()
                            .fill(metricTint(percentage))
                            .frame(
                                width: max(
                                    percentage > 0 ? 7 : 0,
                                    proxy.size.width * min(max(percentage, 0), 100) / 100
                                )
                            )
                    }
                }
            }
            .frame(height: 4)
            .padding(.top, 8)
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
        String(format: "%.1f%%", min(max(value, 0), 100))
    }

    private func metricTint(_ value: Double) -> Color {
        if value >= 90 { return WorkersPalette.red }
        if value >= 75 { return WorkersPalette.orange }
        return WorkersPalette.blue
    }
}

private struct WorkerAccountColumn: View {
    @EnvironmentObject private var sessionManager: SessionManager
    @EnvironmentObject private var workerSessionService: WorkerSessionService

    let worker: ServerProfile
    let kind: AgentKind
    let accountFallback: String
    let snapshot: AccountUsageSnapshot?
    let errorMessage: String?
    let isLoading: Bool
    let requiresNewSessionSignIn: Bool

    @State private var isHovering = false
    @FocusState private var isAccountActionFocused: Bool

    private var productName: String {
        kind == .claude ? "Claude Code" : "Codex"
    }

    private var accountDetail: String {
        let account = snapshot?.account ?? accountFallback
        guard let plan = snapshot?.plan, !plan.isEmpty else { return account }
        return "\(account) · \(plan.capitalized)"
    }

    private var connectionState: (label: String, color: Color) {
        if requiresNewSessionSignIn {
            return ("Signed out", WorkersPalette.orange)
        }
        if errorMessage != nil {
            return ("Unavailable", WorkersPalette.red)
        }
        if snapshot != nil {
            return (isLoading ? "Refreshing" : "Connected", WorkersPalette.green)
        }
        if isLoading {
            return ("Checking", WorkersPalette.orange)
        }
        return ("Not checked", WorkersPalette.tertiary)
    }

    private var hasActiveAgent: Bool {
        sessionManager.occupant(for: worker, kind: kind) != nil
    }

    private var isAccountActionDisabled: Bool {
        workerSessionService.isStarting(worker: worker, kind: kind)
            || workerSessionService.isStopping(worker: worker, kind: kind)
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(productName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(WorkersPalette.primary)
                        .lineLimit(1)

                    Circle()
                        .fill(connectionState.color)
                        .frame(width: 8, height: 8)
                }

                HStack(spacing: 8) {
                    AgentBrandIcon(kind: kind, size: 17)

                    Text(accountDetail)
                        .font(.system(size: 11))
                        .foregroundStyle(WorkersPalette.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            AccountChangeButton(
                worker: worker,
                kind: kind,
                currentAccount: snapshot?.account,
                hasActiveAgent: hasActiveAgent,
                requiresNewSessionSignIn: requiresNewSessionSignIn,
                isSessionOperationInProgress: isAccountActionDisabled,
                controlSize: .mini,
                showsIcon: false
            )
            .fixedSize()
            .focused($isAccountActionFocused)
            .opacity(isHovering || isAccountActionFocused ? 1 : 0.001)
            .allowsHitTesting(isHovering || isAccountActionFocused)
        }
        .padding(.horizontal, 18)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help(accountHelp)
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
            lines.append(
                requiresNewSessionSignIn && hasActiveAgent
                    ? "Sign in once, then restart this terminal to use the worker's shared \(productName) account."
                    : errorMessage
            )
        }
        return lines.joined(separator: "\n")
    }
}

private struct WorkerLinkedAppsColumn: View {
    let projects: [ProjectProfile]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onPairMobile: () -> Void
    let onEdit: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Linked apps")
                    .font(.system(size: 13))
                    .foregroundStyle(WorkersPalette.secondary)

                Text(linkedAppsTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(WorkersPalette.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16)
            .padding(.trailing, 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .overlay(alignment: .topTrailing) {
            ZStack {
                Image(systemName: "ellipsis.vertical")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WorkersPalette.secondary)
                    .frame(width: 24, height: 24)
                    .allowsHitTesting(false)

                Menu {
                    Button(
                        "Pair iPhone or iPad",
                        systemImage: "qrcode",
                        action: onPairMobile
                    )
                    Divider()
                    Button("Edit", systemImage: "pencil", action: onEdit)
                    Button(
                        "Delete",
                        systemImage: "trash",
                        role: .destructive,
                        action: onRequestDelete
                    )
                    .disabled(!projects.isEmpty)
                } label: {
                    Color.clear
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Worker actions")
                .accessibilityLabel("Worker actions")
            }
            .padding(.top, 20)
            .padding(.trailing, 9)
        }
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var linkedAppsTitle: String {
        projects.count == 1 ? "1 linked app" : "\(projects.count) linked apps"
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
                .font(.system(size: 12))
                .foregroundStyle(WorkersPalette.tertiary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.githubRepository)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkersPalette.primary)
                Text(project.workingDirectory)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(WorkersPalette.tertiary)
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
        .padding(.horizontal, 18)
        .frame(minHeight: 44)
    }
}
