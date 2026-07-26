import Combine
import Sparkle
import SwiftUI

enum ApplicationUpdateConfiguration {
    static let commandTitle = "Check for Updates…"
    static let feedURL = "https://miguelpieras.github.io/terminal-relay/appcast.xml"
    static let publicEDKey = "v0p1N1q4J2BUKlqOx8GpDSwJTJYWZrFvkAyMXdLSesQ="
    static let scheduledCheckInterval = 86_400

    static func shouldStartUpdater(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] == nil
    }

    static func isValid(infoDictionary: [String: Any]) -> Bool {
        infoDictionary["SUFeedURL"] as? String == feedURL
            && infoDictionary["SUPublicEDKey"] as? String == publicEDKey
            && infoDictionary["SUEnableAutomaticChecks"] as? Bool == true
            && infoDictionary["SUAutomaticallyUpdate"] as? Bool == false
            && infoDictionary["SUAllowsAutomaticUpdates"] as? Bool == true
            && infoDictionary["SUEnableSystemProfiling"] as? Bool == false
            && infoDictionary["SURequireSignedFeed"] as? Bool == true
            && infoDictionary["SUVerifyUpdateBeforeExtraction"] as? Bool == true
            && infoDictionary["SUSignedFeedFailureExpirationInterval"] as? Int == 0
            && infoDictionary["SUScheduledCheckInterval"] as? Int
                == scheduledCheckInterval
    }
}

private struct ApplicationUpdaterEnvironmentKey: EnvironmentKey {
    static let defaultValue: SPUUpdater? = nil
}

extension EnvironmentValues {
    var applicationUpdater: SPUUpdater? {
        get { self[ApplicationUpdaterEnvironmentKey.self] }
        set { self[ApplicationUpdaterEnvironmentKey.self] = newValue }
    }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    private var observation: AnyCancellable?

    init(updater: SPUUpdater) {
        observation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button(ApplicationUpdateConfiguration.commandTitle) {
            updater.checkForUpdates()
        }
        .disabled(!viewModel.canCheckForUpdates)
    }
}

struct ApplicationUpdateSettingsView: View {
    let updater: SPUUpdater
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecksForUpdates = State(
            initialValue: updater.automaticallyChecksForUpdates
        )
        _automaticallyDownloadsUpdates = State(
            initialValue: updater.automaticallyDownloadsUpdates
        )
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 7) {
                Toggle(
                    "Automatically check for updates",
                    isOn: $automaticallyChecksForUpdates
                )
                Text("Checks GitHub once per day while Terminal Relay is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                    .padding(.vertical, 4)

                Toggle(
                    "Automatically download and install updates",
                    isOn: $automaticallyDownloadsUpdates
                )
                .disabled(!automaticallyChecksForUpdates || !updater.allowsAutomaticUpdates)
                Text("Installs signed updates after download, normally when the app quits.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        } label: {
            Label("Updates", systemImage: "arrow.triangle.2.circlepath")
        }
        .onChange(of: automaticallyChecksForUpdates) { _, newValue in
            updater.automaticallyChecksForUpdates = newValue
            if !newValue {
                automaticallyDownloadsUpdates = false
            }
        }
        .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
            updater.automaticallyDownloadsUpdates = newValue
        }
    }
}
