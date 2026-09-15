import XCTest
@testable import Chau7

final class LaunchAtLoginManagerTests: XCTestCase {
    func testEnablingWritesLaunchAgentForNextLoginWithoutSessionLoad() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.home) }

        XCTAssertFalse(LaunchAtLoginManager.isEnabled(environment: fixture.environment))

        LaunchAtLoginManager.setEnabled(true, environment: fixture.environment)

        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.agentURL.path))
        XCTAssertTrue(LaunchAtLoginManager.isEnabled(environment: fixture.environment))

        let plist = try readAgentPlist(at: fixture.agentURL)
        XCTAssertEqual(plist["Label"] as? String, fixture.label)
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["KeepAlive"] as? Bool, false)
        XCTAssertEqual((plist["ProgramArguments"] as? [String])?.first, Bundle.main.executableURL?.path)
    }

    func testDisablingRemovesLaunchAgentPlist() throws {
        let fixture = try makeFixture()
        defer { remove(fixture.home) }

        LaunchAtLoginManager.setEnabled(true, environment: fixture.environment)
        LaunchAtLoginManager.setEnabled(false, environment: fixture.environment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agentURL.path))
        XCTAssertFalse(LaunchAtLoginManager.isEnabled(environment: fixture.environment))
    }

    func testIsolatedTestModeKeepsLaunchAtLoginInert() throws {
        let fixture = try makeFixture(isolated: true)
        defer { remove(fixture.home) }

        LaunchAtLoginManager.setEnabled(true, environment: fixture.environment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.agentURL.path))
        XCTAssertFalse(LaunchAtLoginManager.isEnabled(environment: fixture.environment))
    }

    private struct Fixture {
        var home: URL
        var label: String
        var agentURL: URL
        var environment: [String: String]
    }

    private func makeFixture(isolated: Bool = false) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchAtLoginManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let label = Bundle.main.bundleIdentifier ?? "com.chau7"
        let agentURL = home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
        return Fixture(
            home: home,
            label: label,
            agentURL: agentURL,
            environment: [
                "CHAU7_HOME_ROOT": home.path,
                "CHAU7_ISOLATED_TEST_MODE": isolated ? "1" : "0"
            ]
        )
    }

    private func readAgentPlist(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    private func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
