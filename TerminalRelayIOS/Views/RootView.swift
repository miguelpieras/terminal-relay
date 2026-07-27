import SwiftUI

private struct WorkerEditorRoute: Identifiable {
    let id = UUID()
    let profile: WorkerProfile?
    let showsProjectsAfterSave: Bool
}

private enum RootTab: Hashable {
    case projects
    case workers
}

struct RootView: View {
    @ObservedObject var model: WorkerSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = RootTab.projects
    @State private var editorRoute: WorkerEditorRoute?
    @State private var showsPairingScanner = false
    @State private var workerPendingDeletion: WorkerProfile?
    @State private var workerSearchText = ""

    private var filteredWorkerProfiles: [WorkerProfile] {
        model.profiles.filter {
            WorkerOverviewFilter.matches(
                profile: $0,
                snapshot: model.workerOverviews[$0.id],
                query: workerSearchText
            )
        }
    }

    private var workerRefreshTaskID: String {
        model.profiles
            .map { "\($0.id.uuidString):\($0.host):\($0.port)" }
            .joined(separator: "|")
    }

    private var workerUpdateWarning: (profile: WorkerProfile, message: String)? {
        for profile in model.profiles {
            if let message = model.updateWarning(for: profile.id) {
                return (profile, message)
            }
        }
        return nil
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ProjectListView(model: model) {
                    showsPairingScanner = true
                }
            }
            .tabItem {
                Label("Projects", systemImage: "folder")
            }
            .tag(RootTab.projects)

