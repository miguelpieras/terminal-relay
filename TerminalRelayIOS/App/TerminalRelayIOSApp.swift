import SwiftUI

@main
struct TerminalRelayIOSApp: App {
    @StateObject private var model: WorkerSessionModel

    init() {
        let model = WorkerSessionModel(screenshotDemo: ScreenshotDemoMode.isEnabled)
        if ScreenshotDemoMode.opensTerminal,
           let session = DemoWorkspace.sessions.first {
            model.openTerminal(session)
        }
        _model = StateObject(
            wrappedValue: model
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
