import XCTest
@testable import Chau7Core

final class MagiCLICommandTests: XCTestCase {
    func testBareQuestionParsesAsAsk() {
        XCTAssertEqual(
            MagiCLICommandParser.parse(["What", "is", "the", "best", "Final", "Fantasy?"]),
            .success(.ask(question: "What is the best Final Fantasy?"))
        )
    }

    func testAskCommandParsesQuestion() {
        XCTAssertEqual(
            MagiCLICommandParser.parse(["ask", "Should we merge this?"]),
            .success(.ask(question: "Should we merge this?"))
        )
    }

    func testAskWithoutQuestionFails() {
        XCTAssertEqual(
            MagiCLICommandParser.parse(["ask"]),
            .failure(.missingQuestion)
        )
    }

    func testDoctorParses() {
        XCTAssertEqual(MagiCLICommandParser.parse(["doctor"]), .success(.doctor))
    }

    func testConfigParses() {
        XCTAssertEqual(MagiCLICommandParser.parse(["config"]), .success(.config))
        XCTAssertEqual(MagiCLICommandParser.parse(["--config"]), .success(.config))
    }

    func testReplayRequiresRunID() {
        XCTAssertEqual(MagiCLICommandParser.parse(["replay"]), .failure(.missingRunID(command: "replay")))
        XCTAssertEqual(MagiCLICommandParser.parse(["replay", "run-1"]), .success(.replay(runID: "run-1")))
    }

    func testShareRequiresRunID() {
        XCTAssertEqual(MagiCLICommandParser.parse(["share"]), .failure(.missingRunID(command: "share")))
        XCTAssertEqual(MagiCLICommandParser.parse(["share", "run-1"]), .success(.share(runID: "run-1")))
    }

    func testHelpAndVersionParse() {
        XCTAssertEqual(MagiCLICommandParser.parse([]), .success(.home))
        XCTAssertEqual(MagiCLICommandParser.parse(["--help"]), .success(.help))
        XCTAssertEqual(MagiCLICommandParser.parse(["version"]), .success(.version))
        XCTAssertEqual(MagiCLICommandParser.parse(["--version"]), .success(.version))
    }

    func testUnknownOptionFails() {
        XCTAssertEqual(MagiCLICommandParser.parse(["--unknown"]), .failure(.unknownOption("--unknown")))
    }

    func testPathsUseGlobalMagiDefaults() {
        let paths = MagiCLIPaths(homeDirectory: "/home/user", currentDirectory: "/repo")

        XCTAssertEqual(paths.globalRoot, "/home/user/.chau7/magi")
        XCTAssertEqual(paths.globalConfigPath, "/home/user/.chau7/magi/config.toml")
        XCTAssertEqual(paths.globalPersonaDirectory, "/home/user/.chau7/magi/personas")
        XCTAssertEqual(paths.personaPath(for: .melchior), "/home/user/.chau7/magi/personas/melchior.md")
    }

    func testPathsResolveArtifactsToRepositoryRootWhenInsideGitRepo() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo")
        let nested = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )

        let paths = MagiCLIPaths(homeDirectory: "/home/user", currentDirectory: nested.path)
        let bundle = paths.artifactBundle(runID: "run-1")

        XCTAssertEqual(paths.repositoryRoot(), repo.path)
        XCTAssertEqual(bundle.rootDirectory, "\(repo.path)/.chau7/magi/runs/run-1")
        XCTAssertEqual(bundle.requiredPaths.map { URL(fileURLWithPath: $0).lastPathComponent }, MagiArtifactBundle.requiredFileNames)
    }

    func testPathsResolveArtifactsToRepositoryRootForGitFileWorktree() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("worktree")
        let nested = repo.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(
            at: nested,
            withIntermediateDirectories: true
        )
        try "gitdir: ../.git/worktrees/worktree\n".write(
            to: repo.appendingPathComponent(".git"),
            atomically: true,
            encoding: .utf8
        )

        let paths = MagiCLIPaths(homeDirectory: "/home/user", currentDirectory: nested.path)

        XCTAssertEqual(paths.repositoryRoot(), repo.path)
        XCTAssertEqual(paths.resolvedRunRoot(runID: "run-2"), "\(repo.path)/.chau7/magi/runs/run-2")
    }

    func testPathsResolveArtifactsToHomeWhenOutsideRepository() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let paths = MagiCLIPaths(homeDirectory: "/home/user", currentDirectory: outside.path)
        let candidates = paths.artifactCandidateBundles(runID: "run-3")

        XCTAssertNil(paths.repositoryRoot())
        XCTAssertEqual(paths.resolvedRunRoot(runID: "run-3"), "/home/user/.chau7/magi/runs/run-3")
        XCTAssertEqual(candidates.map(\.rootDirectory), ["/home/user/.chau7/magi/runs/run-3"])
    }

    func testArtifactCandidatesPreferRepoThenGlobal() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(
            at: repo.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )

        let paths = MagiCLIPaths(homeDirectory: "/home/user", currentDirectory: repo.path)
        let candidates = paths.artifactCandidateBundles(runID: "run-4")

        XCTAssertEqual(
            candidates.map(\.rootDirectory),
            [
                "\(repo.path)/.chau7/magi/runs/run-4",
                "/home/user/.chau7/magi/runs/run-4"
            ]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("magi-cli-paths-\(UUID().uuidString)")
    }
}
