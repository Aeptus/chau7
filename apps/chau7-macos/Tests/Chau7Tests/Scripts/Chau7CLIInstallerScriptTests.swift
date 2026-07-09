import XCTest

final class Chau7CLIInstallerScriptTests: XCTestCase {
    func testInstallerCreatesChau7WrapperForChau7CLI() throws {
        let tempRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let productBin = tempRoot.appendingPathComponent("fake-chau7-cli")
        let installDir = tempRoot.appendingPathComponent("bin", isDirectory: true)
        try writeExecutable(
            at: productBin,
            body: "printf 'fake chau7-cli:%s\\n' \"$*\"\n"
        )

        let script = repositoryRoot()
            .appendingPathComponent("Scripts/install-chau7-cli.sh")
        let install = try run(
            "/bin/bash",
            [script.path],
            environment: [
                "HOME": tempRoot.path,
                "PATH": "\(installDir.path):/usr/bin:/bin",
                "CHAU7_CLI_SKIP_BUILD": "1",
                "CHAU7_CLI_PRODUCT_BIN": productBin.path,
                "CHAU7_CLI_INSTALL_DIR": installDir.path
            ]
        )

        XCTAssertEqual(install.status, 0, install.stderr)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installDir.appendingPathComponent("chau7-cli").path))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installDir.appendingPathComponent("chau7").path))
        XCTAssertTrue(install.stdout.contains("fake chau7-cli:--version"))

        let wrapper = try run(
            installDir.appendingPathComponent("chau7").path,
            ["skills", "doctor"],
            environment: ["PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(wrapper.status, 0, wrapper.stderr)
        XCTAssertEqual(wrapper.stdout, "fake chau7-cli:skills doctor\n")
    }

    func testInstallerBuildsTheChau7CLIProductByDefault() throws {
        let script = try String(
            contentsOf: repositoryRoot()
                .appendingPathComponent("Scripts/install-chau7-cli.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("swift build -c \"$BUILD_MODE\" --product chau7-cli"))
        XCTAssertTrue(script.contains("exec \"\\${CHAU7_CLI_BIN:-$INSTALL_DIR/chau7-cli}\" \"\\$@\""))
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
            .appendingPathComponent("Chau7CLIInstallerScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, body: String) throws {
        try "#!/usr/bin/env bash\nset -euo pipefail\n\(body)"
            .write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
