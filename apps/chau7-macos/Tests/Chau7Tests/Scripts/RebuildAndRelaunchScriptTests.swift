import XCTest

final class RebuildAndRelaunchScriptTests: XCTestCase {
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
        XCTAssertTrue(script.contains("Refusing SIGKILL to protect session data"))
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr)
    }
}
