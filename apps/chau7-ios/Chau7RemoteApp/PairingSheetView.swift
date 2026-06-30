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
                Text("Open Chau7 on your Mac, enable Remote, and scan the pairing code — or paste it here.")
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
            .onAppear {
                if let info = client.pairingInfo,
                   let data = try? RemoteJSON.encoder.encode(info),
                   let str = String(data: data, encoding: .utf8) {
                    draftPayload = str
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

    private func pasteAndPair() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            feedback = .error("Your clipboard is empty. Copy the pairing text from Chau7 on your Mac first.")
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

/// Outcome of validating a pairing payload: a decoded `PairingInfo` or a
/// specific, human-readable problem. A dedicated enum (rather than `Result`)
/// avoids conforming `String` to `Error` just to carry the message.
enum PairingValidationResult {
    case success(PairingInfo)
    case failure(String)
}

/// Validates a pasted/scanned pairing payload and reports specific problems.
enum PairingPayloadValidator {
    static func validate(_ raw: String) -> PairingValidationResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure("Nothing to pair with. Paste or scan the pairing code from your Mac.")
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("That doesn't look like a Chau7 pairing code. Copy it from the Remote panel on your Mac.")
        }

        let requiredFields: [(key: String, label: String)] = [
            ("relay_url", "relay URL"),
            ("device_id", "device ID"),
            ("mac_pub", "Mac key"),
            ("pairing_code", "pairing code"),
            ("expires_at", "expiry")
        ]
        for field in requiredFields where (object[field.key] as? String)?.isEmpty ?? true {
            return .failure("The pairing code is missing its \(field.label). Generate a fresh code on your Mac.")
        }

        guard let info = try? JSONDecoder().decode(PairingInfo.self, from: data) else {
            return .failure("The pairing code couldn't be read. Generate a fresh code on your Mac.")
        }

        if let expiry = parseDate(info.expiresAt), expiry < Date() {
            return .failure("This pairing code has expired. Generate a new one on your Mac.")
        }

        guard URLComponents(string: info.relayURL)?.scheme?.lowercased() == "wss" else {
            return .failure("Relay URL must use wss:// (encrypted transport). Generate a fresh code on your Mac.")
        }

        return .success(info)
    }

    private static func parseDate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
