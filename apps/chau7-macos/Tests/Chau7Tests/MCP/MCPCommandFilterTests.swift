#if !SWIFT_PACKAGE
import XCTest
@testable import Chau7

final class MCPCommandFilterTests: XCTestCase {
    func testExtractBaseCommandsSplitsBackgroundOperator() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("echo ok & rm -rf /"),
            ["echo", "rm"]
        )
    }

    func testExtractBaseCommandsSplitsNewlines() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("echo ok\nrm -rf /"),
            ["echo", "rm"]
        )
    }

    func testExtractBaseCommandsDoesNotSplitQuotedSeparatorLiterals() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("printf '&'\nprintf done"),
            ["printf", "printf"]
        )
    }

    func testExtractBaseCommandsTreatsTabsAsWhitespace() {
        XCTAssertEqual(
            MCPCommandFilter.extractBaseCommands("env\tFOO=bar\t/bin/rm -f /tmp/test"),
            ["rm"]
        )
    }
}
#endif
