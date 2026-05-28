import XCTest

final class CodexTerminalPathFixScriptTests: XCTestCase {
    func testInstallerMakesTerminalZshResolveCodexImageBinBeforeVoltaShim() throws {
        try XCTSkipUnless(
            FileManager.default.isExecutableFile(atPath: "/bin/zsh"),
            "zsh is required to verify Terminal.app startup semantics"
        )

        let tempHome = try makeTemporaryDirectory()
        let shimBin = tempHome
            .appendingPathComponent(".volta", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let nodeBin = tempHome.codexVoltaNodeBin("25.7.0")
        let rcFile = tempHome.appendingPathComponent(".zshrc")

        try FileManager.default.createDirectory(at: shimBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nodeBin, withIntermediateDirectories: true)
        try writeExecutable(
            at: shimBin.appendingPathComponent("codex"),
            body: "printf 'shim\\n'\n"
        )
        try writeExecutable(
            at: nodeBin.appendingPathComponent("codex"),
            body: "printf 'image\\n'\n"
        )
        try """
        export VOLTA_HOME="$HOME/.volta"
        export PATH="$VOLTA_HOME/bin:/usr/bin:/bin"

        """.write(to: rcFile, atomically: true, encoding: .utf8)

        let script = repositoryRoot()
            .appendingPathComponent("Scripts/install-codex-terminal-path-fix.sh")
        let install = try run(
            "/bin/bash",
            [script.path, rcFile.path],
            environment: ["HOME": tempHome.path, "PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(install.status, 0, install.stderr)

        let zshCheck = try run(
            "/bin/zsh",
            [
                "-f",
                "-c",
                "source \(shellQuote(rcFile.path)); command -v codex; codex"
            ],
            environment: ["HOME": tempHome.path, "PATH": "/usr/bin:/bin"]
        )

        XCTAssertEqual(zshCheck.status, 0, zshCheck.stderr)
        let lines = zshCheck.stdout
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(lines.first, nodeBin.appendingPathComponent("codex").path)
        XCTAssertEqual(lines.last, "image")
    }

    func testInstallerIsIdempotent() throws {
        let tempHome = try makeTemporaryDirectory()
        let rcFile = tempHome.appendingPathComponent(".zshrc")
        try "export PATH=\"$HOME/.volta/bin:$PATH\"\n"
            .write(to: rcFile, atomically: true, encoding: .utf8)

        let script = repositoryRoot()
            .appendingPathComponent("Scripts/install-codex-terminal-path-fix.sh")

        for _ in 0 ..< 2 {
            let result = try run(
                "/bin/bash",
                [script.path, rcFile.path],
                environment: ["HOME": tempHome.path, "PATH": "/usr/bin:/bin"]
            )
            XCTAssertEqual(result.status, 0, result.stderr)
        }

        let contents = try String(contentsOf: rcFile, encoding: .utf8)
        XCTAssertEqual(contents.components(separatedBy: "# >>> Chau7 Codex Volta PATH fix >>>").count - 1, 1)
        XCTAssertEqual(contents.components(separatedBy: "# <<< Chau7 Codex Volta PATH fix <<<").count - 1, 1)
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
            .appendingPathComponent("CodexTerminalPathFixScriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(at url: URL, body: String) throws {
        try "#!/bin/sh\n\(body)".write(to: url, atomically: true, encoding: .utf8)
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

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
