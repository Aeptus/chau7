import Chau7Core
import SwiftUI

/// Modal sheet for pairing with the macOS app by scanning the QR code Chau7
/// shows on the Mac. The QR is the only carrier of the relay credential, so
/// there is no paste or manual entry. Success is reported only once the Mac
/// has accepted the scan; until then the previous pairing stays stored.
struct PairingSheetView: View {
    var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var feedback: Feedback?
    @State private var isScannerPresented = false

    enum Feedback: Equatable {
        case error(String)
        case waiting
        case success

        var isSuccess: Bool { self == .success }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open Chau7 on your Mac, enable Remote, and scan the QR code it shows.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    feedback = nil
                    isScannerPresented = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if let feedback {
                    switch feedback {
                    case .error(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    case .waiting:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Waiting for your Mac…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    case .success:
                        Label("Paired", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $isScannerPresented) {
                scannerSheet
            }
            .onChange(of: client.pairingAttempt) { _, attempt in
                // Only an attempt this sheet started is reflected here.
                guard feedback == .waiting else { return }
                switch attempt {
                case .accepted:
                    feedback = .success
                    Task {
                        try? await Task.sleep(for: .milliseconds(600))
                        dismiss()
                    }
                case .failed(let message):
                    feedback = .error(message)
                case .idle, .waitingForMac:
                    break
                }
            }
        }
    }

    private var scannerSheet: some View {
        NavigationStack {
            QRScannerView(
                onScan: { value in
                    isScannerPresented = false
                    attemptPair(with: value)
                },
                onError: { message in
                    isScannerPresented = false
                    feedback = .error(message)
                }
            )
            .ignoresSafeArea()
            .navigationTitle("Scan Pairing Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { isScannerPresented = false }
                }
            }
        }
    }

    private func attemptPair(with payload: String) {
        switch PairingPayloadValidator.validate(payload) {
        case .success(let info):
            feedback = .waiting
            client.beginPairing(info)
        case .failure(let message):
            feedback = .error(message)
        }
    }
}
