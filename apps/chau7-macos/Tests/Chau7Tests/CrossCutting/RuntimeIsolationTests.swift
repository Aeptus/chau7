import XCTest
@testable import Chau7Core

final class RuntimeIsolationTests: XCTestCase {
    func testHomeDirectoryUsesOverrideWhenConfigured() {
        let url = RuntimeIsolation.homeDirectory(environment: [
            "CHAU7_HOME_ROOT": "/tmp/chau7-isolated-home"
        ])

        XCTAssertEqual(url.path, "/tmp/chau7-isolated-home")
    }

    func testApplicationSupportDirectoryUsesOverrideRoot() {
        let url = RuntimeIsolation.applicationSupportDirectory(environment: [
            "CHAU7_HOME_ROOT": "/tmp/chau7-isolated-home"
        ])

        XCTAssertEqual(url.path, "/tmp/chau7-isolated-home/Library/Application Support")
    }

    func testChau7DirectoryUsesOverrideRoot() {
        let url = RuntimeIsolation.chau7Directory(environment: [
            "CHAU7_HOME_ROOT": "/tmp/chau7-isolated-home"
        ])

        XCTAssertEqual(url.path, "/tmp/chau7-isolated-home/.chau7")
    }

    func testExpandTildeUsesOverrideRoot() {
        let path = RuntimeIsolation.expandTilde(
            in: "~/project",
            environment: ["CHAU7_HOME_ROOT": "/tmp/chau7-isolated-home"]
        )

        XCTAssertEqual(path, "/tmp/chau7-isolated-home/project")
    }

    func testIsolatedTestModeRecognizesTrueValues() {
        XCTAssertTrue(RuntimeIsolation.isIsolatedTestMode(environment: [
            "CHAU7_ISOLATED_TEST_MODE": "1"
        ]))
        XCTAssertTrue(RuntimeIsolation.isIsolatedTestMode(environment: [
            "CHAU7_ISOLATED_TEST_MODE": "true"
        ]))
        XCTAssertFalse(RuntimeIsolation.isIsolatedTestMode(environment: [:]))
    }
}
