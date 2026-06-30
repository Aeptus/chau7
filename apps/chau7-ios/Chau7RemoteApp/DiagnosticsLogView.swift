import SwiftUI

/// In-app viewer for the verbose diagnostics log, with category/level
/// filtering, search, and a share-based export.
struct DiagnosticsLogView: View {
    @State private var log = DiagnosticsLog.shared
    @State private var searchText = ""
    @State private var minimumLevel: DiagnosticsLog.Level = .trace
    @State private var selectedCategory: DiagnosticsLog.Category?
    @State private var exportItem: ExportItem?
    @State private var showClearConfirmation = false

    /// Identifiable wrapper so the export URL can drive `.sheet(item:)`
    /// without a retroactive `URL: Identifiable` conformance.
    private struct ExportItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }

    private var filteredEntries: [DiagnosticsLog.Entry] {
        log.entries.reversed().filter { entry in
            if entry.levelValue < minimumLevel { return false }
            if let selectedCategory, entry.category != selectedCategory.rawValue { return false }
            if !searchText.isEmpty {
                let haystack = entry.message + " " + entry.metadata.values.joined(separator: " ")
                if !haystack.localizedCaseInsensitiveContains(searchText) { return false }
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            logList
        }
        .navigationTitle("Diagnostics Log")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        if let url = log.exportFile() {
                            exportItem = ExportItem(url: url)
                        }
                    } label: {
                        Label("Export Log…", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        log.capturePerformanceSnapshot(reason: "manual")
                    } label: {
                        Label("Capture Perf Snapshot", systemImage: "gauge")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Label("Clear Log", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }
        .confirmationDialog(
            "Clear the diagnostics log? This cannot be undone.",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear Log", role: .destructive) { log.clear() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Picker("Level", selection: $minimumLevel) {
                    Text("All").tag(DiagnosticsLog.Level.trace)
                    Text("Debug+").tag(DiagnosticsLog.Level.debug)
                    Text("Info+").tag(DiagnosticsLog.Level.info)
                    Text("Warn+").tag(DiagnosticsLog.Level.warn)
                    Text("Errors").tag(DiagnosticsLog.Level.error)
                }
                .pickerStyle(.menu)

                filterChip(title: "All", isOn: selectedCategory == nil) {
                    selectedCategory = nil
                }
                ForEach(DiagnosticsLog.Category.allCases, id: \.self) { category in
                    filterChip(title: category.rawValue, isOn: selectedCategory == category) {
                        selectedCategory = selectedCategory == category ? nil : category
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(UIColor.secondarySystemBackground))
    }

    private func filterChip(title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isOn ? Color.accentColor : Color(UIColor.tertiarySystemBackground))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var logList: some View {
        if filteredEntries.isEmpty {
            ContentUnavailableView(
                "No Log Entries",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Entries will appear here as you use the app.")
            )
        } else {
            List(filteredEntries) { entry in
                DiagnosticsRow(entry: entry)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            .listStyle(.plain)
        }
    }
}

private struct DiagnosticsRow: View {
    let entry: DiagnosticsLog.Entry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(entry.levelValue.description)
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(levelColor.opacity(0.2))
                    .foregroundStyle(levelColor)
                    .clipShape(Capsule())
                Text(entry.category)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(entry.message)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.primary)
            if !entry.metadata.isEmpty {
                Text(metadataText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    private var metadataText: String {
        entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "  ")
    }

    private var levelColor: Color {
        switch entry.levelValue {
        case .trace: return .gray
        case .debug: return .blue
        case .info: return .green
        case .warn: return .orange
        case .error: return .red
        }
    }
}

/// Bridges `UIActivityViewController` so the export file can be shared/saved.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
