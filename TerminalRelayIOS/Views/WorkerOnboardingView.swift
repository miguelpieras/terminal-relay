import SwiftUI
import UIKit

struct WorkerOnboardingView: View {
    @ObservedObject var model: WorkerSessionModel
    let allowsCancel: Bool
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var fingerprint: String
    @State private var validationMessage: String?

    init(model: WorkerSessionModel, allowsCancel: Bool, onSaved: @escaping () -> Void) {
        self.model = model
        self.allowsCancel = allowsCancel
        self.onSaved = onSaved
        _host = State(initialValue: model.profile?.host ?? "")
        _port = State(initialValue: model.profile.map { String($0.port) } ?? "22")
        _username = State(initialValue: model.profile?.username ?? "")
        _fingerprint = State(initialValue: model.profile?.expectedHostKeyFingerprint ?? "")
    }

    var body: some View {
        Form {
            Section {
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

            if allowsCancel {
                Section {
                    Button("Forget worker", role: .destructive) {
                        model.clearProfile()
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("Worker setup")
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
            try model.saveProfile(host: host, portText: port, username: username, fingerprint: fingerprint)
            validationMessage = nil
            onSaved()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}
