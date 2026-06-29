import XCTest
@testable import Chau7

/// Light coverage for the highlight cache after swapping out the bogus
/// `Dictionary.keys.prefix` eviction for `NSCache`. We can't observe
/// `NSCache`'s internal LRU ordering directly, so we just verify identity:
/// the same input string returns the *same* cached `NSAttributedString`
/// instance until the cache is cleared.
final class SyntaxHighlighterCacheTests: XCTestCase {

    func testRepeatedHighlightReturnsCachedInstance() {
        SyntaxHighlighter.shared.clearCache()

        let sample = "ERROR: something failed at /tmp/foo.swift"
        let first = SyntaxHighlighter.shared.highlight(sample)
        let second = SyntaxHighlighter.shared.highlight(sample)

        // `NSCache` returns the same boxed object for the same key until
        // it evicts — a fresh recompute would produce a distinct instance.
        XCTAssertTrue(
            first === second,
            "expected the cache to return the same NSAttributedString instance"
        )
    }

    func testClearCacheForcesRecompute() {
        SyntaxHighlighter.shared.clearCache()

        let sample = "WARNING: deprecated"
        let before = SyntaxHighlighter.shared.highlight(sample)
        SyntaxHighlighter.shared.clearCache()
        let after = SyntaxHighlighter.shared.highlight(sample)

        XCTAssertFalse(
            before === after,
            "clearCache must drop entries so the next highlight builds a fresh result"
        )
        XCTAssertEqual(before.string, after.string, "highlight output must still be deterministic")
    }
}
