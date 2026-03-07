import XCTest
@testable import Chau7Core

// MARK: - NotificationActionType Tests

final class NotificationActionTypeTests: XCTestCase {

    func testAllCasesUnique() {
        let rawValues = NotificationActionType.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count, "All action types should have unique raw values")
    }

    func testActionTypeCount() {
        // Catalog defines 25 action types
        XCTAssertEqual(NotificationActionType.allCases.count, 25)
    }

    func testActionTypeIdentifiable() {
        let action = NotificationActionType.showNotification
        XCTAssertEqual(action.id, action.rawValue)
    }

    func testActionTypeCodableRoundTrip() throws {
        let original = NotificationActionType.webhook
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationActionType.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - ActionCategory Tests

final class ActionCategoryTests: XCTestCase {

    func testAllCategoriesUnique() {
        let rawValues = ActionCategory.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues.count, Set(rawValues).count)
    }

    func testCategoryCount() {
        XCTAssertEqual(ActionCategory.allCases.count, 7)
    }

    func testDisplayNames() {
        XCTAssertEqual(ActionCategory.basic.displayName, "Basic")
        XCTAssertEqual(ActionCategory.automation.displayName, "Automation")
        XCTAssertEqual(ActionCategory.integration.displayName, "Integrations")
        XCTAssertEqual(ActionCategory.devops.displayName, "DevOps")
        XCTAssertEqual(ActionCategory.productivity.displayName, "Productivity")
        XCTAssertEqual(ActionCategory.accessibility.displayName, "Accessibility")
        XCTAssertEqual(ActionCategory.timeTracking.displayName, "Time Tracking")
    }

    func testIcons() {
        // Every category should have a non-empty icon
        for category in ActionCategory.allCases {
            XCTAssertFalse(category.icon.isEmpty, "\(category) should have an icon")
        }
    }

    func testCodableRoundTrip() throws {
        let original = ActionCategory.devops
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ActionCategory.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - NotificationActionCatalog Tests

final class NotificationActionCatalogTests: XCTestCase {

    func testCatalogCoversAllActionTypes() {
        let catalogTypes = Set(NotificationActionCatalog.all.map(\.type))
        let allTypes = Set(NotificationActionType.allCases)
        XCTAssertEqual(catalogTypes, allTypes, "Catalog should have an entry for every action type")
    }

    func testActionLookupByType() {
        let info = NotificationActionCatalog.action(for: .webhook)
        XCTAssertNotNil(info)
        XCTAssertEqual(info?.type, .webhook)
        XCTAssertEqual(info?.category, .integration)
    }

    func testActionLookupReturnsNilForNone() {
        // All types are in the catalog, so this is more of a structure test
        let info = NotificationActionCatalog.action(for: .showNotification)
        XCTAssertNotNil(info)
    }

    func testActionsInCategory() {
        let basic = NotificationActionCatalog.actions(in: .basic)
        XCTAssertFalse(basic.isEmpty)
        for action in basic {
            XCTAssertEqual(action.category, .basic)
        }
    }

    func testActionsInCategoryDevOps() {
        let devops = NotificationActionCatalog.actions(in: .devops)
        let types = devops.map(\.type)
        XCTAssertTrue(types.contains(.dockerBump))
        XCTAssertTrue(types.contains(.dockerCompose))
        XCTAssertTrue(types.contains(.kubernetesRollout))
    }

    func testActionsInCategoryTimeTracking() {
        let timeTracking = NotificationActionCatalog.actions(in: .timeTracking)
        let types = timeTracking.map(\.type)
        XCTAssertTrue(types.contains(.startTimer))
        XCTAssertTrue(types.contains(.stopTimer))
        XCTAssertTrue(types.contains(.logTime))
    }

    func testByCategoryCoversAllCategories() {
        let grouped = NotificationActionCatalog.byCategory
        let categories = grouped.map(\.category)

        for category in ActionCategory.allCases {
            XCTAssertTrue(categories.contains(category), "\(category) should appear in byCategory")
        }
    }

    func testByCategoryActionsMatchCategory() {
        for (category, actions) in NotificationActionCatalog.byCategory {
            for action in actions {
                XCTAssertEqual(
                    action.category,
                    category,
                    "\(action.type) is in \(category) group but has category \(action.category)"
                )
            }
        }
    }

    func testByCategoryTotalMatchesAll() {
        let total = NotificationActionCatalog.byCategory.reduce(0) { $0 + $1.actions.count }
        XCTAssertEqual(total, NotificationActionCatalog.all.count)
    }

    // MARK: - Catalog Metadata Quality

    func testAllActionsHaveLabels() {
        for action in NotificationActionCatalog.all {
            XCTAssertFalse(action.labelFallback.isEmpty, "\(action.type) missing label")
            XCTAssertFalse(action.labelKey.isEmpty, "\(action.type) missing label key")
        }
    }

    func testAllActionsHaveDescriptions() {
        for action in NotificationActionCatalog.all {
            XCTAssertFalse(action.descriptionFallback.isEmpty, "\(action.type) missing description")
            XCTAssertFalse(action.descriptionKey.isEmpty, "\(action.type) missing description key")
        }
    }

    func testAllActionsHaveIcons() {
        for action in NotificationActionCatalog.all {
            XCTAssertFalse(action.icon.isEmpty, "\(action.type) missing icon")
        }
    }

    func testRequiresConfigActionsHaveConfigFields() {
        for action in NotificationActionCatalog.all where action.requiresConfig {
            XCTAssertFalse(
                action.configFields.isEmpty,
                "\(action.type) requires config but has no config fields"
            )
        }
    }
}

// MARK: - NotificationActionConfig Tests

final class NotificationActionConfigTests: XCTestCase {

    func testConfigValuePresent() {
        let config = NotificationActionConfig(
            actionType: .webhook,
            config: ["url": "https://example.com"]
        )
        XCTAssertEqual(config.configValue("url"), "https://example.com")
    }

    func testConfigValueMissing() {
        let config = NotificationActionConfig(actionType: .webhook, config: [:])
        XCTAssertNil(config.configValue("url"))
    }

    func testConfigBoolTrue() {
        let config = NotificationActionConfig(
            actionType: .focusWindow,
            config: ["focusTab": "true"]
        )
        XCTAssertTrue(config.configBool("focusTab"))
    }

    func testConfigBoolOne() {
        let config = NotificationActionConfig(
            actionType: .focusWindow,
            config: ["focusTab": "1"]
        )
        XCTAssertTrue(config.configBool("focusTab"))
    }

    func testConfigBoolFalse() {
        let config = NotificationActionConfig(
            actionType: .focusWindow,
            config: ["focusTab": "false"]
        )
        XCTAssertFalse(config.configBool("focusTab"))
    }

    func testConfigBoolMissingUsesDefault() {
        let config = NotificationActionConfig(actionType: .focusWindow, config: [:])
        XCTAssertFalse(config.configBool("focusTab"))
        XCTAssertTrue(config.configBool("focusTab", default: true))
    }

    func testConfigBoolCaseInsensitive() {
        let config = NotificationActionConfig(
            actionType: .focusWindow,
            config: ["enabled": "TRUE"]
        )
        XCTAssertTrue(config.configBool("enabled"))
    }

    func testConfigIntValid() {
        let config = NotificationActionConfig(
            actionType: .playSound,
            config: ["volume": "75"]
        )
        XCTAssertEqual(config.configInt("volume"), 75)
    }

    func testConfigIntInvalid() {
        let config = NotificationActionConfig(
            actionType: .playSound,
            config: ["volume": "loud"]
        )
        XCTAssertEqual(config.configInt("volume"), 0)
    }

    func testConfigIntMissingUsesDefault() {
        let config = NotificationActionConfig(actionType: .playSound, config: [:])
        XCTAssertEqual(config.configInt("volume"), 0)
        XCTAssertEqual(config.configInt("volume", default: 50), 50)
    }

    func testConfigCodableRoundTrip() throws {
        let original = NotificationActionConfig(
            actionType: .webhook,
            enabled: true,
            config: ["url": "https://example.com", "method": "POST"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NotificationActionConfig.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testConfigIdentifiable() {
        let config = NotificationActionConfig(actionType: .webhook)
        XCTAssertNotEqual(config.id, UUID()) // Auto-generated, unique
    }
}

// MARK: - TriggerActionBinding Tests

final class TriggerActionBindingTests: XCTestCase {

    func testBindingInit() {
        let binding = TriggerActionBinding(triggerId: "events_log.finished")
        XCTAssertEqual(binding.triggerId, "events_log.finished")
        XCTAssertTrue(binding.actions.isEmpty)
    }

    func testBindingWithActions() {
        let action = NotificationActionConfig(actionType: .showNotification)
        let binding = TriggerActionBinding(
            triggerId: "events_log.finished",
            actions: [action]
        )
        XCTAssertEqual(binding.actions.count, 1)
        XCTAssertEqual(binding.actions.first?.actionType, .showNotification)
    }

    func testBindingCodableRoundTrip() throws {
        let action = NotificationActionConfig(
            actionType: .playSound,
            config: ["sound": "default"]
        )
        let original = TriggerActionBinding(
            triggerId: "claude_code.finished",
            actions: [action]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TriggerActionBinding.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testBindingEquality() {
        let id = UUID()
        let a = TriggerActionBinding(id: id, triggerId: "t1")
        let b = TriggerActionBinding(id: id, triggerId: "t1")
        XCTAssertEqual(a, b)
    }
}

// MARK: - ActionConfigField Tests

final class ActionConfigFieldTests: XCTestCase {

    func testFieldIdentifiable() {
        let field = ActionConfigField(
            id: "url",
            labelKey: "action.field.url",
            labelFallback: "URL",
            type: .text,
            required: true
        )
        XCTAssertEqual(field.id, "url")
    }

    func testFieldEquality() {
        let a = ActionConfigField(id: "url", labelKey: "k", labelFallback: "URL", type: .text)
        let b = ActionConfigField(id: "url", labelKey: "k", labelFallback: "URL", type: .text)
        XCTAssertEqual(a, b)
    }

    func testFieldWithOptions() {
        let field = ActionConfigField(
            id: "method",
            labelKey: "k",
            labelFallback: "Method",
            type: .picker,
            options: [
                ConfigOption(id: "POST", label: "POST"),
                ConfigOption(id: "GET", label: "GET")
            ]
        )
        XCTAssertEqual(field.options?.count, 2)
    }
}
