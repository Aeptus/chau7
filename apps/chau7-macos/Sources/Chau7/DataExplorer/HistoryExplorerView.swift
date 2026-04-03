import SwiftUI
import Chau7Core

struct HistoryExplorerView: View {
    @State private var records: [HistoryRecord] = []
    @State private var searchText = ""
    @State private var totalCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Search + stats bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L("placeholder.searchCommands", "Search commands..."), text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { reload() }
                Spacer()
                Text(String(format: L("explorer.history.totalRecords", "%d total records"), totalCount))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // Table
            if records.isEmpty {
                VStack {
                    Spacer()
                    Text(searchText.isEmpty ? L("explorer.history.noHistory", "No command history yet") : L("explorer.history.noMatches", "No matching commands"))
                        .foregroundStyle(.secondary)
                    Text(L("explorer.history.hint", "Commands will appear here as you use the terminal"))
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(records) { record in
                    HistoryRecordRow(record: record)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        totalCount = PersistentHistoryStore.shared.totalCount()
        if searchText.isEmpty {
            records = PersistentHistoryStore.shared.recent(limit: 200)
        } else {
            records = PersistentHistoryStore.shared.search(query: searchText, limit: 200)
        }
    }
}

private struct HistoryRecordRow: View {
    let record: HistoryRecord

    var body: some View {
        HStack(spacing: 12) {
            // Exit code indicator
            if let code = record.exitCode {
                Image(systemName: code == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(code == 0 ? .green : .red)
                    .font(.system(size: 12))
                    .frame(width: 16)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    .frame(width: 16)
            }

            // Command
            Text(record.command)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Directory
            if let dir = record.directory {
                Text(shortenPath(dir))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 150, alignment: .trailing)
            }

            // Duration
            if let dur = record.duration, dur > 0 {
                Text(formatDuration(dur))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }

            // Timestamp
            Text(formatDate(record.timestamp))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return String(format: "%.0fms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins)m\(secs)s"
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
