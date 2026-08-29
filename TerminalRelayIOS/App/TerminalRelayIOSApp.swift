import SwiftUI

@main
struct TerminalRelayIOSApp: App {
    @StateObject private var model: WorkerSessionModel

    init() {
#if DEBUG
        let model = WorkerSessionModel(screenshotDemo: ScreenshotDemoMode.isEnabled)
        if ScreenshotDemoMode.opensTerminal,
           let session = DemoWorkspace.sessions.first {
            model.openTerminal(session)
        }
#else
        let model = WorkerSessionModel()
#endif
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
