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
        let snapshot = ProcessTreeProviderResolver.parse(psArgsOutput: output)
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
        let snapshot = ProcessTreeProviderResolver.parse(psArgsOutput: output)
        XCTAssertEqual(snapshot.commOf[100], "zsh")
        XCTAssertEqual(snapshot.commOf[101], "claude")
    }

    func testParseArgsExtractsCommandPathAndFullArgv() {
        // A single `ps -axo pid,ppid,args` scan must yield argv[0] (as comm) and the
        // full argv, so interpreter wrappers stay resolvable from one capture.
        let output = """
          100     1 -zsh
          101   100 /usr/local/bin/claude --resume abc
          102   100 node /Users/x/app/server.js
        """
        let snapshot = ProcessTreeProviderResolver.parse(psArgsOutput: output)
        XCTAssertEqual(snapshot.childrenOf[100]?.sorted(), [101, 102])
        XCTAssertEqual(snapshot.commOf[101], "/usr/local/bin/claude")
        XCTAssertEqual(snapshot.argsOf[101], "/usr/local/bin/claude --resume abc")
        XCTAssertEqual(snapshot.commOf[102], "node")
        XCTAssertEqual(snapshot.argsOf[102], "node /Users/x/app/server.js")
        XCTAssertEqual(
            ProcessTreeProviderResolver.resolve(shellPid: 100, snapshot: snapshot),
            "Claude"
        )
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

    // MARK: - Snapshot building

    func testBuildSnapshotFoldsRows() {
        let rows = [
            ProcessTreeProviderResolver.ProcessRow(pid: 100, ppid: 1, command: "zsh", argv: nil),
            ProcessTreeProviderResolver.ProcessRow(pid: 101, ppid: 100, command: "node", argv: "node /x/gemini"),
            ProcessTreeProviderResolver.ProcessRow(pid: 102, ppid: 100, command: "claude", argv: nil)
        ]
        let snapshot = ProcessTreeProviderResolver.buildSnapshot(rows: rows)
        XCTAssertEqual(snapshot.childrenOf[100]?.sorted(), [101, 102])
        XCTAssertEqual(snapshot.commOf[101], "node")
        XCTAssertEqual(snapshot.argsOf[101], "node /x/gemini")
        XCTAssertEqual(snapshot.commOf[102], "claude")
        XCTAssertNil(snapshot.argsOf[102]) // no argv → not stored
    }

    // MARK: - captureSnapshot (native primary, ps fallback)

    func testCaptureSnapshotPrefersNativeRowsOverPS() {
        let rows = [
            ProcessTreeProviderResolver.ProcessRow(pid: 100, ppid: 1, command: "zsh", argv: nil),
            ProcessTreeProviderResolver.ProcessRow(pid: 101, ppid: 100, command: "codex", argv: nil)
        ]
        let snapshot = ProcessTreeProviderResolver.captureSnapshot(
            rowProvider: { rows },
            runner: { _, _ in "999 1 should-not-run" }
        )
        XCTAssertEqual(snapshot?.commOf[101], "codex")
        XCTAssertNil(snapshot?.commOf[999], "ps fallback must be skipped when native rows exist")
    }

    func testCaptureSnapshotFallsBackToPSWhenNativeEmpty() {
        let argsFixture = """
          100     1 zsh
          101   100 claude --resume abc
        """
        let snapshot = ProcessTreeProviderResolver.captureSnapshot(
            rowProvider: { nil },
            runner: { _, _ in argsFixture }
        )
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.commOf[101], "claude")
        XCTAssertEqual(snapshot?.argsOf[101], "claude --resume abc")
    }

    func testCaptureSnapshotReturnsNilWhenNativeAndPSFail() {
        XCTAssertNil(
            ProcessTreeProviderResolver.captureSnapshot(rowProvider: { nil }, runner: { _, _ in nil })
        )
    }

    // MARK: - KERN_PROCARGS2 decoding

    func testParseProcArgsReconstructsCommandLine() {
        // KERN_PROCARGS2 layout: Int32 argc, exec path + NUL, NUL padding, argc argv strings.
        var raw: [UInt8] = []
        var argc: Int32 = 2
        withUnsafeBytes(of: &argc) { raw.append(contentsOf: $0) }
        raw.append(contentsOf: Array("/usr/local/bin/node".utf8))
        raw.append(0)
        raw.append(0)
        raw.append(0) // padding before argv[0]
        raw.append(contentsOf: Array("node".utf8))
        raw.append(0)
        raw.append(contentsOf: Array("/Users/x/.volta/bin/gemini".utf8))
        raw.append(0)
        raw.append(contentsOf: Array("PATH=/usr/bin".utf8))
        raw.append(0) // env (ignored)

        XCTAssertEqual(
            ProcessTreeProviderResolver.parseProcArgs(raw),
            "node /Users/x/.volta/bin/gemini"
        )
    }

    func testParseProcArgsRejectsMalformedBuffer() {
        XCTAssertNil(ProcessTreeProviderResolver.parseProcArgs([1, 2])) // shorter than Int32 argc
        XCTAssertNil(ProcessTreeProviderResolver.parseProcArgs([0, 0, 0, 0])) // argc == 0
    }

    // MARK: - Native enumeration (integration)

    func testNativeRowsIncludesCurrentProcess() {
        guard let rows = ProcessTreeProviderResolver.nativeRows() else {
            return XCTFail("native enumeration returned nil")
        }
        let current = rows.first { $0.pid == getpid() }
        XCTAssertNotNil(current, "current process should appear in the native snapshot")
        XCTAssertEqual(current?.ppid, getppid())
        XCTAssertFalse(current?.command.isEmpty ?? true)
    }
}
