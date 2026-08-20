import SwiftUI

struct ProviderAccountPickerView: View {
    let workerName: String
    let provider: AgentKind
    let accounts: [ProviderAccountProfile]
    let onSelect: (ProviderAccountProfile) -> Void
    let onSignIn: (ProviderAccountProfile) -> Void
    let onAddAccount: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AgentBrandIcon(kind: provider, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Choose a \(provider.displayName) account")
                        .font(.title3.weight(.semibold))
                    Text(workerName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("This choice is permanent for the task. Models and reasoning settings can change later without changing its account.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()

            if accounts.isEmpty {
                ContentUnavailableView {
                    Label("No usable accounts", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Add or sign in to a \(provider.displayName) profile on this worker.")
                }
                .frame(maxWidth: .infinity, minHeight: 170)
            } else {
                VStack(spacing: 8) {
                    ForEach(accounts) { account in
                        Button {
                            if account.status.isUsable {
                                onSelect(account)
                            } else {
                                onSignIn(account)
                            }
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "person.crop.circle")
                                    .font(.system(size: 17))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(account.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(accountDetail(account))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: account.status.isUsable ? "arrow.right" : "person.crop.circle.badge.plus")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14)
                            .frame(minHeight: 58)
                            .background(
                                Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(account.status == .disabled)
                    }
                }
            }

            Divider()

            HStack {
                Button("Add account") {
                    dismiss()
                    onAddAccount()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 500)
    }

    private func accountDetail(_ account: ProviderAccountProfile) -> String {
        switch account.status {
        case .active:
            account.storageKind == .legacyDefault
                ? "Existing worker account"
                : "Isolated profile"
        case .authRequired:
            "Sign in required"
        case .disabled:
            "Unavailable"
        }
    }
}

struct ProviderAccountBadge: View {
    let provider: AgentKind
    let accountLabel: String

    var body: some View {
        Label {
            Text("\(provider.displayName) · \(accountLabel)")
        } icon: {
            Image(systemName: "person.crop.circle")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct ProviderAccountCreateView: View {
    @EnvironmentObject private var providerAccountService: ProviderAccountService
    @Environment(\.dismiss) private var dismiss

    let worker: ServerProfile
    let provider: AgentKind
    let onCreated: (ProviderAccountProfile) -> Void

    @State private var label = ""
    @State private var isCreating = false
    @State private var didLoadAccounts = false
    @State private var isConfirmingLegacyAssignment = false
    @State private var errorMessage: String?

    private var normalizedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var legacyAccount: ProviderAccountProfile? {
        providerAccountService.accounts(
            workerID: worker.id,
            provider: provider
        ).first { $0.storageKind == .legacyDefault }
    }

    private var needsLegacyAssignmentConfirmation: Bool {
        let accounts = providerAccountService.accounts(
            workerID: worker.id,
            provider: provider
        )
        return accounts.count == 1 && legacyAccount != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AgentBrandIcon(kind: provider, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add \(provider.displayName) account")
                        .font(.title3.weight(.semibold))
                    Text(worker.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Terminal Relay creates a new private provider profile on the worker. You will sign in to it next.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Profile name, for example Personal", text: $label)
                .textFieldStyle(.roundedBorder)
                .onSubmit(requestCreate)
                .disabled(isCreating)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(isCreating)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(
                    isCreating ? "Creating…" : "Create and sign in",
                    action: requestCreate
                )
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating || !didLoadAccounts || normalizedLabel.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .interactiveDismissDisabled(isCreating)
        .task {
            let loaded = await providerAccountService.refresh(
                worker: worker,
                provider: provider
            )
            didLoadAccounts = loaded != nil
            if loaded == nil {
                errorMessage = "The worker account list could not be loaded."
            }
        }
        .alert(
            "Keep existing history with \(legacyAccount?.displayName ?? "the current account")?",
            isPresented: $isConfirmingLegacyAssignment
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Keep history and continue") { create() }
        } message: {
            Text(
                "All existing \(provider.displayName) tasks on this worker will remain permanently bound to \(legacyAccount?.displayName ?? "the current account"). The new profile will be separate."
            )
        }
    }

    private func requestCreate() {
        guard didLoadAccounts, !isCreating, !normalizedLabel.isEmpty else { return }
        if needsLegacyAssignmentConfirmation {
            isConfirmingLegacyAssignment = true
        } else {
            create()
        }
    }

    private func create() {
        guard !isCreating, !normalizedLabel.isEmpty else { return }
        isCreating = true
        errorMessage = nil
        let requestedLabel = normalizedLabel
        Task {
            do {
                let account = try await providerAccountService.create(
                    worker: worker,
                    provider: provider,
                    label: requestedLabel
                )
                onCreated(account)
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "The account profile could not be created."
                isCreating = false
            }
        }
    }
}

struct ProviderAccountManagementView: View {
    @EnvironmentObject private var providerAccountService: ProviderAccountService
    @EnvironmentObject private var accountAuthenticationService: AccountAuthenticationService
    @EnvironmentObject private var accountUsageService: AccountUsageService
    @Environment(\.dismiss) private var dismiss

    let worker: ServerProfile
    let provider: AgentKind

    @State private var isAddingAccount = false
    @State private var accountToRename: ProviderAccountProfile?
    @State private var isRefreshing = false

    private var accounts: [ProviderAccountProfile] {
        providerAccountService.accounts(workerID: worker.id, provider: provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                AgentBrandIcon(kind: provider, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manage \(provider.displayName) accounts")
                        .font(.title3.weight(.semibold))
                    Text(worker.displayName)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await refreshAccounts() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(isRefreshing)
                .help("Refresh account status and usage")
            }

            Divider()

            if accounts.isEmpty {
                ProgressView("Reading worker profiles…")
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                VStack(spacing: 8) {
                    ForEach(accounts) { account in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.displayName)
                                    .font(.body.weight(.medium))
                                Text(statusText(account))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                accountToRename = account
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Rename \(account.displayName)")

                            if account.status == .authRequired {
                                Button("Sign In") {
                                    dismiss()
                                    DispatchQueue.main.async {
                                        accountAuthenticationService.begin(
                                            worker: worker,
                                            account: account
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                            } else if account.status == .active {
                                Label("Ready", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.green)
                            } else {
                                Text("Unavailable")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(minHeight: 58)
                        .background(
                            Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                    }
                }
            }

            Divider()

            HStack {
                Button("Add account") { isAddingAccount = true }
                    .buttonStyle(.borderedProminent)
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 520)
        .task {
            await refreshAccounts()
        }
        .sheet(isPresented: $isAddingAccount) {
            ProviderAccountCreateView(worker: worker, provider: provider) { account in
                isAddingAccount = false
                dismiss()
                DispatchQueue.main.async {
                    accountAuthenticationService.begin(worker: worker, account: account)
                }
            }
        }
        .sheet(item: $accountToRename) { account in
            ProviderAccountRenameView(worker: worker, account: account)
        }
    }

    private func statusText(_ account: ProviderAccountProfile) -> String {
        let storage = account.storageKind == .legacyDefault
            ? "Existing worker account"
            : "Isolated profile"
        switch account.status {
        case .active: return storage
        case .authRequired: return "\(storage) · Sign in required"
        case .disabled: return "\(storage) · Disabled"
        }
    }

    private func refreshAccounts() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let loaded = await providerAccountService.refresh(
            worker: worker,
            provider: provider
        ) ?? accounts
        var refreshed: [ProviderAccountProfile] = []
        for account in loaded {
            guard account.status != .disabled else {
                refreshed.append(account)
                continue
            }
            refreshed.append(
                (try? await providerAccountService.refreshStatus(
                    worker: worker,
                    account: account
                )) ?? account
            )
        }
        await accountUsageService.refresh(worker: worker, accounts: refreshed)
        isRefreshing = false
    }
}

private struct ProviderAccountRenameView: View {
    @EnvironmentObject private var providerAccountService: ProviderAccountService
    @Environment(\.dismiss) private var dismiss

    let worker: ServerProfile
    let account: ProviderAccountProfile

    @State private var label: String
    @State private var isRenaming = false
    @State private var errorMessage: String?

    init(worker: ServerProfile, account: ProviderAccountProfile) {
        self.worker = worker
        self.account = account
        _label = State(initialValue: account.displayName)
    }

    private var normalizedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename account")
                .font(.title3.weight(.semibold))

            Text("The task route stays bound to the same account ID.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField("Profile name", text: $label)
                .textFieldStyle(.roundedBorder)
                .onSubmit(rename)
                .disabled(isRenaming)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(isRenaming)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isRenaming ? "Renaming…" : "Rename", action: rename)
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isRenaming
                            || normalizedLabel.isEmpty
                            || normalizedLabel == account.displayName
                    )
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .interactiveDismissDisabled(isRenaming)
    }

    private func rename() {
        guard !isRenaming,
              !normalizedLabel.isEmpty,
              normalizedLabel != account.displayName else {
            return
        }
        isRenaming = true
        errorMessage = nil
        let requestedLabel = normalizedLabel
        Task {
            do {
                _ = try await providerAccountService.rename(
                    worker: worker,
                    account: account,
                    label: requestedLabel
                )
                dismiss()
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "The account could not be renamed."
                isRenaming = false
            }
        }
    }
}
