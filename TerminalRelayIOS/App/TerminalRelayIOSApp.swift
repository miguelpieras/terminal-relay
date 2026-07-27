import SwiftUI

@main
struct TerminalRelayIOSApp: App {
    @StateObject private var model: WorkerSessionModel

    init() {
        _model = StateObject(
            wrappedValue: WorkerSessionModel(screenshotDemo: ScreenshotDemoMode.isEnabled)
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
        }
    }
}
