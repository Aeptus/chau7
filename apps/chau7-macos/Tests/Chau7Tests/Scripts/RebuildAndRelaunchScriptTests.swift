import XCTest
import Chau7Core

final class RebuildAndRelaunchScriptTests: XCTestCase {
    func testBundleVerificationAcceptsMatchingGoBuildRevision() throws {
        let result = try verifyFixture(helperRevision: "abcdef1234567890abcdef1234567890abcdef1234")
        XCTAssertEqual(result.status, 0, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("helper revision abcdef1234567890abcdef1234567890abcdef1234"))
    }

    func testBundleVerificationRejectsMismatchedGoBuildRevision() throws {
        let result = try verifyFixture(helperRevision: "0000000000000000000000000000000000000000")
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }

    func testBundleVerificationRejectsMissingGoBuildRevision() throws {
        let result = try verifyFixture(helperRevision: nil)
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }

    func testBundleVerificationRejectsMissingAppRevision() throws {
        let result = try verifyFixture(appRevision: nil)
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }

    func testBundleVerificationRejectsMissingBundleIdentifier() throws {
        let result = try verifyFixture(bundleIdentifier: nil)
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }

    func testBundleVerificationRejectsFailedGoInspectionEvenWithPartialMetadata() throws {
        let result = try verifyFixture(goExitStatus: 1)
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }

    func testBundleVerificationRejectsFailedSignature() throws {
        let result = try verifyFixture(codesignExitStatus: 1)
        XCTAssertNotEqual(result.status, 0, result.stdout)
    }

    /// Runs the real verification functions against an isolated fixture. No
    /// production build, signing, quit, installation, or launch can occur here.
    private func verifyFixture(
        bundleIdentifier: String? = "com.chau7.app",
        appRevision: String? = "abcdef123456",
        helperRevision: String? = "abcdef1234567890abcdef1234567890abcdef1234",
        goExitStatus: Int = 0,
        codesignExitStatus: Int = 0
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Chau7.app")
        let bin = directory.appendingPathComponent("bin")
        for path in ["Contents/MacOS", "Contents/Resources"] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        var plist: [String: String] = [:]
        plist["CFBundleIdentifier"] = bundleIdentifier
        plist["Chau7BuildGitSHA"] = appRevision
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let goOutput = helperRevision.map { "    build   vcs.revision=\($0)" } ?? "    build   GOOS=darwin"
        let executables: [(URL, String)] = [
            (app.appendingPathComponent("Contents/MacOS/Chau7"), "#!/bin/sh\nexit 0\n"),
            (app.appendingPathComponent("Contents/Resources/chau7-remote"), "#!/bin/sh\nexit 0\n"),
            (bin.appendingPathComponent("go"), "#!/bin/sh\nprintf '%s\\n' '\(goOutput)'\nexit \(goExitStatus)\n"),
            (bin.appendingPathComponent("codesign"), "#!/bin/sh\nexit \(codesignExitStatus)\n")
        ]
        for (url, source) in executables {
            try source.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("Scripts/rebuild-and-relaunch.sh"), encoding: .utf8)
        let start = try XCTUnwrap(script.range(of: "\nplist_value() {"))
        let end = try XCTUnwrap(script.range(of: "\nbuild_release_bundle() {"))
        let functions = String(script[start.lowerBound ..< end.lowerBound])
        return try run(
            "/bin/bash",
            ["-c", """
            set -euo pipefail
            APP_NAME=Chau7
            log_error() { echo "$*" >&2; }
            log_step() { :; }
            log_ok() { echo "$*"; }
            \(functions)
            if verify_bundle "$1" abcdef123456; then exit 0; else exit 1; fi
            """, "fixture", app.path],
            environment: ["PATH": "\(bin.path):/usr/bin:/bin"]
        )
    }

    func testDryRunDoesNotAttemptToQuitOrBuild() throws {
        let tempHome = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempHome) }
        let logDirectory = tempHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let result = try run(
            "/bin/bash",
            [
                repositoryRoot()
                    .appendingPathComponent("Scripts/rebuild-and-relaunch.sh").path,
                "--dry-run",
                "--allow-dirty",
                "--quit-only"
            ],
            environment: [
                "HOME": tempHome.path,
                "PATH": "/usr/bin:/bin",
                "CHAU7_LOG_DIR": logDirectory.path,
                "CHAU7_LOG_COLOR": "0"
            ]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertTrue(result.stdout.contains("Dry run: would request a graceful quit"))
        XCTAssertFalse(result.stdout.contains("Requesting a graceful quit for Chau7"))
        XCTAssertFalse(result.stdout.contains("Building Chau7"))
    }

    func testWorkflowGuardsBundleProvenanceAndUsesAtomicReplacement() throws {
        let script = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Scripts/rebuild-and-relaunch.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("APP_OUTPUT_DIR=\"$dev_output\""))
        XCTAssertTrue(script.contains("process_name == \"Chau7\""))
        XCTAssertTrue(script.contains("verify_bundle \"$RELEASE_DIR/$APP_NAME.app\""))
        XCTAssertTrue(script.contains("mv \"$INSTALL_STAGING_DIR/$APP_NAME.app\" \"$DST_APP\""))
        XCTAssertTrue(script.contains("--install-path must point to a Chau7.app bundle"))
        XCTAssertTrue(script.contains("Refusing to install an older build"))
        XCTAssertTrue(script.contains("Refusing SIGTERM and SIGKILL to protect session data"))

        // A timed-out AppleScript quit must fail before any POSIX signal is
        // sent. SIGTERM has no Chau7 handler and can bypass
        // applicationWillTerminate, which is the final durable restore save.
        let forceGuard = try XCTUnwrap(script.range(of: #"if [[ "$FORCE_QUIT" != "1" ]]; then"#))
        let termEscalation = try XCTUnwrap(script.range(of: "send_signal_to_chau7 TERM"))
        XCTAssertLessThan(
            forceGuard.lowerBound,
            termEscalation.lowerBound,
            "SIGTERM must remain behind the explicit --force guard"
        )
    }

    func testLegacyInstallerDelegatesToGuardedWorkflow() throws {
        let script = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Scripts/install-launchpad-app.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("rebuild-and-relaunch.sh"))
        XCTAssertTrue(script.contains("--no-launch"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RebuildAndRelaunchScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, stdout: String, stderr: String) {
        let result = try XCTUnwrap(SubprocessRunner.capture(
            executablePath: executable, arguments: arguments, environment: environment, timeout: 10
        ))
        XCTAssertTrue(result.completed, "Script must complete without timeout or truncated output")
        return (
            result.status ?? -1,
            String(decoding: result.stdout, as: UTF8.self),
            String(decoding: result.stderr, as: UTF8.self)
        )
    }
}
