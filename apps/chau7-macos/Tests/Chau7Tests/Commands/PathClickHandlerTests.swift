import XCTest
@testable import Chau7

@MainActor
final class PathClickHandlerTests: XCTestCase {

    func testFindPathReturnsMatchContainingClickedIndex() {
        let text = "See docs/alpha.md and docs/beta.md for details"
        let alphaIndex = (text as NSString).range(of: "docs/alpha.md").location + 2
        let betaIndex = (text as NSString).range(of: "docs/beta.md").location + 2

        let alpha = PathClickHandler.findPath(in: text, atUTF16Index: alphaIndex)
        let beta = PathClickHandler.findPath(in: text, atUTF16Index: betaIndex)

        XCTAssertEqual(alpha?.path, "docs/alpha.md")
        XCTAssertEqual(beta?.path, "docs/beta.md")
    }

    func testFindPathReturnsNilWhenClickIsOutsideAnyPath() {
        let text = "See docs/alpha.md and docs/beta.md for details"
        let outsideIndex = (text as NSString).range(of: " and ").location + 1

        let match = PathClickHandler.findPath(in: text, atUTF16Index: outsideIndex)

        XCTAssertNil(match)
    }

    func testFindPathDoesNotMatchLeadingDelimiter() {
        let text = "(docs/readme.md)"
        let delimiterIndex = (text as NSString).range(of: "(").location

        let match = PathClickHandler.findPath(in: text, atUTF16Index: delimiterIndex)

        XCTAssertNil(match)
    }

    func testFindPathPreservesLineAndColumnMetadata() {
        let text = "Open docs/readme.md:12:4 next"
        let clickedIndex = (text as NSString).range(of: "docs/readme.md:12:4").location + 5

        let match = PathClickHandler.findPath(in: text, atUTF16Index: clickedIndex)

        XCTAssertEqual(match?.path, "docs/readme.md")
        XCTAssertEqual(match?.line, 12)
        XCTAssertEqual(match?.column, 4)
    }

    func testFindURLExcludesUnmatchedTrailingClosingParenthesisFromClickRange() throws {
        let text = "Open https://example.com/docs) next"
        let match = try XCTUnwrap(PathClickHandler.findURLs(in: text).first)

        XCTAssertEqual(match.url, "https://example.com/docs")
        XCTAssertEqual(
            (text as NSString).substring(with: match.range),
            "https://example.com/docs"
        )
    }

    func testFindURLPreservesBalancedClosingParenthesisInClickRange() throws {
        let text = "Open https://example.com/docs_(v2) next"
        let match = try XCTUnwrap(PathClickHandler.findURLs(in: text).first)

        XCTAssertEqual(match.url, "https://example.com/docs_(v2)")
        XCTAssertEqual(
            (text as NSString).substring(with: match.range),
            "https://example.com/docs_(v2)"
        )
    }

    func testResolvePathForClickUsesDirectPathFirst() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let direct = repository.appendingPathComponent("README.md")
        try Data().write(to: direct)

        let result = await resolve("README.md", in: repository.path)

        XCTAssertEqual(result, .resolved(path: direct.path, usedRepositoryFallback: false))
    }

    func testResolvePathForClickFindsUniqueNestedBareFilename() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let nested = repository.appendingPathComponent("docs/platform/adr", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let expected = nested.appendingPathComponent("decision.md")
        try Data().write(to: expected)

        let result = await resolve("decision.md", in: repository.path)

        XCTAssertEqual(result, .resolved(path: expected.path, usedRepositoryFallback: true))
    }

    func testResolvePathForClickRefusesAmbiguousBareFilename() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        let first = repository.appendingPathComponent("docs/a/README.md")
        let second = repository.appendingPathComponent("docs/b/README.md")
        try FileManager.default.createDirectory(
            at: first.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: second.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: first)
        try Data().write(to: second)

        let result = await resolve("README.md", in: repository.path)

        XCTAssertEqual(result, .ambiguous([first.path, second.path].sorted()))
    }

    func testResolvePathForClickReportsMissingFilename() async throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }

        let result = await resolve("missing.md", in: repository.path)

        XCTAssertEqual(
            result,
            .missing(directPath: repository.appendingPathComponent("missing.md").path)
        )
    }

    func testRepositorySearchSkipsGeneratedAndDependencyDirectories() throws {
        let repository = try makeRepository()
        defer { try? FileManager.default.removeItem(at: repository) }
        for directory in [".git", ".build", "node_modules"] {
            let ignored = repository.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
            try Data().write(to: ignored.appendingPathComponent("ignored.md"))
        }

        XCTAssertEqual(
            PathClickHandler.repositoryMatches(named: "ignored.md", under: repository.path),
            []
        )
    }

    private func makeRepository() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PathClickHandlerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func resolve(_ path: String, in workingDirectory: String) async -> PathClickHandler.PathResolutionResult {
        await withCheckedContinuation { continuation in
            PathClickHandler.resolvePathForClick(path, relativeTo: workingDirectory) {
                continuation.resume(returning: $0)
            }
        }
    }
}
