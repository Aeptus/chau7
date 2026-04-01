import SwiftUI
import Chau7Core

/// Settings view for API Analytics proxy configuration
struct ProxySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var proxyStatus: ProxyStatus = .disabled
    @State private var showingClearConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // API Call Tracking
            SettingsSectionHeader(L("settings.proxy.tracking", "API Call Tracking"), icon: "chart.bar.xaxis")

            SettingsToggle(
                label: L("settings.proxy.enable", "Enable API Analytics"),
                help: L(
                    "settings.proxy.enable.help",
                    "Route LLM API calls through a local proxy to capture token usage, costs, and latency metrics. Authentication is handled by CLI tools — no API keys are stored by Chau7."
                ),
                isOn: $settings.isAPIAnalyticsEnabled
            )

            SettingsRow(L("settings.proxy.status", "Status")) {
                statusIndicator
            }

            Divider()
                .padding(.vertical, 8)

            // Privacy
            SettingsSectionHeader(L("settings.proxy.privacy", "Privacy"), icon: "lock.shield")

            SettingsToggle(
                label: L("settings.proxy.logPrompts", "Log Prompt Previews"),
                help: L(
                    "settings.proxy.logPrompts.help",
                    "Store the first 500 characters of prompts and responses for debugging. Disable for maximum privacy."
                ),
                isOn: $settings.apiAnalyticsLogPrompts
            )

            SettingsToggle(
                label: L("settings.proxy.includeOpenAI", "Route OpenAI-Compatible Clients"),
                help: L(
                    "settings.proxy.includeOpenAI.help",
                    "Inject OPENAI_BASE_URL so Codex CLI and other OpenAI-compatible clients are routed through the proxy. Disable if you only want Anthropic and Gemini analytics."
                ),
                isOn: $settings.apiAnalyticsIncludeOpenAI
            )

            Divider()
                .padding(.vertical, 8)

            // Advanced
            SettingsSectionHeader(L("settings.proxy.advanced", "Advanced"), icon: "gearshape.2")

            SettingsRow(L("settings.proxy.port", "Port"), help: L("settings.proxy.port.help", "Local proxy port for intercepting API calls")) {
                TextField("", value: $settings.apiAnalyticsPort, format: .number)
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
            }

            SettingsButtonRow(buttons: [
                .init(title: L("settings.proxy.openFolder", "Open Database Folder"), icon: "folder", style: .bordered) {
                    openDatabaseFolder()
                },
                .init(title: L("settings.proxy.clearData", "Clear All Data"), icon: "trash", style: .bordered) {
                    showingClearConfirmation = true
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Supported Tools
            SettingsSectionHeader(L("settings.proxy.tools", "Supported Tools"), icon: "wrench.and.screwdriver")

            VStack(alignment: .leading, spacing: 8) {
                supportedToolRow(name: "Claude Code", supported: .full)
                supportedToolRow(name: "Codex CLI", supported: .full)
                supportedToolRow(name: "Gemini CLI", supported: .partial)
                supportedToolRow(name: "Aider", supported: .full)
                supportedToolRow(name: "Cursor", supported: .full)

                Text(L("settings.proxy.geminiNote", "Gemini CLI support is partial — may not work when Google OAuth session is cached."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }

            Divider()
                .padding(.vertical, 8)

            // How It Works
            SettingsSectionHeader(L("settings.proxy.howItWorks", "How It Works"), icon: "questionmark.circle")

            VStack(alignment: .leading, spacing: 8) {
                Text(L("settings.proxy.envVarsDescription", "When enabled, Chau7 sets environment variables to route API calls:"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    codeRow("ANTHROPIC_BASE_URL")
                    codeRow("OPENAI_BASE_URL")
                    codeRow("GOOGLE_GEMINI_BASE_URL")
                }
                .padding(.vertical, 4)

                Text(L("settings.proxy.openaiNote", "OpenAI SDKs expect OPENAI_BASE_URL to include /v1. Chau7 sets this automatically."))
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(L(
                    "settings.proxy.forwardingNote",
                    "The proxy logs metadata (model, tokens, latency) then forwards requests to the real APIs. Auth headers pass through unchanged."
                ))
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .onAppear {
            updateStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proxyStatusChanged)) { _ in
            updateStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiAnalyticsSettingsChanged)) { _ in
            updateStatus()
        }
        .alert(L("settings.proxy.clearConfirm.title", "Clear Analytics Data"), isPresented: $showingClearConfirmation) {
            Button(L("Cancel", "Cancel"), role: .cancel) {}
            Button(L("settings.proxy.clearConfirm.action", "Clear All"), role: .destructive) {
                clearAnalyticsData()
            }
        } message: {
            Text(L("settings.proxy.clearConfirm.message", "This will delete all captured API call data. This action cannot be undone."))
        }
    }

    // MARK: - Status Indicator

    @ViewBuilder
    private var statusIndicator: some View {
        switch proxyStatus {
        case .disabled:
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 8, height: 8)
                Text(L("status.disabled", "Disabled"))
                    .foregroundColor(.secondary)
            }
        case .starting:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text(L("status.starting", "Starting..."))
                    .foregroundColor(.orange)
            }
        case .running(let port):
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text(String(format: L("proxy.runningOnPort", "Running on port %d"), port))
                    .foregroundColor(.green)
            }
        case .error(let message):
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                Text(message)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Supported Tool Row

    private enum SupportLevel {
        case full
        case partial
    }

    private func supportedToolRow(name: String, supported: SupportLevel) -> some View {
        HStack(spacing: 6) {
            switch supported {
            case .full:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
            case .partial:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            Text(name)
                .font(.body)
        }
    }

    private func codeRow(_ code: String) -> some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
    }

    // MARK: - Actions

    private func updateStatus() {
        if !settings.isAPIAnalyticsEnabled {
            proxyStatus = .disabled
        } else if ProxyManager.shared.isRunning {
            proxyStatus = .running(port: settings.apiAnalyticsPort)
        } else {
            proxyStatus = .starting
        }
    }

    private func openDatabaseFolder() {
        let path = RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("Proxy", isDirectory: true)

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        NSWorkspace.shared.open(path)
    }

    private func clearAnalyticsData() {
        let dbPath = RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("Proxy", isDirectory: true)
            .appendingPathComponent("analytics.db")

        do {
            if FileManager.default.fileExists(atPath: dbPath.path) {
                try FileManager.default.removeItem(at: dbPath)
                Log.info("Analytics database cleared")
            }
        } catch {
            Log.error("Failed to clear analytics database: \(error)")
        }

        // Restart proxy to recreate database
        if settings.isAPIAnalyticsEnabled {
            ProxyManager.shared.restart()
        }
    }
}

// MARK: - Proxy Status

private enum ProxyStatus {
    case disabled
    case starting
    case running(port: Int)
    case error(String)
}
