import XCTest
@testable import Chau7

final class AppSignalsTests: XCTestCase {

    /// A copy-pasted declaration must not silently alias another signal.
    func testSignalRawValuesAreUnique() {
        let rawValues = AppSignals.all.map(\.rawValue)
        XCTAssertEqual(
            rawValues.count, Set(rawValues).count,
            "duplicate Notification.Name raw values in the registry"
        )
    }

    /// Registry convention: every internal signal is namespaced.
    func testSignalsAreNamespaced() {
        for name in AppSignals.all {
            XCTAssertTrue(
                name.rawValue.hasPrefix("com.chau7."),
                "\(name.rawValue) is missing the com.chau7. namespace"
            )
        }
    }
}
