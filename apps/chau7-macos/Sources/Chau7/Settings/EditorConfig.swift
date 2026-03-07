import Foundation

// MARK: - Editor Configuration

/// Configuration for the enhanced editor.
/// Persisted in UserDefaults as JSON under the "editor.config" key.
struct EditorConfig: Codable, Equatable {
    var fontSize = 13
    var tabSize = 4
    var useSpacesForTabs = true
    var wordWrap = true
    var showLineNumbers = true
    var autoIndent = true
    var bracketMatching = true
    var showMinimap = false
    var highlightCurrentLine = true
    var theme = "default"

    static let `default` = EditorConfig()

    /// Load persisted configuration from UserDefaults.
    static func load() -> EditorConfig {
        guard let data = UserDefaults.standard.data(forKey: "editor.config"),
              let config = try? JSONDecoder().decode(EditorConfig.self, from: data)
        else {
            return .default
        }
        return config
    }

    /// Persist configuration to UserDefaults.
    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: "editor.config")
        }
    }

    /// Tab insertion string based on current configuration.
    var tabString: String {
        if useSpacesForTabs {
            return String(repeating: " ", count: tabSize)
        }
        return "\t"
    }
}
