import Foundation
import XCTest
@testable import Chau7

/// SPM-runnable tests pinning the URL detection regex used by Cmd+click.
///
/// User reported that file paths were Cmd+clickable but URLs weren't. The
/// pre-fix regex required a `://` scheme, so bare URLs like `github.com/foo`
/// or `localhost:3000` (extremely common in modern CLI output) silently
/// failed. This suite pins all four matching shapes plus a representative
/// false-positive corpus so future regex tweaks can't silently break a
/// case the user relies on.
final class UrlRegexTests: XCTestCase {

    // MARK: - Schemed URLs (canonical case, must keep working)

    func testSchemedHttpsMatches() {
        XCTAssertEqual(matches(in: "https://github.com/Aeptus/chau7/pull/123"),
                       ["https://github.com/Aeptus/chau7/pull/123"])
    }

    func testSchemedHttpMatches() {
        XCTAssertEqual(matches(in: "http://localhost:3000"),
                       ["http://localhost:3000"])
    }

    func testFileUrlMatches() {
        XCTAssertEqual(matches(in: "file:///etc/hosts"),
                       ["file:///etc/hosts"])
    }

    // MARK: - Bare domain + path (the user's regression)

    func testBareDomainWithPathMatches() {
        XCTAssertEqual(matches(in: "github.com/Aeptus/chau7"),
                       ["github.com/Aeptus/chau7"])
    }

    func testBareDomainDeepPathMatches() {
        XCTAssertEqual(matches(in: "github.com/Aeptus/chau7/pull/123"),
                       ["github.com/Aeptus/chau7/pull/123"])
    }

    func testBareDomainEmbeddedInProseMatches() {
        XCTAssertEqual(matches(in: "Visit github.com/foo to see"),
                       ["github.com/foo"])
    }

    // MARK: - localhost (with optional port + path)

    func testLocalhostBareMatches() {
        XCTAssertEqual(matches(in: "localhost:3000"),
                       ["localhost:3000"])
    }

    func testLocalhostWithPathMatches() {
        XCTAssertEqual(matches(in: "localhost:3000/api/users"),
                       ["localhost:3000/api/users"])
    }

    // MARK: - www-prefixed

    func testWwwBareMatches() {
        XCTAssertEqual(matches(in: "www.example.com"),
                       ["www.example.com"])
    }

    func testWwwWithPathMatches() {
        XCTAssertEqual(matches(in: "www.example.com/foo/bar"),
                       ["www.example.com/foo/bar"])
    }

    // MARK: - False-positive corpus (must NOT match)

    func testVersionStringDoesNotMatch() {
        XCTAssertEqual(matches(in: "v1.2.3 release"), [])
    }

    func testDotPropertyDoesNotMatch() {
        XCTAssertEqual(matches(in: "self.foo.bar"), [])
    }

    func testQuotedDottedIdentifierDoesNotMatch() {
        XCTAssertEqual(matches(in: "import { foo } from 'foo.bar.baz'"), [])
    }

    func testBareFilenameDoesNotMatch() {
        // README.md without a slash must not be confused for a URL —
        // the path-click handler covers it instead.
        XCTAssertEqual(matches(in: "see README.md for details"), [])
    }

    func testAbsolutePathDoesNotMatch() {
        XCTAssertEqual(matches(in: "/Users/me/file.txt"), [])
    }

    func testRelativePathWithLineColumnDoesNotMatch() {
        XCTAssertEqual(matches(in: "./relative/path.swift:42"), [])
    }

    // MARK: - Helpers

    /// Pulls every matched URL substring from `text` using the production
    /// regex, returning them in document order. Captures the same shape
    /// `RustTerminalView+Mouse.findURLs` consumes.
    private func matches(in text: String) -> [String] {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        var results: [String] = []
        RegexPatterns.url.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            results.append(nsText.substring(with: match.range))
        }
        return results
    }
}

/// SPM-runnable tests for `PathClickHandler.normalizedURLString` — the
/// scheme-prepend helper that lets `NSWorkspace.open` accept bare URLs.
final class PathClickHandlerNormalizedURLTests: XCTestCase {

    func testSchemedURLPassesThroughUnchanged() {
        XCTAssertEqual(PathClickHandler.normalizedURLString("https://example.com"),
                       "https://example.com")
    }

    func testFileURLPassesThroughUnchanged() {
        XCTAssertEqual(PathClickHandler.normalizedURLString("file:///etc/hosts"),
                       "file:///etc/hosts")
    }

    func testBareDomainGetsHttpsScheme() {
        XCTAssertEqual(PathClickHandler.normalizedURLString("github.com/foo"),
                       "https://github.com/foo")
    }

    func testWwwGetsHttpsScheme() {
        XCTAssertEqual(PathClickHandler.normalizedURLString("www.example.com/path"),
                       "https://www.example.com/path")
    }

    func testLocalhostHostPortGetsHttpsScheme() {
        // Crucial: `localhost:3000` contains a colon, but no `://`. We must
        // NOT treat `localhost:` as an existing scheme — the colon is the
        // host:port separator.
        XCTAssertEqual(PathClickHandler.normalizedURLString("localhost:3000"),
                       "https://localhost:3000")
    }

    func testNormalizationProducesValidURL() {
        // Round-trip: NSWorkspace.open requires URL(string:) to accept the
        // normalized form. Confirm for every scheme-less shape.
        for input in ["github.com/foo", "www.example.com/path", "localhost:3000"] {
            let normalized = PathClickHandler.normalizedURLString(input)
            XCTAssertNotNil(URL(string: normalized),
                            "URL(string:) must accept normalized form of '\(input)' (got '\(normalized)')")
        }
    }
}
