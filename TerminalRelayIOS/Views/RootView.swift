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
    @State private var workerPendingDeletion: WorkerProfile?

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ProjectListView(model: model) {
                    editorRoute = WorkerEditorRoute(
                        profile: nil,
                        showsProjectsAfterSave: true
                    )
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
        .fullScreenCover(item: $model.terminalRoute, onDismiss: {
            Task { await model.refresh() }
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
            Text("This removes the worker connection from this iPhone. It does not change or stop the remote worker.")
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
    }

    @ViewBuilder
    private var workerList: some View {
        Group {
            if model.profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Workers", systemImage: "server.rack")
                } description: {
                    Text("Add a worker to load its projects and shared agent sessions.")
                } actions: {
                    Button("Add Worker") {
                        editorRoute = WorkerEditorRoute(
                            profile: nil,
                            showsProjectsAfterSave: true
                        )
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(model.profiles) { profile in
                            Button {
                                model.selectProfile(id: profile.id)
                                selectedTab = .projects
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(profile.displayName)
                                            .foregroundStyle(.primary)
                                        Text("\(profile.username)@\(profile.host):\(profile.port)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if model.profile?.id == profile.id {
                                        Image(systemName: "checkmark")
                                            .fontWeight(.semibold)
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
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
                        }
                    } footer: {
                        Text("The selected worker supplies the Projects tab. Tap another worker to switch.")
                    }
                }
            }
        }
        .navigationTitle("Workers")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorRoute = WorkerEditorRoute(
                        profile: nil,
                        showsProjectsAfterSave: true
                    )
                } label: {
                    Label("Add Worker", systemImage: "plus")
                }
            }
        }
    }
}
