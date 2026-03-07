import SwiftUI
import Chau7Core

/// Settings view for configuring LLM providers (BYOAI feature).
/// Allows users to select a provider, enter API keys (stored in Keychain),
/// configure endpoints, models, and test the connection.
struct LLMSettingsView: View {
    @ObservedObject var settings: FeatureSettings
    @State private var selectedProvider: LLMProviderType = .openai
    @State private var apiKeyInput = ""
    @State private var endpointInput = ""
    @State private var modelInput = ""
    @State private var maxTokensInput = "1024"
    @State private var testResult: String?
    @State private var isTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsSectionHeader(L("LLM Provider"))

            // Provider picker
            Picker(L("Provider", "Provider"), selection: $selectedProvider) {
                ForEach(LLMProviderType.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedProvider) { _ in loadProviderSettings() }

            // API Key
            if selectedProvider.requiresAPIKey {
                HStack {
                    SecureField(L("API Key", "API Key"), text: $apiKeyInput)
                        .textFieldStyle(.roundedBorder)
                    Button(L("Save", "Save")) {
                        saveAPIKey()
                    }
                    .buttonStyle(.bordered)
                }
                SettingsDescription(text: L("Stored securely in the macOS Keychain"))
            }

            // Endpoint
            TextField(L("Endpoint URL", "Endpoint URL"), text: $endpointInput)
                .textFieldStyle(.roundedBorder)
            SettingsDescription(L("Default: \(selectedProvider.defaultEndpoint)"))

            // Model
            TextField(L("Model", "Model"), text: $modelInput)
                .textFieldStyle(.roundedBorder)

            // Max tokens
            HStack {
                Text(L("Max Tokens:", "Max Tokens:"))
                TextField(L("1024", "1024"), text: $maxTokensInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            // Test connection
            HStack {
                Button(isTesting ? "Testing..." : "Test Connection") {
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

            SettingsSectionHeader(L("Error Explanation"))

            SettingsToggle(
                label: L("Enable \"Explain This Error\""),
                help: L("Show an explain button when commands fail"),
                isOn: Binding(
                    get: { settings.errorExplainEnabled },
                    set: { settings.errorExplainEnabled = $0 }
                )
            )
        }
        .padding()
        .onAppear { loadProviderSettings() }
    }

    // MARK: - Load/Save

    private func loadProviderSettings() {
        let service = "com.chau7.llm.\(selectedProvider.rawValue).apikey"
        apiKeyInput = KeychainHelper.load(service: service, account: "apikey") ?? ""
        endpointInput = selectedProvider.defaultEndpoint
        modelInput = selectedProvider.defaultModel
        maxTokensInput = "1024"
    }

    private func saveAPIKey() {
        let service = "com.chau7.llm.\(selectedProvider.rawValue).apikey"
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
