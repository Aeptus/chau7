import Foundation
import Observation

// MARK: - Settings Navigation

@MainActor
@Observable
final class SettingsNavigationModel {
    var selection: SettingsSection
    var searchQuery: String
    var anchorID: String?

    init(
        selection: SettingsSection = .startHere,
        searchQuery: String = "",
        anchorID: String? = nil
    ) {
        self.selection = selection
        self.searchQuery = searchQuery
        self.anchorID = anchorID
    }

    func show(section: SettingsSection? = nil, anchorID: String? = nil) {
        let resolvedAnchorID = Self.normalized(anchorID)
        selection = section ?? Self.section(containingAnchorID: resolvedAnchorID) ?? .startHere
        searchQuery = ""
        self.anchorID = resolvedAnchorID
    }

    func updateSearchQuery(_ query: String, firstMatchingSection: SettingsSection?) {
        searchQuery = query

        guard !query.isEmpty else {
            anchorID = nil
            return
        }

        if let firstMatchingSection {
            selection = firstMatchingSection
        }
        anchorID = nil
    }

    func focusSearchResult(_ setting: SearchableSetting) {
        selection = setting.section
        anchorID = setting.anchorID
    }

    func clearAnchor() {
        anchorID = nil
    }

    static func section(containingAnchorID anchorID: String?) -> SettingsSection? {
        guard let anchorID = normalized(anchorID) else { return nil }
        return FeatureSettings.searchableSettings.first {
            $0.anchorID == anchorID || $0.id == anchorID
        }?.section
    }

    static func normalized(_ anchorID: String?) -> String? {
        let trimmed = anchorID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
