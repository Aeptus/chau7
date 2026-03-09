import SwiftUI
import UIKit

struct PairingSheetView: View {
    @ObservedObject var client: RemoteClient
    @Environment(\.dismiss) private var dismiss
    @State private var draftPayload = ""
    @State private var error: String?

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

                if let error {
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
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(draftPayload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
            .navigationTitle("Pairing")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let info = client.pairingInfo,
                   let data = try? JSONEncoder().encode(info),
                   let str = String(data: data, encoding: .utf8) {
                    draftPayload = str
                }
            }
        }
    }

    private func save() {
        error = nil
        guard let data = draftPayload.data(using: .utf8),
              let info = try? JSONDecoder().decode(PairingInfo.self, from: data) else {
            error = "Invalid pairing JSON"
            return
        }
        client.pairingInfo = info
        dismiss()
    }
}
