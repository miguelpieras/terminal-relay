import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct MobilePairingView: View {
    @Environment(\.dismiss) private var dismiss

    let worker: ServerProfile

    @State private var invitation: MobilePairingInvitation?
    @State private var isPreparing = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pair iPhone or iPad")
                        .font(.title2.weight(.semibold))
                    Text(worker.displayName)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            Group {
                if isPreparing {
                    ProgressView("Creating a private pairing code…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let invitation,
                          let image = MobilePairingQRCode.image(for: invitation.code) {
                    pairingContent(invitation: invitation, image: image)
                } else {
                    ContentUnavailableView {
                        Label("Pairing Unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage ?? "The pairing code could not be created.")
                    } actions: {
                        Button("Try Again") {
                            Task { await prepareInvitation() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 660)
        .task {
            await prepareInvitation()
        }
        .onDisappear {
            guard !ScreenshotDemoMode.isEnabled else { return }
            guard let invitation else { return }
            Task {
                try? await MobilePairingService.revoke(
                    token: invitation.id,
                    on: invitation.worker
                )
            }
        }
    }

    private func pairingContent(
        invitation: MobilePairingInvitation,
        image: NSImage
    ) -> some View {
        VStack(spacing: 18) {
            Text("On your iPhone or iPad, open Terminal Relay and tap “Scan Mac Pairing Code.”")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 410)

            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: 300, height: 300)
                .padding(14)
                .background(.white, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Terminal Relay mobile pairing QR code")

            VStack(spacing: 6) {
                Label("Direct SSH pairing—no Terminal Relay cloud", systemImage: "lock.shield")
                Text("The code expires after 10 minutes, can authorize one device, and cannot open a shell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
            }

            Button("Create a New Code") {
                Task { await prepareInvitation() }
            }
            .disabled(isPreparing)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @MainActor
    private func prepareInvitation() async {
        guard !isPreparing else { return }
        isPreparing = true
        errorMessage = nil
        let previousInvitation = invitation
        invitation = nil

#if DEBUG
        if ScreenshotDemoMode.isEnabled {
            invitation = MobilePairingInvitation(
                id: "00000000-0000-4000-8000-000000004001",
                worker: worker,
                code: "terminal-relay-demo-pairing-code",
                expiresAt: Date().addingTimeInterval(MobilePairingService.invitationLifetime)
            )
            isPreparing = false
            return
        }
#endif

        if let previousInvitation {
            try? await MobilePairingService.revoke(
                token: previousInvitation.id,
                on: previousInvitation.worker
            )
        }

        do {
            invitation = try await MobilePairingService.prepare(worker: worker)
        } catch {
            errorMessage = error.localizedDescription
        }
        isPreparing = false
    }
}

private enum MobilePairingQRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let outputImage = filter.outputImage else { return nil }

        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 300, height: 300))
    }
}
