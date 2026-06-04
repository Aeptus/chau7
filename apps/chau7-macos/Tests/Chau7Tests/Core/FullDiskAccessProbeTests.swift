import XCTest
@testable import Chau7Core

final class FullDiskAccessProbeTests: XCTestCase {
    private func evaluate(_ results: [String: FullDiskAccessProbe.AccessResult],
                          canaries: [String]) -> FullDiskAccessProbe.Status {
        FullDiskAccessProbe.evaluate(home: "/Users/test", canaries: canaries) { path in
            // path is "/Users/test/<relative>"; key the map by the relative tail.
            let relative = String(path.dropFirst("/Users/test/".count))
            return results[relative] ?? .missing
        }
    }

    func testReadableCanaryMeansGranted() {
        let status = evaluate(["a": .ok, "b": .denied], canaries: ["a", "b"])
        XCTAssertEqual(status, .granted)
    }

    func testReadableCanaryWinsRegardlessOfOrder() {
        // A denial seen before a readable canary must not produce .denied.
        let status = evaluate(["a": .denied, "b": .ok], canaries: ["a", "b"])
        XCTAssertEqual(status, .granted)
    }

    func testPermissionErrorMeansDenied() {
        let status = evaluate(["a": .missing, "b": .denied], canaries: ["a", "b"])
        XCTAssertEqual(status, .denied)
    }

    func testAllMissingIsIndeterminate() {
        let status = evaluate(["a": .missing, "b": .missing], canaries: ["a", "b"])
        XCTAssertEqual(status, .indeterminate)
    }

    func testOtherErrorsDoNotFalseAlarm() {
        // Transient/unknown errors must never be reported as denied.
        let status = evaluate(["a": .otherError, "b": .otherError], canaries: ["a", "b"])
        XCTAssertEqual(status, .indeterminate)
    }

    func testHomeWithTrailingSlashJoinsCleanly() {
        var seen: String?
        _ = FullDiskAccessProbe.evaluate(home: "/Users/test/", canaries: ["Library/x"]) { path in
            seen = path
            return .ok
        }
        XCTAssertEqual(seen, "/Users/test/Library/x")
    }

    func testPosixAccessorClassifiesRealPaths() {
        XCTAssertEqual(FullDiskAccessProbe.posixAccessor("/etc/hosts"), .ok)
        XCTAssertEqual(
            FullDiskAccessProbe.posixAccessor("/nonexistent-\(UUID().uuidString)"),
            .missing
        )
    }
}
