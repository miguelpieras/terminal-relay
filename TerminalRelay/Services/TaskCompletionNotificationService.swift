import Foundation
import OSLog
import UserNotifications

private let taskCompletionNotificationLogger = Logger(
    subsystem: "com.mpieras.TerminalRelay",
    category: "completion-notification"
)

enum TaskCompletionNotificationService {
    static func requestAuthorization() {
        Task {
            _ = await isAuthorized()
        }
    }

    @MainActor
    static func notifyTaskCompletion(for session: TerminalSession) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.kind.displayName) task finished"
        content.subtitle = session.projectName
        content.body = session.displayTitle
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        Task {
            guard await isAuthorized() else { return }
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                taskCompletionNotificationLogger.error(
                    "Could not deliver a task completion notification."
                )
            }
        }
    }

    private static func isAuthorized() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            do {
                return try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                taskCompletionNotificationLogger.error(
                    "Could not request task completion notification authorization."
                )
                return false
            }
        default:
            return false
        }
    }
}
