import Chau7Core
import SwiftUI

/// Modal sheet for pairing with the macOS app. Supports scanning the pairing QR
/// code shown by Chau7 on the Mac, a one-tap "Paste & Pair" from the clipboard,
/// or manually editing the pairing payload. Validation produces specific,
/// human-readable errors instead of a single generic failure.
struct PairingSheetView: View {
    var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var draftPayload = ""
    @State private var feedback: Feedback?
    @State private var isScannerPresented = false

    enum Feedback: Equatable {
        case error(String)
        case success

        var isSuccess: Bool { self == .success }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Open Chau7 on your Mac, enable Remote, and scan the secure QR code. You can also enter a securely supplied pairing payload.")
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

                Button {
                    pasteAndPair()
                } label: {
                    Label("Paste & Pair", systemImage: "doc.on.clipboard")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                DisclosureGroup("Enter pairing text manually") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextEditor(text: $draftPayload)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 120)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.3))
                            )
                            .accessibilityLabel("Pairing text")

                        HStack {
                            Button("Clear", role: .destructive) {
                                draftPayload = ""
                                feedback = nil
                            }
                            .disabled(draftPayload.isEmpty)
                            Spacer()
                            Button("Pair") { attemptPair(with: draftPayload) }
                                .buttonStyle(.borderedProminent)
                                .disabled(draftPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.top, 4)
                }
                .font(.subheadline)

                if let feedback {
                    switch feedback {
                    case .error(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    case .success:
                        Label("Paired! Connecting…", systemImage: "checkmark.circle.fill")
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

    private func pasteAndPair() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            feedback = .error("Your clipboard is empty. Scan the secure QR on your Mac, or enter a securely supplied pairing payload.")
            return
        }
        draftPayload = text
        attemptPair(with: text)
    }

    private func attemptPair(with payload: String) {
        switch PairingPayloadValidator.validate(payload) {
        case .success(let info):
            client.pairingInfo = info
            client.connect()
            feedback = .success
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                dismiss()
            }
        case .failure(let message):
            feedback = .error(message)
        }
    }
}
