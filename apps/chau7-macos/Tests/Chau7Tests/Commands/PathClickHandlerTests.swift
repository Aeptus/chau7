import XCTest
#if !SWIFT_PACKAGE
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
}
#endif
