import Chau7Core
import AVFoundation
import SwiftUI
import UIKit

/// Camera QR scanner used for pairing. Wraps an AVCaptureSession and reports the
/// first decoded payload string. Handles permission prompts and surfaces a
/// friendly message when the camera is unavailable or access is denied.
struct QRScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError)
    }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onScan: (String) -> Void
        let onError: (String) -> Void
        private var didScan = false

        init(onScan: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onScan = onScan
            self.onError = onError
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !didScan,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue, !value.isEmpty else { return }
            didScan = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan(value)
        }
    }
}

final class ScannerViewController: UIViewController {
    var coordinator: QRScannerView.Coordinator?

    private let session = AVCaptureSession()
    /// One serial queue for start and stop, so a stop can never run ahead of
    /// the start it follows and leave the camera on after the sheet closes.
    private let sessionQueue = DispatchQueue(label: "ch7.qr-scanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isVisible = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessAndConfigure()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        startRunningIfConfigured()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        // Always enqueue the stop: `isRunning` is still false while a start
        // is in flight, and skipping the stop then left the camera running.
        sessionQueue.async { [session] in
            session.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.coordinator?.onError("Camera access is needed to scan the pairing code. You can enable it in iOS Settings, or paste the pairing text instead.")
                    }
                }
            }
        default:
            coordinator?.onError("Camera access is off. Enable it in iOS Settings, or paste the pairing text instead.")
        }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            coordinator?.onError("This device's camera isn't available. Paste the pairing text instead.")
            return
        }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            coordinator?.onError("Couldn't start the camera. Paste the pairing text instead.")
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        addReticle()
        startRunningIfConfigured()
    }

    private func startRunningIfConfigured() {
        // The permission prompt can return after the sheet was dismissed.
        guard isVisible, !session.inputs.isEmpty else { return }
        sessionQueue.async { [session] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    private func addReticle() {
        let reticle = UIView()
        reticle.translatesAutoresizingMaskIntoConstraints = false
        reticle.layer.borderColor = UIColor.white.cgColor
        reticle.layer.borderWidth = 2
        reticle.layer.cornerRadius = 16
        reticle.backgroundColor = .clear
        view.addSubview(reticle)
        NSLayoutConstraint.activate([
            reticle.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            reticle.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            reticle.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.7),
            reticle.heightAnchor.constraint(equalTo: reticle.widthAnchor)
        ])
    }
}
