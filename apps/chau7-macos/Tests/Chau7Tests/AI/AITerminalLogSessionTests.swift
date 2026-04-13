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

    func testSyncDrainsQueuedOutputBeforeRead() throws {
        let logURL = tempDir.appendingPathComponent("pty.log")
        let session = AITerminalLogSession(toolName: "Codex", logPath: logURL.path)

        session.recordOutput(Data("Working...\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n".utf8))
        session.sync()

        let tail = try XCTUnwrap(TelemetryRecorder.readPTYLogTail(path: logURL.path))
        XCTAssertTrue(tail.contains("Working..."))
        XCTAssertTrue(tail.contains("\"summary\":\"ok\""))
    }

    func testReadPTYLogTailNormalizesAnsiAndBackspaces() throws {
        let logURL = tempDir.appendingPathComponent("pty.log")
        let session = AITerminalLogSession(toolName: "Codex", logPath: logURL.path)
        let raw = "\u{1B}[32mWaitix\u{08}ng...\u{1B}[0m\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n"

        session.recordOutput(Data(raw.utf8))
        session.sync()

        let tail = try XCTUnwrap(TelemetryRecorder.readPTYLogTail(path: logURL.path))
        XCTAssertTrue(tail.contains("Waiting..."))
        XCTAssertFalse(tail.contains("\u{1B}[32m"))
        XCTAssertFalse(tail.contains("\u{08}"))
        XCTAssertTrue(tail.contains("\"summary\":\"ok\""))
    }

    func testCloseFlushesBufferedOutput() throws {
        let logURL = tempDir.appendingPathComponent("pty.log")
        let session = AITerminalLogSession(toolName: "Codex", logPath: logURL.path)

        session.recordOutput(Data("Working...\n".utf8))
        session.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, "Working...\n")
    }

    func testInputFlushPreservesEarlierBufferedOutputOrdering() throws {
        let logURL = tempDir.appendingPathComponent("pty.log")
        let session = AITerminalLogSession(toolName: "Codex", logPath: logURL.path)

        session.recordOutput(Data("Working...\n".utf8))
        session.recordInput("echo hello\n")
        session.close()

        let contents = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(contents, "Working...\n[INPUT] echo hello\n")
    }
}
