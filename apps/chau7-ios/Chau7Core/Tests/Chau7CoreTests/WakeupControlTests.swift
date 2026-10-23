import XCTest
@testable import Chau7Core

final class WakeupControlTests: XCTestCase {
    func testUsesDefaultWhenUnset() {
        XCTAssertTrue(WakeupControl.isEnabled(.instrumentationEnabled, environment: [:]))
        XCTAssertTrue(WakeupControl.isEnabled(.asyncDebugAnalyticsRefresh, environment: [:]))
        XCTAssertTrue(WakeupControl.isEnabled(.lowPowerDangerousHighlights, environment: [:]))
    }

    func testParsesFalseVariants() {
        XCTAssertFalse(WakeupControl.isEnabled(.instrumentationEnabled, environment: [
            WakeupSwitch.instrumentationEnabled.rawValue: "0"
        ]))
        XCTAssertFalse(WakeupControl.isEnabled(.asyncDebugAnalyticsRefresh, environment: [
            WakeupSwitch.asyncDebugAnalyticsRefresh.rawValue: "false"
        ]))
        XCTAssertFalse(WakeupControl.isEnabled(.lowPowerDangerousHighlights, environment: [
            WakeupSwitch.lowPowerDangerousHighlights.rawValue: "off"
        ]))
    }

    func testParsesTrueVariants() {
        XCTAssertTrue(WakeupControl.isEnabled(.instrumentationEnabled, environment: [
            WakeupSwitch.instrumentationEnabled.rawValue: "1"
        ]))
        XCTAssertTrue(WakeupControl.isEnabled(.asyncDebugAnalyticsRefresh, environment: [
            WakeupSwitch.asyncDebugAnalyticsRefresh.rawValue: "yes"
        ]))
        XCTAssertTrue(WakeupControl.isEnabled(.lowPowerDangerousHighlights, environment: [
            WakeupSwitch.lowPowerDangerousHighlights.rawValue: "ON"
        ]))
    }

    func testFallsBackToDefaultForUnknownValues() {
        XCTAssertTrue(WakeupControl.isEnabled(.instrumentationEnabled, environment: [
            WakeupSwitch.instrumentationEnabled.rawValue: "unexpected"
        ]))
    }
}
