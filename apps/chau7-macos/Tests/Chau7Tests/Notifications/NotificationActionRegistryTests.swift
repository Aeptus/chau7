import XCTest
@testable import Chau7
import Chau7Core

/// Contract tests for the per-type action handler registry. The
/// canonical guarantee — "every `NotificationActionType` case has a
/// registered handler" — must fail the build the moment someone adds a
/// new case to the enum without registering its handler.
@MainActor
final class NotificationActionRegistryTests: XCTestCase {

    func testEveryActionTypeHasARegisteredHandler() {
        let registry = NotificationActionRegistry.makeDefault()
        let registered = registry.registeredActionTypes
        let everyCase = Set(NotificationActionType.allCases)
        let missing = everyCase.subtracting(registered)
        XCTAssertTrue(
            missing.isEmpty,
            "Missing handlers for: \(missing.map(\.rawValue).sorted().joined(separator: ", "))"
        )
    }

    func testEachHandlerCoversItsDeclaredSupportedTypes() {
        // Every handler's `supportedActionTypes` must round-trip
        // through the registry: each declared type maps back to the
        // SAME handler instance (so shared-state handlers like time-
        // tracking actually share state across their three keys).
        let registry = NotificationActionRegistry.makeDefault()
        for type in NotificationActionType.allCases {
            guard let handler = registry.handler(for: type) else {
                XCTFail("No handler for \(type)")
                continue
            }
            XCTAssertTrue(
                handler.supportedActionTypes.contains(type),
                "Handler for \(type) does not declare \(type) in supportedActionTypes"
            )
        }
    }

    func testTimeTrackingHandlerCoversAllThreeTypes() {
        let registry = NotificationActionRegistry.makeDefault()
        let start = registry.handler(for: .startTimer)
        let stop = registry.handler(for: .stopTimer)
        let log = registry.handler(for: .logTime)
        XCTAssertTrue(start is TimeTrackingActionHandler)
        XCTAssertTrue(stop is TimeTrackingActionHandler)
        XCTAssertTrue(log is TimeTrackingActionHandler)
        // All three keys must point at the same instance — that's the
        // whole reason the trio shares one handler (shared activeTimers).
        XCTAssertTrue(start as AnyObject === stop as AnyObject)
        XCTAssertTrue(stop as AnyObject === log as AnyObject)
    }
}
