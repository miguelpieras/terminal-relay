import AppKit
import SwiftUI

@MainActor
final class AgentConsoleApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var sessionManager: SessionManager?

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager?.stopAll()
    }
}

@main
struct AgentConsoleApp: App {
    @NSApplicationDelegateAdaptor(AgentConsoleApplicationDelegate.self) private var appDelegate
    @StateObject private var serverStore = ServerStore()
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        Window("Agent Console", id: "main") {
            ContentView()
                .environmentObject(serverStore)
                .environmentObject(sessionManager)
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
