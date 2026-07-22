import SwiftUI

struct RootView: View {
    @ObservedObject var model: WorkerSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsSettings = false

    var body: some View {
        Group {
            if model.profile == nil {
                NavigationStack {
                    WorkerOnboardingView(model: model, allowsCancel: false) {
                        Task { await model.refresh() }
                    }
                }
            } else {
                ProjectListView(model: model, showsSettings: $showsSettings)
            }
        }
        .sheet(isPresented: $showsSettings) {
            NavigationStack {
                WorkerOnboardingView(model: model, allowsCancel: true) {
                    showsSettings = false
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
        .task {
            if model.profile != nil {
                await model.refresh()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, model.profile != nil, model.terminalRoute == nil {
                Task { await model.refresh() }
            }
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
}
