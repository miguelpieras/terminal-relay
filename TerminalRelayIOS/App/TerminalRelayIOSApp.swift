import SwiftUI

@main
struct TerminalRelayIOSApp: App {
    @StateObject private var model = WorkerSessionModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
