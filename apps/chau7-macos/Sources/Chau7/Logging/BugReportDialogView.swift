import SwiftUI

/// Privacy-first bug report dialog.
///
/// Shows a live preview of the markdown that will be submitted. All sensitive
/// sections are OFF by default. Each sensitive toggle has its own tab picker
/// and an inline privacy warning.
struct BugReportDialogView: View {
    @ObservedObject var draft: BugReportDraft
    let onClose: () -> Void

    @State private var savedPath: String?
    @State private var showSavedAlert = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    disclosureSection
                    descriptionSection
                    contactSection
                    Divider()
                    globalTogglesSection
                    Divider()
                    tabDiagnosticsSection
                    Divider()
                    previewSection
                }
                .padding(20)
            }

            Divider()
            actionBar
        }
        .frame(minWidth: 540, minHeight: 520)
        .alert("Report Saved", isPresented: $showSavedAlert) {
            Button("Show in Finder") {
                if let path = savedPath {
                    let url = URL(fileURLWithPath: path).deletingLastPathComponent()
                    NSWorkspace.shared.open(url)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text("Saved to \(savedPath ?? "reports folder")")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        Text(L("bugReport.title", "Report an Issue"))
            .font(.system(size: 18, weight: .semibold))
    }

    // MARK: - Disclosure

    private var disclosureSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            Text(L(
                "bugReport.disclosure",
                "This report is submitted privately to a secure endpoint maintained by Chau7's developers. Only the development team can view submitted reports. No data is sent until you click Submit."
            ))
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Description

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("bugReport.descriptionLabel", "What happened?"))
                .font(.system(size: 12, weight: .medium))
            TextEditor(text: $draft.userDescription)
                .font(.system(size: 12))
                .frame(minHeight: 80, maxHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
                .overlay(alignment: .topLeading, content: {
                    if draft.userDescription.isEmpty {
                        Text(L("bugReport.descriptionPlaceholder", "Describe what happened and what you expected..."))
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                })
        }
    }

    // MARK: - Contact Info

    private var contactSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                TextField(
                    L("bugReport.contactName", "Your name"),
                    text: $draft.contactName
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                TextField(
                    L("bugReport.contactHandle", "GitHub username or email"),
                    text: $draft.contactHandle
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                Toggle(isOn: $draft.saveContactInfo) {
                    Text(L("bugReport.rememberContact", "Remember for future reports"))
                        .font(.system(size: 11))
                }
                .toggleStyle(.checkbox)
            }
            .padding(.top, 4)
        } label: {
            Text(L("bugReport.contactHeader", "Your info (optional)"))
                .font(.system(size: 12, weight: .medium))
        }
    }

    // MARK: - Global Toggles

    private var globalTogglesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("bugReport.diagnosticsHeader", "Diagnostic information"))
                .font(.system(size: 12, weight: .medium))

            diagnosticToggle(
                isOn: $draft.includeFeatureFlags,
                label: L("bugReport.toggle.featureFlags", "Feature settings"),
                description: L("bugReport.toggle.featureFlags.desc", "Which features are enabled or disabled — no personal data.")
            )

            diagnosticToggle(
                isOn: $draft.includeLogs,
                label: L("bugReport.toggle.logs", "Application logs"),
                description: L("bugReport.toggle.logs.desc", "Last 50 log lines."),
                warning: L("bugReport.toggle.logs.warn", "May contain file paths and command output.")
            )

            diagnosticToggle(
                isOn: $draft.includeEvents,
                label: L("bugReport.toggle.events", "Recent events"),
                description: L("bugReport.toggle.events.desc", "Last 20 app events — tool calls and notifications."),
                warning: L("bugReport.toggle.events.warn", "Shows recent app activity.")
            )
        }
    }

    // MARK: - Tab Diagnostics

    private var tabDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("bugReport.tabHeader", "Tab-specific diagnostics"))
                .font(.system(size: 12, weight: .medium))

            // Tab metadata toggle + picker
            diagnosticToggle(
                isOn: $draft.includeTabMetadata,
                label: L("bugReport.toggle.tabMetadata", "Send tab metadata"),
                description: L("bugReport.toggle.tabMetadata.desc", "Tab title, active app, status, and working directory."),
                warning: L("bugReport.toggle.tabMetadata.warn", "Shares tab title, working directory, and app info from the selected tab.")
            )
            if draft.includeTabMetadata {
                tabPicker(selection: $draft.metadataTabID)
                    .padding(.leading, 20)
            }

            // Terminal history toggle + picker
            diagnosticToggle(
                isOn: $draft.includeTerminalHistory,
                label: L("bugReport.toggle.history", "Send terminal history"),
                description: L("bugReport.toggle.history.desc", "Last 50 lines of terminal output from the selected tab."),
                warning: L("bugReport.toggle.history.warn", "Terminal output may contain commands, file paths, API keys, or other sensitive content.")
            )
            .onChange(of: draft.includeTerminalHistory) { enabled in
                if enabled, let tabID = draft.historyTabID {
                    draft.cachedTerminalHistory = draft.captureTabHistory(tabID: tabID)
                } else if !enabled {
                    draft.cachedTerminalHistory = nil
                }
            }
            if draft.includeTerminalHistory {
                tabPicker(selection: $draft.historyTabID)
                    .padding(.leading, 20)
                    .onChange(of: draft.historyTabID) { newTabID in
                        if let tabID = newTabID {
                            draft.cachedTerminalHistory = draft.captureTabHistory(tabID: tabID)
                        }
                    }
            }

            // AI session toggle (uses metadata tab)
            diagnosticToggle(
                isOn: $draft.includeAISession,
                label: L("bugReport.toggle.aiSession", "Send AI session info"),
                description: L("bugReport.toggle.aiSession.desc", "AI agent state, project name, and recent tool usage."),
                warning: L("bugReport.toggle.aiSession.warn", "Shares AI agent state and project name.")
            )
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L("bugReport.previewHeader", "Report preview"))
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(draft.markdownReport, forType: .string)
                } label: {
                    Label(L("bugReport.copy", "Copy"), systemImage: "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            ScrollView {
                Text(draft.markdownReport)
                    .font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            if let error = draft.submitError {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            if let issueNumber = draft.submitSuccess {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(L("bugReport.success", "Issue #\(issueNumber) submitted"))
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            }

            Spacer()

            Button(L("bugReport.cancel", "Cancel")) {
                onClose()
            }
            .keyboardShortcut(.cancelAction)

            Button(L("bugReport.saveLocally", "Save Locally")) {
                if let path = draft.saveLocally() {
                    savedPath = path
                    showSavedAlert = true
                }
            }

            Button {
                // Guard against double-click: check before setting to avoid race
                guard !draft.isSubmitting else { return }
                draft.persistContactInfoIfNeeded()
                // Capture the report on main thread before going async
                let preparedReport = draft.markdownReport
                draft.isSubmitting = true
                draft.submitError = nil
                Task {
                    do {
                        let issueNumber = try await draft.submit(preparedReport: preparedReport)
                        await MainActor.run {
                            draft.isSubmitting = false
                            draft.submitSuccess = issueNumber
                            // Auto-close after a short delay on success
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                onClose()
                            }
                        }
                    } catch {
                        await MainActor.run {
                            draft.isSubmitting = false
                            draft.submitError = error.localizedDescription
                        }
                    }
                }
            } label: {
                if draft.isSubmitting {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                        Text(L("bugReport.submitting", "Submitting..."))
                    }
                } else {
                    Text(L("bugReport.submit", "Submit"))
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.isSubmitting || draft.submitSuccess != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Reusable Components

    private func diagnosticToggle(
        isOn: Binding<Bool>,
        label: String,
        description: String,
        warning: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: isOn) {
                Text(label)
                    .font(.system(size: 12))
            }
            .toggleStyle(.checkbox)

            Text(description)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.leading, 20)

            if let warning, isOn.wrappedValue {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.leading, 20)
            }
        }
    }

    private func tabPicker(selection: Binding<UUID?>) -> some View {
        HStack(spacing: 4) {
            ForEach(draft.availableTabs, id: \.id) { tab in
                let isSelected = selection.wrappedValue == tab.id
                Button {
                    selection.wrappedValue = tab.id
                } label: {
                    Text(tab.label)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().stroke(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
