import SwiftUI

private struct WorkerEditorRoute: Identifiable {
    let id = UUID()
    let profile: WorkerProfile?
    let showsProjectsAfterSave: Bool
}

private enum RootTab: Hashable {
    case projects
    case workers

    var label: String {
        switch self {
        case .projects: "Projects"
        case .workers: "Workers"
        }
    }

    var systemImage: String {
        switch self {
        case .projects: "folder"
        case .workers: "server.rack"
        }
    }
}

struct RootView: View {
    @ObservedObject var model: WorkerSessionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = RootTab.projects
    @State private var selectedProject: ProjectSelection?
    @State private var selectedWorkerID: UUID?
    @State private var editorRoute: WorkerEditorRoute?
    @State private var showsPairingScanner = false
    @State private var workerPendingDeletion: WorkerProfile?
    @State private var workerSearchText = ""
    @State private var splitColumnVisibility = NavigationSplitViewVisibility.all
    @State private var projectNavigationID = UUID()

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
        Group {
            if usesSplitWorkspace {
                splitWorkspace
            } else {
                compactWorkspace
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if model.isDemoMode {
                    DemoModeBanner {
                        exitDemo()
                    }
                }
                if model.terminalRoute == nil,
                   let warning = workerUpdateWarning {
                    WorkerUpdateWarningBanner(
                        workerName: warning.profile.displayName,
                        message: warning.message
                    ) {
                        model.dismissUpdateWarning(for: warning.profile.id)
                    }
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
        .fullScreenCover(item: compactTerminalRoute, onDismiss: refreshAfterTerminal) { route in
            if let profile = model.profile {
                TerminalScreen(
                    profile: profile,
                    route: route,
                    isDemo: model.isDemoMode,
                    onExitDemo: exitDemo
                )
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
                reconcileWorkerSelection()
                Task { await model.refreshWorkerOverviews() }
            }
        }
        .onChange(of: model.profiles.map(\.id)) { _, profileIDs in
            selectedWorkerID = AdaptiveSelectionPolicy.worker(
                current: selectedWorkerID,
                available: profileIDs
            )
            if let selectedProject,
               !profileIDs.contains(selectedProject.workerID) {
                self.selectedProject = nil
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
                    reconcileWorkerSelection()
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

    private var usesSplitWorkspace: Bool {
        horizontalSizeClass == .regular
    }

    private var compactWorkspace: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ProjectListView(
                    model: model,
                    onAddWorker: { showsPairingScanner = true },
                    onExploreDemo: enterDemo
                )
            }
            .id(projectNavigationID)
            .tabItem {
                Label("Projects", systemImage: "folder")
            }
            .tag(RootTab.projects)

            NavigationStack {
                workerList()
            }
            .tabItem {
                Label("Workers", systemImage: "server.rack")
            }
            .tag(RootTab.workers)
        }
    }

    private var splitWorkspace: some View {
        NavigationSplitView(columnVisibility: $splitColumnVisibility) {
            switch selectedTab {
            case .projects:
                IPadWorkspaceSidebar(
                    model: model,
                    selectedProject: $selectedProject,
                    onAddWorker: { showsPairingScanner = true },
                    onExploreDemo: enterDemo,
                    onShowWorkers: showWorkers
                )
            case .workers:
                workerList(usesSplitSelection: true)
            }
        } detail: {
            splitDetail
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private var splitDetail: some View {
        if let route = model.terminalRoute,
           let profile = model.profile {
            TerminalScreen(
                profile: profile,
                route: route,
                isDemo: model.isDemoMode,
                onExitDemo: exitDemo,
                onClose: closeEmbeddedTerminal
            )
            .id(route.id)
        } else {
            switch selectedTab {
            case .projects:
                if let selectedProject {
                    ProjectDetailView(
                        workerID: selectedProject.workerID,
                        repositoryName: selectedProject.repositoryName,
                        model: model
                    )
                    .id(selectedProject.id)
                } else {
                    ContentUnavailableView(
                        "Select a Project",
                        systemImage: "folder",
                        description: Text(
                            "Choose a project to see its conversations and threads."
                        )
                    )
                }
            case .workers:
                if let selectedWorkerID,
                   let profile = model.profiles.first(where: { $0.id == selectedWorkerID }) {
                    workerDetail(profile)
                } else {
                    ContentUnavailableView(
                        "Select a Worker",
                        systemImage: "server.rack",
                        description: Text("Choose a worker to inspect its status and accounts.")
                    )
                }
            }
        }
    }

    private var compactTerminalRoute: Binding<TerminalRoute?> {
        Binding(
            get: { usesSplitWorkspace ? nil : model.terminalRoute },
            set: { route in
                guard !usesSplitWorkspace else { return }
                model.terminalRoute = route
            }
        )
    }

    private var splitTabSelection: Binding<RootTab?> {
        Binding(
            get: { selectedTab },
            set: { selection in
                if let selection {
                    selectedTab = selection
                }
            }
        )
    }

    @ViewBuilder
    private func workerList(usesSplitSelection: Bool = false) -> some View {
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

                    Button("Explore Demo", action: enterDemo)
                }
            } else {
                Group {
                    if usesSplitSelection {
                        List(selection: $selectedWorkerID) {
                            workerRows(usesSplitSelection: true)
                        }
                    } else {
                        List {
                            workerRows(usesSplitSelection: false)
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
                if usesSplitSelection {
                    reconcileWorkerSelection()
                }
                await model.refreshWorkerOverviews()
            }
        }
        .toolbar {
            if usesSplitSelection {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        selectedTab = .projects
                    } label: {
                        Label("Projects", systemImage: "chevron.left")
                    }
                }
            }
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

    @ViewBuilder
    private func workerRows(usesSplitSelection: Bool) -> some View {
        if filteredWorkerProfiles.isEmpty {
            ContentUnavailableView.search(text: workerSearchText)
                .listRowBackground(Color.clear)
        } else {
            ForEach(filteredWorkerProfiles) { profile in
                Group {
                    if usesSplitSelection {
                        WorkerCompactRow(
                            profile: profile,
                            snapshot: model.workerOverviews[profile.id],
                            isLoading: model.workerLoadingIDs.contains(profile.id)
                        )
                    } else {
                        WorkerOverviewRow(
                            profile: profile,
                            snapshot: model.workerOverviews[profile.id],
                            isLoading: model.workerLoadingIDs.contains(profile.id)
                        )
                    }
                }
                .tag(profile.id)
                .modifier(
                    WorkerActionsModifier(
                        onEdit: { edit(profile) },
                        onRemove: { workerPendingDeletion = profile }
                    )
                )
            }
        }
    }

    private func workerDetail(_ profile: WorkerProfile) -> some View {
        ScrollView {
            WorkerOverviewRow(
                profile: profile,
                snapshot: model.workerOverviews[profile.id],
                isLoading: model.workerLoadingIDs.contains(profile.id)
            )
            .padding(24)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(profile.displayName)
        .refreshable {
            await model.refreshWorkerOverviews()
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    edit(profile)
                } label: {
                    Label("Edit Worker", systemImage: "pencil")
                }

                Menu {
                    Button(role: .destructive) {
                        workerPendingDeletion = profile
                    } label: {
                        Label("Remove Worker", systemImage: "trash")
                    }
                } label: {
                    Label("Worker Actions", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private func edit(_ profile: WorkerProfile) {
        editorRoute = WorkerEditorRoute(
            profile: profile,
            showsProjectsAfterSave: false
        )
    }

    private func reconcileWorkerSelection() {
        selectedWorkerID = AdaptiveSelectionPolicy.worker(
            current: selectedWorkerID,
            available: model.profiles.map(\.id)
        )
    }

    private func refreshAfterTerminal() {
        Task {
            await model.refresh()
            model.markLastOpenedTerminalRead()
        }
    }

    private func closeEmbeddedTerminal() {
        model.terminalRoute = nil
        refreshAfterTerminal()
    }

    private func showWorkers() {
        if model.terminalRoute != nil {
            closeEmbeddedTerminal()
        }
        selectedTab = .workers
        reconcileWorkerSelection()
    }

    private func enterDemo() {
        model.enterDemo()
        selectedTab = .projects
        selectedProject = ProjectSelection(
            workerID: DemoWorkspace.worker.id,
            repositoryName: DemoWorkspace.projects[0]
        )
        if usesSplitWorkspace, let session = DemoWorkspace.sessions.first {
            model.openTerminal(session)
        }
    }

    private func exitDemo() {
        projectNavigationID = UUID()
        selectedProject = nil
        selectedWorkerID = nil
        selectedTab = .projects
        model.exitDemo()
    }
}

enum AdaptiveSelectionPolicy {
    static func project(
        current: ProjectSelection?,
        available: [ProjectSelection]
    ) -> ProjectSelection? {
        guard !available.isEmpty else { return nil }
        if let current, available.contains(current) {
            return current
        }
        return available.first
    }

    static func worker(current: UUID?, available: [UUID]) -> UUID? {
        guard !available.isEmpty else { return nil }
        if let current, available.contains(current) {
            return current
        }
        return available.first
    }
}

private struct WorkerActionsModifier: ViewModifier {
    let onEdit: () -> Void
    let onRemove: () -> Void

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing) {
                Button("Remove", role: .destructive, action: onRemove)
                Button("Edit", action: onEdit)
                    .tint(.blue)
            }
            .contextMenu {
                Button(action: onEdit) {
                    Label("Edit Worker", systemImage: "pencil")
                }
                Button(role: .destructive, action: onRemove) {
                    Label("Remove Worker", systemImage: "trash")
                }
            }
    }
}

private struct WorkerCompactRow: View {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                    .background(
                        Color.accentColor.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(profile.displayName)
                            .font(.body.weight(.semibold))
                        Circle()
                            .fill(status.color)
                            .frame(width: 7, height: 7)
                    }
                    Text(profile.host)
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

            if let snapshot {
                HStack(spacing: 14) {
                    Label("\(snapshot.projects.count)", systemImage: "folder")
                    Label(
                        "\(snapshot.sessions.count)",
                        systemImage: "bubble.left.and.bubble.right"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityValue(status.label)
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
                        systemImage: "bubble.left.and.bubble.right"
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
