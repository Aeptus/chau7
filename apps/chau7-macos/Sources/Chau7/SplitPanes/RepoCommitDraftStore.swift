import Foundation

/// Owns the per-directory commit-message draft persistence + the
/// conventional-commit prefix policy. Extracted from `RepositoryPaneModel`
/// so the UserDefaults round-trip and the prefix detection/application
/// rules have their own home and stop bleeding into the 1000-line model.
///
/// The store is intentionally a value type — it's cheap to construct fresh
/// per call (or per directory change). The model still owns the
/// observable `commitMessage` so SwiftUI binds against it directly; the
/// store provides the load/save/clear primitives and the pure prefix
/// helpers.
struct RepoCommitDraftStore {
    /// Canonical conventional-commit prefixes the prefix chips in the
    /// commit composer expose.
    static let prefixes = ["feat", "fix", "docs", "style", "refactor", "test", "chore"]

    /// UserDefaults key prefix used when persisting draft messages per repo
    /// directory. Exposed at internal access for the load-on-restore path.
    static let userDefaultsKeyPrefix = "repoPaneDraft."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Reads the persisted draft for `directory`, or an empty string when
    /// nothing has been saved. The empty-string default matches the
    /// commit composer's initial state.
    func loadDraft(for directory: String) -> String {
        defaults.string(forKey: Self.key(for: directory)) ?? ""
    }

    /// Persists `message` for `directory`. Whitespace-only drafts are
    /// removed from defaults so an empty composer doesn't leave litter.
    func saveDraft(_ message: String, for directory: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.key(for: directory))
        } else {
            defaults.set(message, forKey: Self.key(for: directory))
        }
    }

    /// Drops the persisted draft for `directory`. Called after a successful
    /// commit so the composer reopens clean next time.
    func clearDraft(for directory: String) {
        defaults.removeObject(forKey: Self.key(for: directory))
    }

    /// Applies a conventional-commit `prefix` to `message`, returning the
    /// new message. No-ops when `message` already starts with the prefix
    /// (either `feat:` or `feat(scope)` form).
    func applyPrefix(_ prefix: String, to message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(prefix + ":") || trimmed.hasPrefix(prefix + "(") {
            return message
        }
        return prefix + ": " + trimmed
    }

    /// True when `message` already starts with a conventional-commit prefix
    /// from `prefixes`. Case-insensitive so user typing variants still match.
    func hasConventionalPrefix(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespaces).lowercased()
        return Self.prefixes.contains {
            trimmed.hasPrefix($0 + ":") || trimmed.hasPrefix($0 + "(")
        }
    }

    private static func key(for directory: String) -> String {
        userDefaultsKeyPrefix + directory
    }
}
