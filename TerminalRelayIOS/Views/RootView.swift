import SwiftUI

private struct WorkerEditorRoute: Identifiable {
    let id = UUID()
    let profile: WorkerProfile?
}

struct RootView: View {
    @ObservedObject var model: WorkerSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedWorkerID: UUID?
    @State private var editorRoute: WorkerEditorRoute?
    @State private var workerPendingDeletion: WorkerProfile?

    var body: some View {
        Group {
            if model.profiles.isEmpty {
                NavigationStack {
                    WorkerOnboardingView(model: model, allowsCancel: false) {
                        Task { await model.refresh() }
                    }
                }
            } else {
                NavigationStack {
                    workerList
                        .navigationDestination(item: $selectedWorkerID) { _ in
                            ProjectListView(model: model) {
                                editorRoute = WorkerEditorRoute(profile: model.profile)
                            }
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
               selectedWorkerID != nil,
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

    private var workerList: some View {
        List {
            Section("Workers") {
                ForEach(model.profiles) { profile in
                    Button {
                        model.selectProfile(id: profile.id)
                        selectedWorkerID = profile.id
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "server.rack")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.displayName)
                                    .foregroundStyle(.primary)
                                Text("\(profile.username)@\(profile.host):\(profile.port)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button("Remove", role: .destructive) {
                            workerPendingDeletion = profile
                        }
                        Button("Edit") {
                            editorRoute = WorkerEditorRoute(profile: profile)
                        }
                        .tint(.blue)
                    }
                }
            }
        }
        .navigationTitle("Terminal Relay")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editorRoute = WorkerEditorRoute(profile: nil)
                } label: {
                    Label("Add Worker", systemImage: "plus")
                }
            }
        }
    }
}
