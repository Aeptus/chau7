import XCTest
@testable import Chau7
@testable import Chau7Core

final class AITerminalLogSessionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chau7-ai-log-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testRecordInputPersistsNormalCommands() throws {
        let logURL = tempDir.appendingPathComponent("pty.log")
        let session = AITerminalLogSession(toolName: "Claude", logPath: logURL.path)

        session.recordInput("echo hello\n")
        session.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, "[INPUT] echo hello\n")
    }

    func testRecordInputRedactsInlineSecrets() throws {
        let logURL = tempDir.appendingPathComponent("pty.log")
        let session = AITerminalLogSession(toolName: "Claude", logPath: logURL.path)

        session.recordInput("curl -H 'Authorization: Bearer secret-token' https://example.com\n")
        session.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, "[INPUT] curl \(SensitiveInputGuard.redactedPlaceholder)\n")
    }
}
