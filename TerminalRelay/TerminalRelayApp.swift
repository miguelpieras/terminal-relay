import AppKit
import SwiftUI

@MainActor
final class TerminalRelayApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var sessionManager: SessionManager?
    private(set) var registrationError: String?

    private var serverStore: ServerStore?
    private var projectStore: ProjectStore?
    private var pendingRegistrationURLs: [URL] = []
    private var registrationErrorHandler: ((String?) -> Void)?
    private let registrationAuthorization: (WorkerRegistration) throws -> Void

    override init() {
        let authorizer = WorkerRegistrationTokenAuthorizer()
        registrationAuthorization = authorizer.authorize
        super.init()
    }

    init(registrationAuthorization: @escaping (WorkerRegistration) throws -> Void) {
        self.registrationAuthorization = registrationAuthorization
        super.init()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if serverStore == nil || projectStore == nil {
            pendingRegistrationURLs.append(contentsOf: urls)
            return
        }

        urls.forEach(processRegistrationURL)
    }

    func attach(
        serverStore: ServerStore,
        projectStore: ProjectStore,
        registrationErrorHandler: @escaping (String?) -> Void
    ) {
        self.serverStore = serverStore
        self.projectStore = projectStore
        self.registrationErrorHandler = registrationErrorHandler

        if let registrationError {
            registrationErrorHandler(registrationError)
        }

        let queuedURLs = pendingRegistrationURLs
        pendingRegistrationURLs.removeAll()
        queuedURLs.forEach(processRegistrationURL)
    }

    func dismissRegistrationError() {
        registrationError = nil
        registrationErrorHandler?(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionManager?.disconnectAll()
    }

    private func processRegistrationURL(_ url: URL) {
        guard let serverStore, let projectStore else {
            pendingRegistrationURLs.append(url)
            return
        }

        do {
            let registration = try WorkerRegistrationURL.registration(from: url)
            try registrationAuthorization(registration)
            serverStore.register(registration.profile)
            projectStore.updateServers(serverStore.servers)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? "The worker registration link could not be imported."
            registrationError = message
            registrationErrorHandler?(message)
        }
    }
}

private struct WorkerRegistrationAlert: Identifiable {
    let id = UUID()
    let message: String
}

@main
@MainActor
struct TerminalRelayApp: App {
    @NSApplicationDelegateAdaptor(TerminalRelayApplicationDelegate.self) private var appDelegate
    @StateObject private var serverStore: ServerStore
    @StateObject private var projectStore: ProjectStore
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var workerSessionService = WorkerSessionService()
    @StateObject private var githubService = GitHubProjectService()
    @StateObject private var accountUsageService = AccountUsageService()
    @StateObject private var workerMetricsService = WorkerMetricsService()
    @StateObject private var projectGitService = ProjectGitService()
    @State private var workerRegistrationAlert: WorkerRegistrationAlert?

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
                .environmentObject(workerSessionService)
                .environmentObject(githubService)
                .environmentObject(accountUsageService)
                .environmentObject(workerMetricsService)
                .environmentObject(projectGitService)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
                    appDelegate.sessionManager = sessionManager
                    appDelegate.attach(
                        serverStore: serverStore,
                        projectStore: projectStore
                    ) { message in
                        workerRegistrationAlert = message.map(WorkerRegistrationAlert.init(message:))
                    }
                }
                .alert(item: $workerRegistrationAlert) { alert in
                    Alert(
                        title: Text("Worker registration failed"),
                        message: Text(alert.message),
                        dismissButton: .default(Text("OK")) {
                            appDelegate.dismissRegistrationError()
                        }
                    )
                }
        }
        .defaultSize(width: 1_260, height: 820)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
