import SwiftUI
import Chau7Core

/// Settings view for configuring LLM providers (BYOAI feature).
/// Allows users to select a provider, enter API keys (stored in Keychain),
/// configure endpoints, models, and test the connection.
struct LLMSettingsView: View {
    var settings: FeatureSettings
    @State private var selectedProvider: LLMProviderType = .openai
    @State private var apiKeyInput = ""
    @State private var endpointInput = ""
    @State private var modelInput = ""
    @State private var maxTokensInput = "1024"
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("LLM Provider"), icon: "brain")

            SettingsRow(
                L("settings.llm.provider", "Provider"),
                help: L("settings.llm.provider.help", "Choose the LLM backend for error explanation and AI features")
            ) {
                Picker("", selection: $selectedProvider) {
                    ForEach(LLMProviderType.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .onChange(of: selectedProvider) { loadProviderSettings() }

            // API Key
            if selectedProvider.requiresAPIKey {
                SettingsRow(
                    L("settings.llm.apiKey", "API Key"),
                    help: L("settings.llm.apiKey.help", "Stored securely in the macOS Keychain")
                ) {
                    HStack {
                        SecureField("", text: $apiKeyInput)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 240)
                        Button(L("Save", "Save")) {
                            saveAPIKey()
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            SettingsTextField(
                label: L("settings.llm.endpoint", "Endpoint URL"),
                help: L("settings.llm.endpoint.help", "API endpoint URL (leave empty for provider default)"),
                placeholder: selectedProvider.defaultEndpoint,
                text: $endpointInput,
                width: 300,
                monospaced: true
            )

            SettingsTextField(
                label: L("settings.llm.model", "Model"),
                help: L("settings.llm.model.help", "Model identifier (e.g. gpt-4o, claude-sonnet-4-20250514)"),
                placeholder: selectedProvider.defaultModel,
                text: $modelInput,
                width: 200,
                monospaced: true
            )

            SettingsTextField(
                label: L("settings.llm.maxTokens", "Max Tokens"),
                help: L("settings.llm.maxTokens.help", "Maximum tokens per response"),
                placeholder: "1024",
                text: $maxTokensInput,
                width: 80,
                monospaced: true
            )

            // Test connection
            HStack {
                Button(isTesting ? L("Testing...", "Testing...") : L("Test Connection", "Test Connection")) {
                    testConnection()
                }
                .buttonStyle(.bordered)
                .disabled(isTesting)

                if let result = testResult {
                    Text(result)
                        .font(.caption)
                        .foregroundColor(result.starts(with: "OK") ? .green : .red)
                }
            }

            Divider()
                .padding(.vertical, 8)

            SettingsSectionHeader(L("Error Explanation"), icon: "exclamationmark.bubble")

            SettingsToggle(
                label: L("Enable \"Explain This Error\""),
                help: L("Show an explain button when commands fail, using the configured LLM provider"),
                isOn: Binding(
                    get: { settings.errorExplainEnabled },
                    set: { settings.errorExplainEnabled = $0 }
                )
            )
        }
        .onAppear { loadProviderSettings() }
    }

    // MARK: - Load/Save

    private func loadProviderSettings() {
        let service = LLMProviderConfig(provider: selectedProvider).keychainService
        apiKeyInput = KeychainHelper.load(service: service, account: "apikey") ?? ""
        endpointInput = selectedProvider.defaultEndpoint
        modelInput = selectedProvider.defaultModel
        maxTokensInput = "1024"
    }

    private func saveAPIKey() {
        let service = LLMProviderConfig(provider: selectedProvider).keychainService
        KeychainHelper.save(service: service, account: "apikey", value: apiKeyInput)
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let config = LLMProviderConfig(
            provider: selectedProvider,
            apiKey: apiKeyInput,
            endpoint: endpointInput.isEmpty ? nil : endpointInput,
            model: modelInput.isEmpty ? nil : modelInput,
            maxTokens: Int(maxTokensInput) ?? 1024
        )

        Task {
            let client = LLMClient()
            let request = LLMRequest(
                systemPrompt: "Reply with OK.",
                userMessage: "Test connection",
                maxTokens: 10
            )
            do {
                let response = try await client.send(request: request, config: config)
                await MainActor.run {
                    testResult = "OK: \(response.model)"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "Error: \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }
}
