import AppKit
import SwiftUI

struct AccountAuthenticationView: View {
    @EnvironmentObject private var accountAuthenticationService: AccountAuthenticationService
    @EnvironmentObject private var accountUsageService: AccountUsageService

    let presentation: AccountAuthenticationPresentation

    @State private var claudeAuthorizationCode = ""
    @State private var isVerifyingAccount = false
    @State private var didVerifyAccount = false
    @State private var verifiedAccount: String?
    @State private var verificationMessage: String?

    private var productName: String {
        presentation.kind == .claude ? "Claude Code" : "Codex"
    }

    private var providerName: String {
        presentation.kind == .claude ? "Claude" : "OpenAI"
    }

    private var canSubmitClaudeCode: Bool {
        let code = claudeAuthorizationCode
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !code.isEmpty && code.count <= 4_096
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AgentBrandIcon(kind: presentation.kind, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(accountAction) \(productName)")
                        .font(.title3.weight(.semibold))
                    Text(presentation.worker.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let currentAccount = presentation.currentAccount {
                Label("Currently connected as \(currentAccount)", systemImage: "person.crop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    "Terminal Relay could not read a connected account.",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Divider()

            phaseContent
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)

            Divider()

            HStack {
                Text("Credentials remain on this worker.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                footerActions
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(accountAuthenticationService.isRunning)
        .onAppear {
            if accountAuthenticationService.phase == .succeeded {
                verifyAccount()
            }
        }
        .onChange(of: accountAuthenticationService.phase) { _, phase in
            switch phase {
            case .succeeded:
                claudeAuthorizationCode = ""
                verifyAccount()
            case .failed:
                claudeAuthorizationCode = ""
            default:
                break
            }
        }
        .onDisappear {
            guard accountAuthenticationService.presentation?.id == presentation.id else {
                return
            }
            accountAuthenticationService.dismiss()
        }
    }

    private var accountAction: String {
        presentation.currentAccount == nil ? "Sign in to" : "Change account for"
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch accountAuthenticationService.phase {
        case .idle, .connecting:
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("Connecting securely to the worker…")
                    .foregroundStyle(.secondary)
            }
        case .awaitingAuthorization:
            authorizationContent(isFinishing: false)
        case .finishing:
            authorizationContent(isFinishing: true)
        case .succeeded:
            successContent
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label("Sign-in did not complete", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                Text("Try again to create a fresh browser authorization.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func authorizationContent(isFinishing: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the account you want to use on this worker in the browser.")
                .font(.callout)

            HStack(spacing: 8) {
                Button("Open \(providerName) Sign-in", action: accountAuthenticationService.openAuthorizationPage)
                    .buttonStyle(.borderedProminent)

                Button("Copy Link", action: copyAuthorizationLink)
                    .buttonStyle(.bordered)
            }

            if presentation.kind == .codex {
                if let deviceCode = accountAuthenticationService.deviceCode {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Enter this one-time code:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Text(deviceCode)
                                .font(.system(.title2, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                            Button("Copy Code") {
                                copy(deviceCode)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Reading the one-time code…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                waitingLabel("Waiting for OpenAI to confirm sign-in…")
            } else {
                Text("After authorizing in the browser, paste the code shown there below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    TextField("Paste authorization code", text: $claudeAuthorizationCode)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(submitClaudeCode)
                        .disabled(isFinishing)

                    Button(isFinishing ? "Finishing…" : "Continue", action: submitClaudeCode)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canSubmitClaudeCode || isFinishing)
                }

                if isFinishing {
                    waitingLabel("Waiting for Claude to confirm sign-in…")
                }
            }
        }
    }

    @ViewBuilder
    private var successContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Account connected", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            if isVerifyingAccount {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Refreshing account details…")
                        .foregroundStyle(.secondary)
                }
            } else if let verifiedAccount {
                Text("\(productName) is ready as \(verifiedAccount).")
                    .foregroundStyle(.secondary)
            } else if let verificationMessage {
                Text(verificationMessage)
                    .foregroundStyle(.secondary)
            } else {
                Text("\(productName) is ready on this worker.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func waitingLabel(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.mini)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var footerActions: some View {
        switch accountAuthenticationService.phase {
        case .succeeded:
            Button("Done") {
                accountAuthenticationService.dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isVerifyingAccount)
        case .failed:
            Button("Cancel") {
                accountAuthenticationService.dismiss()
            }
            Button("Try Again") {
                resetVerification()
                accountAuthenticationService.retry()
            }
            .buttonStyle(.borderedProminent)
        case .idle, .connecting, .awaitingAuthorization, .finishing:
            Button("Cancel") {
                accountAuthenticationService.dismiss()
            }
        }
    }

    private func submitClaudeCode() {
        guard canSubmitClaudeCode else { return }
        accountAuthenticationService.submitClaudeAuthorizationCode(
            claudeAuthorizationCode
        )
        claudeAuthorizationCode = ""
    }

    private func copyAuthorizationLink() {
        guard let url = accountAuthenticationService.authorizationURL else { return }
        copy(url.absoluteString)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func verifyAccount() {
        guard !didVerifyAccount else { return }
        didVerifyAccount = true
        isVerifyingAccount = true

        Task {
            await accountUsageService.refresh(
                worker: presentation.worker,
                force: true
            )
            let snapshot = accountUsageService.snapshot(
                for: presentation.worker.id,
                kind: presentation.kind
            )
            verifiedAccount = snapshot?.account
            if snapshot == nil {
                verificationMessage = "Sign-in completed, but account usage is still unavailable."
            }
            isVerifyingAccount = false
        }
    }

    private func resetVerification() {
        isVerifyingAccount = false
        didVerifyAccount = false
        verifiedAccount = nil
        verificationMessage = nil
    }
}
