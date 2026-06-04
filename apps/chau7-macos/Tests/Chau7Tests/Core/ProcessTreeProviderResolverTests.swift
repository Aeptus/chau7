import XCTest
@testable import Chau7Core

final class ProcessTreeProviderResolverTests: XCTestCase {

    // MARK: - Parse

    func testParseBuildsAdjacencyAndCommMap() {
        let output = """
          100     1 zsh
          101   100 claude
          102   100 vim
        """
        let snapshot = ProcessTreeProviderResolver.parse(psOutput: output)
        XCTAssertEqual(snapshot.childrenOf[100]?.sorted(), [101, 102])
        XCTAssertEqual(snapshot.commOf[101], "claude")
        XCTAssertEqual(snapshot.commOf[102], "vim")
    }

    func testParseIgnoresHeaderAndMalformedLines() {
        let output = """
          PID  PPID COMMAND
          100     1 zsh
        garbage line
          101   100 claude
        """
        let snapshot = ProcessTreeProviderResolver.parse(psOutput: output)
        XCTAssertEqual(snapshot.commOf[100], "zsh")
        XCTAssertEqual(snapshot.commOf[101], "claude")
    }

    // MARK: - Resolve

    func testDirectChildMatch() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "claude"]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Claude"
        )
    }

    func testNestedUnderTmux() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [
                100: [200],
                200: [300],
                300: [400]
            ],
            commOf: [
                100: "zsh",
                200: "tmux-server",
                300: "zsh",
                400: "codex"
            ]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Codex"
        )
    }

    func testNoMatchReturnsNil() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "vim"]
        )
        XCTAssertNil(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot)
        )
    }

    func testShellOnlyTreeReturnsNil() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [:],
            commOf: [100: "zsh"]
        )
        XCTAssertNil(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot)
        )
    }

    func testWrapperLeafIsUnmatched() {
        // Interpreter-only process rows remain unmatched when argv is unavailable.
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "node"]
        )
        XCTAssertNil(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot)
        )
    }

    func testNodeWrapperArgMatchesGemini() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "node"],
            argsOf: [
                101: "node /Users/christophehenner/.volta/tools/image/node/25.7.0/bin/gemini"
            ]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Gemini"
        )
    }

    func testNestedVoltaNodeWrapperArgMatchesGemini() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [
                100: [101],
                101: [102]
            ],
            commOf: [
                100: "zsh",
                101: "node",
                102: "/Users/christophehenner/.volta/tools/image/node/25.7.0/bin/node"
            ],
            argsOf: [
                101: "node /Users/christophehenner/.volta/tools/image/node/25.7.0/bin/gemini",
                102: "/Users/christophehenner/.volta/tools/image/node/25.7.0/bin/node --max-old-space-size=8192 /Users/christophehenner/.volta/tools/image/node/25.7.0/bin/gemini"
            ]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Gemini"
        )
    }

    func testArgvDoesNotMatchPlainOptionValue() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "python3"],
            argsOf: [
                101: "python3 eval.py --model gemini"
            ]
        )
        XCTAssertNil(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot)
        )
    }

    func testDeepestMatchWins() {
        // If a tool launches a subprocess whose basename also appears in the registry,
        // we prefer the deeper (leaf) match.
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [
                100: [200],
                200: [300]
            ],
            commOf: [
                100: "zsh",
                200: "claude",
                300: "codex"
            ]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Codex"
        )
    }

    func testBasenameStrippedFromPath() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "/usr/local/bin/claude"]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Claude"
        )
    }

    func testCaseInsensitiveMatch() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "CLAUDE"]
        )
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Claude"
        )
    }

    func testInvalidShellPidReturnsNil() {
        let snapshot = ProcessTreeProviderResolver.Snapshot(
            childrenOf: [100: [101]],
            commOf: [100: "zsh", 101: "claude"]
        )
        XCTAssertNil(ProcessTreeProviderResolver.resolve(shellPid: 0, snapshot: snapshot))
        XCTAssertNil(ProcessTreeProviderResolver.resolve(shellPid: -1, snapshot: snapshot))
    }

    func testCaptureSnapshotUsesInjectedRunner() {
        let commFixture = """
          100     1 zsh
          101   100 claude
        """
        let argsFixture = """
          100     1 zsh
          101   100 claude --resume abc
        """
        let snapshot = ProcessTreeProviderResolver.captureSnapshot { _, args in
            args.joined(separator: " ").contains("args") ? argsFixture : commFixture
        }
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.commOf[101], "claude")
        XCTAssertEqual(snapshot?.argsOf[101], "claude --resume abc")
    }

    func testCaptureSnapshotReturnsNilWhenRunnerFails() {
        XCTAssertNil(ProcessTreeProviderResolver.captureSnapshot { _, _ in nil })
    }
}
