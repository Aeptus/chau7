import XCTest
@testable import Chau7Core

final class TabStateBackupNamespaceTests: XCTestCase {
    func testProductionBundleUsesStableLegacyDirectory() {
        XCTAssertEqual(
            TabStateBackupNamespace.directoryName(bundleIdentifier: "com.chau7.app"),
            "TabStateBackups"
        )
    }

    func testDevBundleUsesSeparateDirectory() {
        XCTAssertEqual(
            TabStateBackupNamespace.directoryName(bundleIdentifier: "com.chau7.app.dev"),
            "TabStateBackups-com.chau7.app.dev"
        )
    }

    func testMissingBundleIdentifierDoesNotUseProductionBackups() {
        XCTAssertEqual(
            TabStateBackupNamespace.directoryName(bundleIdentifier: nil),
            "TabStateBackups-unidentified-bundle"
        )
        XCTAssertEqual(
            TabStateBackupNamespace.directoryName(bundleIdentifier: " "),
            "TabStateBackups-unidentified-bundle"
        )
    }

    func testBundleIdentifierSuffixIsPathSafe() {
        XCTAssertEqual(
            TabStateBackupNamespace.directoryName(bundleIdentifier: "com.chau7.app/dev beta"),
            "TabStateBackups-com.chau7.app-dev-beta"
        )
    }
}