            NavigationStack {
                workerList
            }
            .tabItem {
                Label("Workers", systemImage: "server.rack")
            }
            .tag(RootTab.workers)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let warning = workerUpdateWarning {
                WorkerUpdateWarningBanner(
                    workerName: warning.profile.displayName,
                    message: warning.message
                ) {
                    model.dismissUpdateWarning(for: warning.profile.id)
                }
            }
        }
        .sheet(item: $editorRoute) { route in
            NavigationStack {
                WorkerOnboardingView(
                    model: model,
                    profile: route.profile,
                    allowsCancel: true
                ) {
                    editorRoute = nil
                    if route.showsProjectsAfterSave {
                        selectedTab = .projects
                    }
                    Task { await model.refresh() }
                }
            }
        }
        .sheet(isPresented: $showsPairingScanner) {
            PairingScannerView { code in
                showsPairingScanner = false
                Task {
                    if await model.pair(with: code) {
                        selectedTab = .projects
                    }
                }
            }
        }
        .fullScreenCover(item: $model.terminalRoute, onDismiss: {
            Task {
                await model.refresh()
                model.markLastOpenedTerminalRead()
            }
        }) { route in
            if let profile = model.profile {
                TerminalScreen(profile: profile, route: route)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active,
               selectedTab == .projects,
               model.profile != nil,
               model.terminalRoute == nil {
                Task { await model.refresh() }
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == .workers {
                Task { await model.refreshWorkerOverviews() }
            }
        }
        .alert("Remove worker?", isPresented: Binding(
            get: { workerPendingDeletion != nil },
            set: { if !$0 { workerPendingDeletion = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                workerPendingDeletion = nil
            }
            Button("Remove", role: .destructive) {
                if let workerPendingDeletion {
                    model.deleteProfile(id: workerPendingDeletion.id)
                }
                workerPendingDeletion = nil
            }
        } message: {
            Text("This removes the worker connection from this device. It does not change or stop the remote worker.")
        }
        .alert(
            "Terminal Relay",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
        .overlay {
            if model.isPairing {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                    ProgressView("Pairing securely…")
                        .padding(20)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    @ViewBuilder
    private var workerList: some View {
        Group {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Workers", systemImage: "server.rack")
                } description: {
                    Text("Scan the private pairing code shown by Terminal Relay on your Mac.")
                } actions: {
                    Button("Scan Mac Pairing Code") {
                        showsPairingScanner = true
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Add Manually") {
                        editorRoute = WorkerEditorRoute(
                            profile: nil,
                            showsProjectsAfterSave: true
                        )
                    }
                }
            } else {
                List {
                    if filteredWorkerProfiles.isEmpty {
                        ContentUnavailableView.search(text: workerSearchText)
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(filteredWorkerProfiles) { profile in
                            WorkerOverviewRow(
                                profile: profile,
                                snapshot: model.workerOverviews[profile.id],
                                isLoading: model.workerLoadingIDs.contains(profile.id)
                            )
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) {
                                    workerPendingDeletion = profile
                                }
                                Button("Edit") {
                                    editorRoute = WorkerEditorRoute(
                                        profile: profile,
                                        showsProjectsAfterSave: false
                                    )
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    editorRoute = WorkerEditorRoute(
                                        profile: profile,
                                        showsProjectsAfterSave: false
                                    )
                                } label: {
                                    Label("Edit Worker", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    workerPendingDeletion = profile
                                } label: {
                                    Label("Remove Worker", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .searchable(text: $workerSearchText, prompt: "Filter workers or projects")
                .refreshable {
                    await model.refreshWorkerOverviews()
                }
            }
        }
        .navigationTitle("Workers")
        .task(id: workerRefreshTaskID) {
            if selectedTab == .workers {
                await model.refreshWorkerOverviews()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showsPairingScanner = true
                    } label: {
                        Label("Scan Mac Pairing Code", systemImage: "qrcode.viewfinder")
                    }

                    Button {
                        editorRoute = WorkerEditorRoute(
                            profile: nil,
                            showsProjectsAfterSave: true
                        )
                    } label: {
                        Label("Add Manually", systemImage: "keyboard")
                    }
                } label: {
                    Label("Add Worker", systemImage: "plus")
                }
            }
        }
    }
}

private struct WorkerUpdateWarningBanner: View {
    let workerName: String
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(workerName) update needs attention")
                    .font(.caption.weight(.semibold))
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss update warning")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct WorkerOverviewRow: View {
    let profile: WorkerProfile
    let snapshot: WorkerOverviewSnapshot?
    let isLoading: Bool

    private var status: (label: String, color: Color) {
        if let snapshot {
            return snapshot.isOnline ? ("Online", .green) : ("Unavailable", .red)
        }
        return isLoading ? ("Checking", .orange) : ("Not checked", .secondary)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "server.rack")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.body.weight(.semibold))
                        Circle()
                            .fill(status.color)
                            .frame(width: 7, height: 7)
                            .accessibilityLabel(status.label)
                    }
                    Text("\(profile.username)@\(profile.host)\(profile.port == 22 ? "" : ":\(profile.port)")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if let snapshot, snapshot.isOnline {
                HStack(spacing: 16) {
                    Label(
                        "\(snapshot.projects.count) \(snapshot.projects.count == 1 ? "project" : "projects")",
                        systemImage: "folder"
                    )
                    Label(
                        "\(snapshot.sessions.count) active \(snapshot.sessions.count == 1 ? "task" : "tasks")",
                        systemImage: "terminal"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if !snapshot.projects.isEmpty {
                    Text(snapshot.projects.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let resources = snapshot.resources {
                    HStack(spacing: 8) {
                        WorkerMetricPill(title: "CPU", value: resources.cpuUsedPercent)
                        WorkerMetricPill(title: "Memory", value: resources.memoryUsedPercent)
                        WorkerMetricPill(title: "Disk", value: resources.diskUsedPercent)
                    }
                } else {
                    Label("System usage unavailable", systemImage: "gauge.with.dots.needle.0percent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 9) {
                    ForEach(AgentKind.allCases) { kind in
                        WorkerAccountOverviewRow(
                            kind: kind,
                            snapshot: snapshot.accounts[kind],
                            hasError: snapshot.accountErrors.contains(kind)
                        )
                    }
                }
            } else if let message = snapshot?.connectionError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else {
                Text(isLoading ? "Loading worker status and account usage…" : "Pull to refresh worker status.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct WorkerMetricPill: View {
    let title: String
    let value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text("\(Int(value.rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(metricColor)
            }
            .font(.caption2.weight(.medium))

            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(metricColor)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var metricColor: Color {
        if value >= 90 { return .red }
        if value >= 75 { return .orange }
        return .accentColor
    }
}

private struct WorkerAccountOverviewRow: View {
    let kind: AgentKind
    let snapshot: WorkerAccountSnapshot?
    let hasError: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(kind == .codex ? Color.blue : Color.orange)
                .frame(width: 28, height: 28)
                .background(
                    (kind == .codex ? Color.blue : Color.orange).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 7)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.displayName)
                    .font(.caption.weight(.semibold))
                Text(accountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(usageLabel)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(hasError ? Color.red : Color.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private var accountLabel: String {
        guard let snapshot else { return hasError ? "Usage unavailable" : "Not checked" }
        let account = snapshot.account ?? "Signed in"
        guard let plan = snapshot.plan, !plan.isEmpty else { return account }
        return "\(account) · \(plan.capitalized)"
    }

    private var usageLabel: String {
        guard let snapshot else { return hasError ? "Unavailable" : "—" }
        let labels = snapshot.limits.prefix(2).map {
            "\($0.name) \(Int($0.remainingPercent.rounded()))% left"
        }
        return labels.isEmpty ? "Connected" : labels.joined(separator: "\n")
    }
}
