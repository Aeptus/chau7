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
        XCTAssertEqual(SettingsSection.dangerousCommands.group, .safetyPrivacy)
        XCTAssertEqual(SettingsSection.notifications.group, .safetyPrivacy)
    }

    func testTechnicalSettingSectionsUseHumanTitles() {
        XCTAssertEqual(SettingsSection.tokenOptimization.title, "Context Optimization")
        XCTAssertEqual(SettingsSection.mcpControl.title, "Agent Control")
        XCTAssertEqual(SettingsSection.promptInjection.title, "AI Context")
        XCTAssertEqual(SettingsSection.apiProxy.title, "API Tracking")
        XCTAssertEqual(SettingsSection.scrollbackPerf.title, "Performance")
        XCTAssertEqual(SettingsSection.dangerousCommands.title, "Command Safety")

        let settingsByID = Dictionary(uniqueKeysWithValues: FeatureSettings.searchableSettings.map { ($0.id, $0) })
        XCTAssertEqual(settingsByID["promptInjection"]?.title, "AI Context")
        XCTAssertEqual(settingsByID["apiAnalytics"]?.title, "API Tracking")
        XCTAssertEqual(settingsByID["dangerousCommands"]?.title, "Command Safety")
        XCTAssertEqual(settingsByID["mcpServer"]?.title, "Agent Server")
    }
}
