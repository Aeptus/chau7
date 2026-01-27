import SwiftUI
import UIKit

struct PairingSheetView: View {
    @Binding var pairingPayload: String
    @Binding var pairingError: String?
    @Environment(\.dismiss) private var dismiss
    @State private var draftPayload: String = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Paste pairing JSON from Chau7 on your Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextEditor(text: $draftPayload)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3))
                    )

                if let error = pairingError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Paste from Clipboard") {
                        if let text = UIPasteboard.general.string {
                            draftPayload = text
                        }
                    }
                    Spacer()
                    Button("Save") {
                        savePayload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .navigationTitle("Pairing")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                draftPayload = pairingPayload
            }
        }
    }

    private func savePayload() {
        pairingError = nil
        guard let data = draftPayload.data(using: .utf8),
              let info = try? JSONDecoder().decode(PairingInfo.self, from: data) else {
            pairingError = "Invalid pairing JSON"
            return
        }
        if let normalized = try? JSONEncoder().encode(info),
           let normalizedString = String(data: normalized, encoding: .utf8) {
            pairingPayload = normalizedString
        } else {
            pairingPayload = draftPayload
        }
        dismiss()
    }
}
