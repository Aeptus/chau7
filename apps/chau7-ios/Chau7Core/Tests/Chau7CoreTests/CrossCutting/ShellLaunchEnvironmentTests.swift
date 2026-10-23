import XCTest
@testable import Chau7Core

final class ShellLaunchEnvironmentTests: XCTestCase {

    func testUTF8LocaleEnvironmentDefaultsWhenMissing() {
        let result = ShellLaunchEnvironment.utf8LocaleEnvironment(environment: [:])

        XCTAssertEqual(result["LANG"], "en_US.UTF-8")
        XCTAssertEqual(result["LC_CTYPE"], "en_US.UTF-8")
        XCTAssertNil(result["LC_ALL"])
    }

    func testUTF8LocaleEnvironmentPreservesExistingUTF8Locales() {
        let result = ShellLaunchEnvironment.utf8LocaleEnvironment(environment: [
            "LANG": "fr_FR.UTF-8",
            "LC_CTYPE": "en_US.UTF8",
            "LC_ALL": "de_DE.UTF-8"
        ])

        XCTAssertEqual(result["LANG"], "fr_FR.UTF-8")
        XCTAssertEqual(result["LC_CTYPE"], "en_US.UTF8")
        XCTAssertEqual(result["LC_ALL"], "de_DE.UTF-8")
    }

    func testUTF8LocaleEnvironmentReplacesNonUTF8LocaleValuesWithoutOverridingLCAll() {
        let result = ShellLaunchEnvironment.utf8LocaleEnvironment(environment: [
            "LANG": "C",
            "LC_CTYPE": "POSIX",
            "LC_ALL": "C"
        ])

        XCTAssertEqual(result["LANG"], "en_US.UTF-8")
        XCTAssertEqual(result["LC_CTYPE"], "en_US.UTF-8")
        XCTAssertEqual(result["LC_ALL"], "C")
    }

    func testPreferredPATHPrependsCommonUserBins() {
        let environment = [
            "HOME": "/Users/tester",
            "PATH": "/usr/bin:/bin"
        ]

        let result = ShellLaunchEnvironment.preferredPATH(environment: environment)

        XCTAssertEqual(
            result,
            "/Users/tester/bin:/Users/tester/.local/bin:/Users/tester/.volta/bin:/Users/tester/.cargo/bin:/Users/tester/.bun/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin"
        )
    }

    func testPreferredPATHPutsCodexVoltaImageBinsBeforeVoltaShim() throws {
        let home = try makeTemporaryDirectory()
        let fileManager = FileManager.default
        let oldNodeBin = home.codexVoltaNodeBin("20.19.4")
        let currentNodeBin = home.codexVoltaNodeBin("25.7.0")
        let voltaShimBin = home
            .appendingPathComponent(".volta", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)

        try fileManager.createDirectory(at: oldNodeBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: currentNodeBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: voltaShimBin, withIntermediateDirectories: true)
        try writeExecutable(at: oldNodeBin.appendingPathComponent("codex"))
        try writeExecutable(at: currentNodeBin.appendingPathComponent("codex"))
        try writeExecutable(at: voltaShimBin.appendingPathComponent("codex"))

        let result = ShellLaunchEnvironment.preferredPATH(
            environment: [
                "HOME": home.path,
                "PATH": "\(voltaShimBin.path):/usr/bin:/bin"
            ],
            fileManager: fileManager
        )
        let entries = result
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).resolvingSymlinksInPath().path }
        let currentNodePath = currentNodeBin.resolvingSymlinksInPath().path
        let oldNodePath = oldNodeBin.resolvingSymlinksInPath().path
        let shimPath = voltaShimBin.resolvingSymlinksInPath().path

        let currentIndex = try XCTUnwrap(entries.firstIndex(of: currentNodePath))
        let oldIndex = try XCTUnwrap(entries.firstIndex(of: oldNodePath))
        let shimIndex = try XCTUnwrap(entries.firstIndex(of: shimPath))

        XCTAssertLessThan(currentIndex, shimIndex)
        XCTAssertLessThan(oldIndex, shimIndex)
        XCTAssertLessThan(currentIndex, oldIndex)
    }

    func testPreferredPATHFallsBackWhenPATHMissing() {
        let environment = [
            "HOME": "/Users/tester"
        ]

        let result = ShellLaunchEnvironment.preferredPATH(environment: environment)

        XCTAssertTrue(result.contains("/opt/homebrew/bin"))
        XCTAssertTrue(result.contains("/usr/bin"))
        XCTAssertTrue(result.contains("/Users/tester/.volta/bin"))
    }

    func testUserZdotdirPrefersExplicitEnvironment() {
        let environment = [
            "HOME": "/Users/tester",
            "ZDOTDIR": "/Users/tester/.config/zsh"
        ]

        XCTAssertEqual(
            ShellLaunchEnvironment.userZdotdir(environment: environment),
            "/Users/tester/.config/zsh"
        )
    }

    func testUserXDGConfigHomeFallsBackToHomeConfig() {
        let environment = [
            "HOME": "/Users/tester"
        ]

        XCTAssertEqual(
            ShellLaunchEnvironment.userXDGConfigHome(environment: environment),
            "/Users/tester/.config"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShellLaunchEnvironmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL) throws {
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private extension URL {
    func codexVoltaNodeBin(_ nodeVersion: String) -> URL {
        appendingPathComponent(".volta", isDirectory: true)
            .appendingPathComponent("tools", isDirectory: true)
            .appendingPathComponent("image", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent(nodeVersion, isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
    }
}
