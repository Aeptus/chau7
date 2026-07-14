import XCTest
@testable import Chau7

final class SettingsSurfaceTests: XCTestCase {
    func testEverySectionAppearsInExactlyOneSidebarGroup() {
        let groupedSections = SettingsSectionGroup.allCases.flatMap(\.sections)
        XCTAssertEqual(Set(groupedSections), Set(SettingsSection.allCases))

        let duplicates = Dictionary(grouping: groupedSections, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
        XCTAssertTrue(duplicates.isEmpty, "Duplicate settings sections in sidebar groups: \(duplicates)")
    }

    func testEverySectionHasSearchMetadata() {
        let searchableSections = Set(FeatureSettings.searchableSettings.map(\.section))
        let missing = Set(SettingsSection.allCases).subtracting(searchableSections)
        XCTAssertTrue(missing.isEmpty, "Settings sections missing searchable metadata: \(missing)")
    }

    func testSearchableSettingIDsAreUnique() {
        let groupedIDs = Dictionary(grouping: FeatureSettings.searchableSettings.map(\.id), by: { $0 })
        let duplicates = groupedIDs.filter { $0.value.count > 1 }.keys
        XCTAssertTrue(duplicates.isEmpty, "Duplicate searchable setting IDs: \(duplicates)")
    }

    func testSearchableSettingsExposeStableAnchors() {
        let settingsByID = Dictionary(uniqueKeysWithValues: FeatureSettings.searchableSettings.map { ($0.id, $0) })

        XCTAssertEqual(settingsByID["launch"]?.anchorID, "launch")
        XCTAssertEqual(settingsByID["triggerActions"]?.anchorID, "notificationTriggers")

        let emptyAnchors = FeatureSettings.searchableSettings
            .filter { $0.anchorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map(\.id)
        XCTAssertTrue(emptyAnchors.isEmpty, "Searchable settings with empty anchors: \(emptyAnchors)")
    }

    func testSearchAnchorTitleResolutionIsSectionScoped() {
        XCTAssertEqual(
            FeatureSettings.searchAnchorID(forTitle: "Launch at Login", in: .general),
            "launch"
        )
        XCTAssertEqual(
            FeatureSettings.searchAnchorID(forTitle: "Remote Access", in: .remoteControl),
            "remote"
        )
        XCTAssertNil(
            FeatureSettings.searchAnchorID(forTitle: "Remote Access", in: .general),
            "Title-based anchor resolution should not cross settings sections."
        )
    }

    func testAdvancedDisclosureExpansionIsDrivenByChildSearchAnchors() {
        let hiddenAnchors: Set<String> = ["ctoPerTab", "proxyInternals"]

        XCTAssertTrue(settingsAdvancedDisclosureShouldExpand(
            highlightedAnchorID: "ctoPerTab",
            searchAnchorIDs: hiddenAnchors
        ))
        XCTAssertFalse(settingsAdvancedDisclosureShouldExpand(
            highlightedAnchorID: "launch",
            searchAnchorIDs: hiddenAnchors
        ))
        XCTAssertFalse(settingsAdvancedDisclosureShouldExpand(
            highlightedAnchorID: nil,
            searchAnchorIDs: hiddenAnchors
        ))
    }

    func testEverySectionHasPageSummaryItems() {
        for section in SettingsSection.allCases {
            XCTAssertGreaterThan(
                settingsPageSummaryMinimumItemCount(for: section),
                0,
                "\(section) is missing a page summary."
            )
        }
    }

    func testWindowsSectionIsAppearanceAndSearchable() {
        XCTAssertEqual(SettingsSection.windows.group, .appearance)
        XCTAssertTrue(SettingsSectionGroup.appearance.sections.contains(.windows))

        let windowsResults = FeatureSettings.searchSettings(query: "floating")
        XCTAssertTrue(windowsResults.contains { result in
            result.section == .windows && result.settings.contains { $0.id == "windowFloating" }
        })
    }

    func testStartHereIsFirstAndSearchable() {
        XCTAssertEqual(SettingsSection.allCases.first, .startHere)
        XCTAssertEqual(SettingsSectionGroup.general.sections.first, .startHere)

        let startHereResults = FeatureSettings.searchSettings(query: "overview")
        XCTAssertTrue(startHereResults.contains { result in
            result.section == .startHere && result.settings.contains { $0.id == "startHereStatus" }
        })
    }

    func testSettingsGroupsAreGoalOriented() {
        XCTAssertEqual(
            SettingsSectionGroup.allCases,
            [.general, .appearance, .terminal, .aiWorkflows, .automation, .safetyPrivacy]
        )
        XCTAssertEqual(SettingsSection.repositories.group, .automation)
        XCTAssertEqual(SettingsSection.remoteControl.group, .automation)
        XCTAssertEqual(SettingsSection.sshProfiles.group, .automation)
        XCTAssertEqual(SettingsSection.dangerousCommands.group, .safetyPrivacy)
        XCTAssertEqual(SettingsSection.notifications.group, .safetyPrivacy)
        XCTAssertEqual(SettingsSection.history.group, .safetyPrivacy)
        XCTAssertEqual(SettingsSection.logsHistory.group, .safetyPrivacy)
    }

    func testTechnicalSettingSectionsUseHumanTitles() {
        XCTAssertEqual(SettingsSection.tokenOptimization.title, "Context Optimization")
        XCTAssertEqual(SettingsSection.mcpControl.title, "Agent Control")
        XCTAssertEqual(SettingsSection.promptInjection.title, "AI Context")
        XCTAssertEqual(SettingsSection.apiProxy.title, "API Tracking")
        XCTAssertEqual(SettingsSection.scrollbackPerf.title, "Performance")
        XCTAssertEqual(SettingsSection.dangerousCommands.title, "Command Safety")
        XCTAssertEqual(SettingsSection.remoteControl.title, "Remote Access")
        XCTAssertEqual(SettingsSection.notifications.title, "Alerts")
        XCTAssertEqual(SettingsSection.logsHistory.title, "Diagnostics")

        let settingsByID = Dictionary(uniqueKeysWithValues: FeatureSettings.searchableSettings.map { ($0.id, $0) })
        XCTAssertEqual(settingsByID["promptInjection"]?.title, "AI Context")
        XCTAssertEqual(settingsByID["apiAnalytics"]?.title, "API Tracking")
        XCTAssertEqual(settingsByID["dangerousCommands"]?.title, "Command Safety")
        XCTAssertEqual(settingsByID["mcpServer"]?.title, "Agent Server")
    }

    func testOverloadedSettingsPagesAreSplitByTask() {
        XCTAssertTrue(SettingsSectionGroup.automation.sections.contains(.remoteControl))
        XCTAssertTrue(SettingsSectionGroup.automation.sections.contains(.sshProfiles))
        XCTAssertTrue(SettingsSectionGroup.safetyPrivacy.sections.contains(.history))
        XCTAssertTrue(SettingsSectionGroup.safetyPrivacy.sections.contains(.logsHistory))

        let settingsByID = Dictionary(uniqueKeysWithValues: FeatureSettings.searchableSettings.map { ($0.id, $0) })
        XCTAssertEqual(settingsByID["remote"]?.section, .remoteControl)
        XCTAssertEqual(settingsByID["sshProfiles"]?.section, .sshProfiles)
        XCTAssertEqual(settingsByID["persistentHistory"]?.section, .history)
        XCTAssertEqual(settingsByID["telemetryRetention"]?.section, .history)
        XCTAssertEqual(settingsByID["historyLogs"]?.section, .logsHistory)
        XCTAssertEqual(settingsByID["terminalLogs"]?.section, .logsHistory)
        XCTAssertEqual(settingsByID["debugConsole"]?.section, .logsHistory)
    }
}
