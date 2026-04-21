import XCTest
import Chau7Core

final class TabTitleFormatterTests: XCTestCase {
    func testActiveAINameSurfacesAlongsideCustomTitle() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Codex - Aethyme tooling"
        )
    }

    func testCustomTitleOnlyPreservesExactCustomTitle() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: true
            ),
            "Aethyme tooling"
        )
    }

    func testCustomTitleThatAlreadyContainsAINameIsNotDuplicated() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Codex - Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Codex - Aethyme tooling"
        )
    }

    func testFallsBackToViteAndShell() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: nil,
                aiDisplayAppName: nil,
                devServerName: "Vite",
                customTitleOnly: false
            ),
            "Vite"
        )
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: nil,
                aiDisplayAppName: nil,
                devServerName: nil,
                customTitleOnly: false
            ),
            "Shell"
        )
    }

    func testUsesCallerProvidedShellFallback() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: nil,
                aiDisplayAppName: nil,
                devServerName: nil,
                customTitleOnly: false,
                shellFallback: "Terminal"
            ),
            "Terminal"
        )
    }
}
