import AppKit
import SwiftUI

@MainActor
final class TerminalRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var sessionManager: SessionManager?

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager?.stopAll()
    }
}

@main
@MainActor
struct TerminalRelayApp: App {
    @NSApplicationDelegateAdaptor(TerminalRelayApplicationDelegate.self) private var appDelegate
    @StateObject private var serverStore: ServerStore
    @StateObject private var projectStore: ProjectStore
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var githubService = GitHubProjectService()
    @StateObject private var accountUsageService = AccountUsageService()
    @StateObject private var workerMetricsService = WorkerMetricsService()
    @StateObject private var projectGitService = ProjectGitService()

    init() {
        let serverStore = ServerStore()
        _serverStore = StateObject(wrappedValue: serverStore)
        _projectStore = StateObject(
            wrappedValue: ProjectStore(servers: serverStore.servers)
        )
    }

    var body: some Scene {
        Window("Terminal Relay", id: "main") {
            ContentView()
                .environmentObject(serverStore)
                .environmentObject(projectStore)
                .environmentObject(sessionManager)
                .environmentObject(githubService)
                .environmentObject(accountUsageService)
                .environmentObject(workerMetricsService)
                .environmentObject(projectGitService)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                }
        }
        .defaultSize(width: 1_260, height: 820)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
