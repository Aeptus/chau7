import Foundation
import Chau7Core

/// Manages automatic profile switching based on context rules.
/// Evaluates `ProfileSwitchRule` conditions against the current terminal context
/// (directory, SSH host, running processes, environment variables) and
/// switches the active settings profile when a match is found.
@MainActor
@Observable
final class ProfileAutoSwitcher {
    static let shared = ProfileAutoSwitcher()

    private(set) var isActive = false
    private(set) var currentMatchedRule: ProfileSwitchRule?

    /// The profile name that was active before auto-switching
    private var previousProfileName: String?

    /// Rules to evaluate (loaded from UserDefaults)
    private(set) var rules: [ProfileSwitchRule] = []

    /// Whether auto-switching is enabled globally
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.autoSwitchEnabled)
            if !isEnabled { restorePreviousProfile() }
            Log.info("ProfileAutoSwitcher: enabled=\(isEnabled)")
        }
    }

    private enum Keys {
        static let autoSwitchEnabled = "feature.profileAutoSwitch"
        static let autoSwitchRules = "feature.profileSwitchRules"
    }

    init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Keys.autoSwitchEnabled)
        loadRules()
    }

    /// Testable initializer
    init(isEnabled: Bool, rules: [ProfileSwitchRule]) {
        self.isEnabled = isEnabled
        self.rules = rules
    }

    // MARK: - Rule Management

    func loadRules() {
        guard let data = UserDefaults.standard.data(forKey: Keys.autoSwitchRules) else {
            rules = []
            return
        }
        rules = (try? JSONDecoder().decode([ProfileSwitchRule].self, from: data)) ?? []
        Log.info("ProfileAutoSwitcher: loaded \(rules.count) rules")
    }

    func saveRules() {
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: Keys.autoSwitchRules)
        }
        Log.info("ProfileAutoSwitcher: saved \(rules.count) rules")
    }

    func addRule(_ rule: ProfileSwitchRule) {
        rules.append(rule)
        saveRules()
    }

    func updateRule(_ rule: ProfileSwitchRule) {
        if let idx = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[idx] = rule
            saveRules()
        }
    }

    func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        saveRules()
    }

    // MARK: - Evaluation

    /// Evaluate all rules against the current context and switch profile if a match is found.
    /// Called when directory changes, SSH connections change, etc.
    func evaluateRules(
        directory: String? = nil,
        gitBranch: String? = nil,
        sshHost: String? = nil,
        processes: [String]? = nil,
        environment: [String: String]? = nil
    ) {
        guard isEnabled else { return }

        let sortedRules = rules.sortedByPriority()

        for rule in sortedRules {
            if rule.matches(
                directory: directory,
                gitBranch: gitBranch,
                sshHost: sshHost,
                processes: processes,
                environment: environment
            ) {
                applyRule(rule)
                return
            }
        }

        // No rule matched — restore previous profile if we had auto-switched
        if currentMatchedRule != nil {
            restorePreviousProfile()
        }
    }

    /// Apply a matching rule by switching to its target profile.
    private func applyRule(_ rule: ProfileSwitchRule) {
        // Skip if already on this rule
        if currentMatchedRule?.id == rule.id { return }

        let settings = FeatureSettings.shared
        let profiles = settings.savedProfiles

        guard let targetProfile = profiles.first(where: { $0.name == rule.profileName }) else {
            Log.warn("ProfileAutoSwitcher: profile '\(rule.profileName)' not found for rule '\(rule.name)'")
            return
        }

        // Save current profile name before switching (only on first auto-switch)
        if currentMatchedRule == nil {
            previousProfileName = settings.activeProfile?.name
        }

        settings.loadProfile(targetProfile)
        currentMatchedRule = rule
        isActive = true
        Log.info("ProfileAutoSwitcher: switched to '\(rule.profileName)' (rule: '\(rule.name)')")
    }

    /// Restore the profile that was active before auto-switching.
    func restorePreviousProfile() {
        guard let previousName = previousProfileName else {
            currentMatchedRule = nil
            isActive = false
            return
        }

        let settings = FeatureSettings.shared
        if let previousProfile = settings.savedProfiles.first(where: { $0.name == previousName }) {
            settings.loadProfile(previousProfile)
            Log.info("ProfileAutoSwitcher: restored previous profile '\(previousName)'")
        }

        currentMatchedRule = nil
        previousProfileName = nil
        isActive = false
    }
}
