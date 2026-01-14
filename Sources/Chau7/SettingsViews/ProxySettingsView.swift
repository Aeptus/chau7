import SwiftUI

/// Settings view for API Analytics proxy configuration
struct ProxySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var proxyStatus: ProxyStatus = .disabled
    @State private var showingClearConfirmation = false

    var body: some View {
        Form {
            // Main Toggle Section
            Section {
                Toggle("Enable API Analytics", isOn: $settings.isAPIAnalyticsEnabled)

                HStack {
                    Text("Status:")
                    statusIndicator
                }
            } header: {
                Text("API Call Tracking")
            } footer: {
                Text("Routes LLM API calls through a local proxy to capture token usage, costs, and latency metrics. Authentication is handled by CLI tools — no API keys are stored by Chau7.")
            }

            // Privacy Section
            Section {
                Toggle("Log prompt previews", isOn: $settings.apiAnalyticsLogPrompts)
            } header: {
                Text("Privacy")
            } footer: {
                Text("When enabled, stores the first 500 characters of prompts and responses for debugging. Disable for maximum privacy.")
            }

            // Advanced Section
            Section {
                HStack {
                    Text("Port")
                    Spacer()
                    TextField("", value: $settings.apiAnalyticsPort, format: .number)
                        .frame(width: 80)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Button("Open Database Folder") {
                        openDatabaseFolder()
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button("Clear All Data", role: .destructive) {
                        showingClearConfirmation = true
                    }
                    .buttonStyle(.borderless)
                }
            } header: {
                Text("Advanced")
            }

            // Supported Tools Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    supportedToolRow(name: "Claude Code", supported: .full)
                    supportedToolRow(name: "Codex CLI", supported: .full)
                    supportedToolRow(name: "Gemini CLI", supported: .partial)
                    supportedToolRow(name: "Aider", supported: .full)
                    supportedToolRow(name: "Cursor", supported: .full)

                    Text("Gemini CLI support is partial — may not work when Google OAuth session is cached.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }
            } header: {
                Text("Supported Tools")
            }

            // How It Works Section
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("When enabled, Chau7 sets environment variables to route API calls:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        codeRow("ANTHROPIC_BASE_URL")
                        codeRow("OPENAI_BASE_URL")
                        codeRow("GOOGLE_GEMINI_BASE_URL")
                    }
                    .padding(.vertical, 4)

                    Text("OpenAI SDKs expect OPENAI_BASE_URL to include /v1. Chau7 sets this automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("The proxy logs metadata (model, tokens, latency) then forwards requests to the real APIs. Auth headers pass through unchanged.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("How It Works")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            updateStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .proxyStatusChanged)) { _ in
            updateStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .apiAnalyticsSettingsChanged)) { _ in
            updateStatus()
        }
        .alert("Clear Analytics Data", isPresented: $showingClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                clearAnalyticsData()
            }
        } message: {
            Text("This will delete all captured API call data. This action cannot be undone.")
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
                Text("Disabled")
                    .foregroundColor(.secondary)
            }
        case .starting:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Starting...")
                    .foregroundColor(.orange)
            }
        case .running(let port):
            HStack(spacing: 4) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Running on port \(port)")
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

    @ViewBuilder
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

    @ViewBuilder
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
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Chau7/proxy")

        // Create directory if it doesn't exist
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        NSWorkspace.shared.open(path)
    }

    private func clearAnalyticsData() {
        let dbPath = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Chau7/proxy/analytics.db")

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

// MARK: - Preview

#if DEBUG
struct ProxySettingsView_Previews: PreviewProvider {
    static var previews: some View {
        ProxySettingsView()
            .frame(width: 500, height: 600)
    }
}
#endif
