import SwiftUI
import UIKit

struct WorkerOnboardingView: View {
    @ObservedObject var model: WorkerSessionModel
    let profile: WorkerProfile?
    let allowsCancel: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var fingerprint: String
    @State private var validationMessage: String?

    init(
        model: WorkerSessionModel,
        profile: WorkerProfile? = nil,
        allowsCancel: Bool,
        onSaved: @escaping () -> Void
    ) {
        self.model = model
        self.profile = profile
        self.allowsCancel = allowsCancel
        self.onSaved = onSaved
        _name = State(initialValue: profile?.name ?? "")
        _host = State(initialValue: profile?.host ?? "")
        _port = State(initialValue: profile.map { String($0.port) } ?? "22")
        _username = State(initialValue: profile?.username ?? "")
        _fingerprint = State(initialValue: profile?.expectedHostKeyFingerprint ?? "")
    }

    var body: some View {
        Form {
            Section {
                TextField("Worker name", text: $name)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                TextField("worker.tailnet.ts.net", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                TextField("22", text: $port)
                    .keyboardType(.numberPad)
                TextField("Username", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("SHA256:…", text: $fingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("Worker over Tailscale")
            } footer: {
                Text("Pin the worker's SSH host key fingerprint. The app rejects every host key that does not match it.")
            }

            Section("Dedicated public key") {
                Text(model.publicKey.isEmpty ? "Key unavailable" : model.publicKey)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)

                Text("Authorize this device key on every worker you add.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    UIPasteboard.general.string = model.publicKey
                } label: {
                    Label("Copy for authorized_keys", systemImage: "doc.on.doc")
                }
                .disabled(model.publicKey.isEmpty)
            }

            if let validationMessage {
                Section {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Save and connect") {
                    save()
                }
                .frame(maxWidth: .infinity)
            }

            if allowsCancel, let profile {
                Section {
                    Button("Remove worker", role: .destructive) {
                        model.deleteProfile(id: profile.id)
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle(profile == nil ? "Add Worker" : "Worker setup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if allowsCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func save() {
        do {
            try model.saveProfile(
                id: profile?.id,
                name: name,
                host: host,
                portText: port,
                username: username,
                fingerprint: fingerprint
            )
            validationMessage = nil
            onSaved()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
