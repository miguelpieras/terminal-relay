import AppKit
import Sparkle
import SwiftUI
import UserNotifications

enum ApplicationSettings {
    enum StorageKey {
        static let keepRunningAfterLastWindowClosed =
            "applicationSettings.keepRunningAfterLastWindowClosed"
        static let showTaskCompletionNotifications =
            "applicationSettings.showTaskCompletionNotifications"
    }

    static let defaultKeepRunningAfterLastWindowClosed = true
    static let defaultShowTaskCompletionNotifications = false

    static func keepRunningAfterLastWindowClosed(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: StorageKey.keepRunningAfterLastWindowClosed) != nil else {
            return defaultKeepRunningAfterLastWindowClosed
        }
        return defaults.bool(forKey: StorageKey.keepRunningAfterLastWindowClosed)
    }

    static func showTaskCompletionNotifications(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: StorageKey.showTaskCompletionNotifications) != nil else {
            return defaultShowTaskCompletionNotifications
        }
        return defaults.bool(forKey: StorageKey.showTaskCompletionNotifications)
    }
}

@MainActor
final class TerminalRelayApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    weak var sessionManager: SessionManager?
    private(set) var registrationError: String?

    private var serverStore: ServerStore?
    private var projectStore: ProjectStore?
    private var pendingRegistrationURLs: [URL] = []
    private var registrationErrorHandler: ((String?) -> Void)?
    private let registrationAuthorization: (WorkerRegistration) throws -> Void
    private let defaults: UserDefaults
    private let terminatesAfterLastWindowForTestHost: Bool

    override init() {
        let authorizer = WorkerRegistrationTokenAuthorizer()
        registrationAuthorization = authorizer.authorize
        defaults = .standard
        terminatesAfterLastWindowForTestHost =
            !ApplicationUpdateConfiguration.shouldStartUpdater()
        super.init()
    }

    init(
        registrationAuthorization: @escaping (WorkerRegistration) throws -> Void,
        defaults: UserDefaults = .standard
    ) {
        self.registrationAuthorization = registrationAuthorization
        self.defaults = defaults
        terminatesAfterLastWindowForTestHost = false
        super.init()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if terminatesAfterLastWindowForTestHost {
            return true
        }
        return !ApplicationSettings.keepRunningAfterLastWindowClosed(in: defaults)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        if ApplicationSettings.showTaskCompletionNotifications(in: defaults) {
            TaskCompletionNotificationService.requestAuthorization()
        }
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

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
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
    private let updaterController: SPUStandardUpdaterController
    @StateObject private var serverStore: ServerStore
    @StateObject private var projectStore: ProjectStore
    @StateObject private var sessionManager: SessionManager
    @StateObject private var workerSessionService = WorkerSessionService()
    @StateObject private var githubService = GitHubProjectService()
    @StateObject private var accountUsageService: AccountUsageService
    @StateObject private var workerMetricsService = WorkerMetricsService()
    @StateObject private var projectGitService = ProjectGitService()
    @State private var workerRegistrationAlert: WorkerRegistrationAlert?

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: ApplicationUpdateConfiguration.shouldStartUpdater()
                && !ScreenshotDemoMode.isEnabled,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        let serverStore: ServerStore
        let projectStore: ProjectStore
        let sessionManager: SessionManager
        let accountUsageService: AccountUsageService
#if DEBUG
        if !ApplicationUpdateConfiguration.shouldStartUpdater() {
            let suiteName = "com.mpieras.TerminalRelay.xctest-host"
            let defaults = UserDefaults(suiteName: suiteName) ?? .standard
            defaults.removePersistentDomain(forName: suiteName)
            serverStore = ServerStore(defaults: defaults)
            projectStore = ProjectStore(
                defaults: defaults,
                servers: serverStore.servers
            )
            sessionManager = SessionManager(defaults: defaults)
            accountUsageService = AccountUsageService()
        } else if ScreenshotDemoMode.isEnabled {
            let fixture = ScreenshotDemoMode.fixture()
            let defaults = ScreenshotDemoMode.isolatedDefaults()
            serverStore = ServerStore(
                defaults: defaults,
                initialServers: [fixture.worker]
            )
            projectStore = ProjectStore(
                defaults: defaults,
                servers: serverStore.servers,
                initialProjects: fixture.projects
            )
            sessionManager = SessionManager(defaults: defaults)
            sessionManager.loadScreenshotDemo(fixture.sessions, on: fixture.worker)
            accountUsageService = AccountUsageService(
                screenshotDemoWorkerID: fixture.worker.id
            )
        } else {
            serverStore = ServerStore()
            projectStore = ProjectStore(servers: serverStore.servers)
            sessionManager = SessionManager()
            accountUsageService = AccountUsageService()
        }
#else
        serverStore = ServerStore()
        projectStore = ProjectStore(servers: serverStore.servers)
        sessionManager = SessionManager()
        accountUsageService = AccountUsageService()
#endif

        _serverStore = StateObject(wrappedValue: serverStore)
        _projectStore = StateObject(wrappedValue: projectStore)
        _sessionManager = StateObject(wrappedValue: sessionManager)
        _accountUsageService = StateObject(wrappedValue: accountUsageService)
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
                .environment(\.applicationUpdater, updaterController.updater)
                .preferredColorScheme(.dark)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear {
#if DEBUG
                    if ScreenshotDemoMode.isEnabled {
                        DispatchQueue.main.async {
                            guard let window = NSApplication.shared.windows.first(where: \.isVisible)
                            else { return }
                            window.setContentSize(NSSize(width: 1_260, height: 820))
                            window.center()
                        }
                    }
#endif
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
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }
    }
}
