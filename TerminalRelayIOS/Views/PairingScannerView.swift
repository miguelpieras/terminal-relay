import AVFoundation
import SwiftUI
import UIKit

struct PairingScannerView: View {
    @Environment(\.dismiss) private var dismiss

    let onScanned: (String) -> Void

    @State private var cameraError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                QRCodeScannerView(
                    onCode: onScanned,
                    onError: { cameraError = $0 }
                )
                .ignoresSafeArea()

                VStack {
                    Text("Point your camera at the pairing code on your Mac.")
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 14)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        .padding()

                    Spacer()

                    if let cameraError {
                        VStack(spacing: 12) {
                            Text(cameraError)
                                .font(.callout)
                                .multilineTextAlignment(.center)
                            pasteButton
                        }
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding()
                    }
                }
            }
            .navigationTitle("Pair with Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    pasteButton
                }
            }
        }
    }

    private var pasteButton: some View {
        Button("Paste Code") {
            guard let code = UIPasteboard.general.string,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                cameraError = "No pairing code is available on the clipboard."
                return
            }
            onScanned(code.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

private struct QRCodeScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        QRCodeScannerViewController(onCode: onCode, onError: onError)
    }

    func updateUIViewController(
        _ uiViewController: QRCodeScannerViewController,
        context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: QRCodeScannerViewController,
        coordinator: ()
    ) {
        uiViewController.stop()
    }
}

private final class QRCodeScannerViewController:
    UIViewController,
    AVCaptureMetadataOutputObjectsDelegate
{
    private let onCode: (String) -> Void
    private let onError: (String) -> Void
    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "terminal-relay.pairing-camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasDeliveredCode = false

    init(
        onCode: @escaping (String) -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.onCode = onCode
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func stop() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    private func requestCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted {
                        self.configureCamera()
                    } else {
                        self.onError("Camera access is required to scan the pairing code.")
                    }
                }
            }
        case .denied, .restricted:
            onError("Allow camera access in Settings, or paste the pairing code.")
        @unknown default:
            onError("The camera is unavailable. Paste the pairing code instead.")
        }
    }

    private func configureCamera() {
        guard let camera = AVCaptureDevice.default(for: .video) else {
            onError("No camera is available. Paste the pairing code instead.")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: camera)
            guard captureSession.canAddInput(input) else {
                onError("The camera could not be started. Paste the pairing code instead.")
                return
            }
            captureSession.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard captureSession.canAddOutput(output) else {
                onError("QR scanning is unavailable. Paste the pairing code instead.")
                return
            }
            captureSession.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer.videoGravity = .resizeAspectFill
            previewLayer.frame = view.bounds
            view.layer.addSublayer(previewLayer)
            self.previewLayer = previewLayer

            sessionQueue.async { [captureSession] in
                captureSession.startRunning()
            }
        } catch {
            onError("The camera could not be started. Paste the pairing code instead.")
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasDeliveredCode,
              let codeObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              codeObject.type == .qr,
              let value = codeObject.stringValue else {
            return
        }
        hasDeliveredCode = true
        stop()
        onCode(value)
    }
}
