import Foundation
import SwiftUI

@MainActor
@Observable
final class IssueReportDraft {
    private nonisolated static let endpoint = "https://issues.chau7.sh"

    let context: RemoteIssueReportContext
    var userDescription = ""
    var contact: String
    var saveContact: Bool
    var includeDiagnostics = false
    var isSubmitting = false
    var submitError: String?
    var submittedIssueNumber: Int?
    var didSubmit = false

    init(client: RemoteClient) {
        context = RemoteIssueReportContext(
            appVersion: RemoteClient.appVersion,
            osVersion: UIDevice.current.systemVersion,
            deviceModel: UIDevice.current.model,
            connectionStatus: client.connectionDisplayLabel,
            tabInventoryStatus: client.remoteTabsDisplayLabel,
            tabCount: client.tabs.count
        )
        contact = UserDefaults.standard.string(forKey: AppSettings.issueReportContactKey) ?? ""
        saveContact = UserDefaults.standard.object(forKey: AppSettings.issueReportSaveContactKey) as? Bool ?? false
    }

    var canSubmit: Bool {
        !userDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSubmitting
    }

    var markdownReport: String {
        RemoteIssueReportComposer.markdown(
            description: userDescription,
            contact: contact,
            context: context,
            diagnostics: includeDiagnostics ? DiagnosticsLog.shared.reportExcerpt() : nil
        )
    }

    func submit() async {
        guard canSubmit else { return }
        isSubmitting = true
        submitError = nil
        defer { isSubmitting = false }

        do {
            submittedIssueNumber = try await Self.post(markdownReport, appVersion: context.appVersion)
            didSubmit = true
            persistContactPreference()
            DiagnosticsLog.shared.info(.network, "Issue report submitted", [
                "issue_number": submittedIssueNumber.map(String.init) ?? "unknown",
                "diagnostics_included": includeDiagnostics ? "true" : "false"
            ])
        } catch {
            submitError = error.localizedDescription
            DiagnosticsLog.shared.error(.network, "Issue report submission failed", [
                "error": error.localizedDescription
            ])
        }
    }

    func exportFile() -> URL? {
        persistContactPreference()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-ios-issue-\(formatter.string(from: Date())).md")
        do {
            try markdownReport.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            submitError = "Could not prepare the report for sharing: \(error.localizedDescription)"
            return nil
        }
    }

    private func persistContactPreference() {
        UserDefaults.standard.set(saveContact, forKey: AppSettings.issueReportSaveContactKey)
        UserDefaults.standard.set(saveContact ? contact : "", forKey: AppSettings.issueReportContactKey)
    }

    private nonisolated static func post(_ report: String, appVersion: String) async throws -> Int? {
        guard let url = URL(string: endpoint), url.scheme == "https" else {
            throw IssueReportSubmissionError.invalidEndpoint
        }
        let payload = [
            "title": "iOS issue report from Chau7 Remote \(appVersion)",
            "body": report
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw IssueReportSubmissionError.invalidResponse
        }
        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            if httpResponse.statusCode == 429 {
                throw IssueReportSubmissionError.rateLimited
            }
            throw IssueReportSubmissionError.server(status: httpResponse.statusCode)
        }
        let responseBody = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return responseBody?["issue_number"] as? Int
    }
}

private enum IssueReportSubmissionError: LocalizedError {
    case invalidEndpoint
    case invalidResponse
    case rateLimited
    case server(status: Int)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Issue reporting is not configured correctly."
        case .invalidResponse:
            return "The issue service returned an invalid response."
        case .rateLimited:
            return "Too many reports were submitted recently. Please try again later."
        case let .server(status):
            return "The issue service returned HTTP \(status)."
        }
    }
}

struct IssueReportView: View {
    @State private var draft: IssueReportDraft
    @State private var isPreviewExpanded = false
    @State private var exportItem: IssueExportItem?

    init(client: RemoteClient) {
        _draft = State(initialValue: IssueReportDraft(client: client))
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $draft.userDescription)
                    .frame(minHeight: 150)
                    .accessibilityLabel("Issue description")
            } header: {
                Text("What happened?")
            } footer: {
                Text("Include what you expected, what happened instead, and whether you can reproduce it.")
            }

            Section("Contact (optional)") {
                TextField("GitHub username or email", text: $draft.contact)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Toggle("Remember contact", isOn: $draft.saveContact)
            }

            Section {
                Toggle("Include recent diagnostics", isOn: $draft.includeDiagnostics)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Off by default. When enabled, the latest 500 on-device log entries are attached. If keystroke logging is enabled, those entries may contain text typed into terminals.")
            }

            Section {
                DisclosureGroup("Preview report", isExpanded: $isPreviewExpanded) {
                    ScrollView(.horizontal) {
                        Text(draft.markdownReport)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 8)
                    }
                }
            }

            Section {
                Button {
                    Task { await draft.submit() }
                } label: {
                    HStack {
                        Label("Create Issue", systemImage: "paperplane")
                        Spacer()
                        if draft.isSubmitting { ProgressView() }
                    }
                }
                .disabled(!draft.canSubmit)

                Button {
                    if let url = draft.exportFile() {
                        exportItem = IssueExportItem(url: url)
                    }
                } label: {
                    Label("Share Report Instead…", systemImage: "square.and.arrow.up")
                }
            }

            if draft.didSubmit {
                Section {
                    Label(
                        draft.submittedIssueNumber.map { "Issue #\($0) was created." } ?? "Issue was created.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                }
            }

            if let error = draft.submitError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } footer: {
                    Text("You can still share the prepared Markdown report.")
                }
            }
        }
        .navigationTitle("Report an Issue")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private struct IssueExportItem: Identifiable {
        let url: URL
        var id: String { url.absoluteString }
    }
}

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
