import SwiftUI
import Chau7Core

struct SessionsExplorerView: View {
    @State private var sessions: [[String: Any]] = []

    var body: some View {
        Group {
            if sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No sessions recorded yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(sessions.indices, id: \.self) { index in
                    let session = sessions[index]
                    SessionRow(session: session)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        sessions = TelemetryStore.shared.listSessions()
    }
}

private struct SessionRow: View {
    let session: [String: Any]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(sessionID)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)

                Spacer()

                if let provider = session["provider"] as? String {
                    Text(provider.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.purple)
                }
            }

            HStack {
                if let repo = session["repo_path"] as? String {
                    Text(URL(fileURLWithPath: repo).lastPathComponent)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let count = session["run_count"] as? Int {
                    Text("\(count) runs")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let lastActive = session["last_active"] as? String {
                    Text(lastActive)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var sessionID: String {
        guard let id = session["session_id"] as? String else { return "—" }
        if id.count > 12 { return String(id.prefix(8)) + "..." }
        return id
    }
}
