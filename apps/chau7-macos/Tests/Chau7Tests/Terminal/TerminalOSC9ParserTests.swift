import XCTest
@testable import Chau7Core

final class TerminalOSC9ParserTests: XCTestCase {
    func testBuffersSplitChau7BranchMarkerUntilTerminatorArrives() {
        var parser = TerminalOSC9Parser()

        XCTAssertEqual(parser.ingest(Data("\u{1B}]9;chau7;br".utf8)), [])
        XCTAssertEqual(parser.ingest(Data("anch=feature/split".utf8)), [])

        XCTAssertEqual(
            parser.ingest(Data("\u{7}".utf8)),
            [.chau7(key: "branch", value: "feature/split")]
        )
    }

    func testParsesRepoRootWithSTTerminator() {
        var parser = TerminalOSC9Parser()

        let events = parser.ingest(Data("\u{1B}]9;chau7;repo-root=/tmp/repo\u{1B}\\".utf8))

        XCTAssertEqual(events, [.chau7(key: "repo-root", value: "/tmp/repo")])
    }

    func testSeparatesForeignNotificationsFromChau7Markers() {
        var parser = TerminalOSC9Parser()

        let payload = "\u{1B}]9;Approval requested: test\u{7}\u{1B}]9;chau7;exit=0\u{7}"

        XCTAssertEqual(
            parser.ingest(Data(payload.utf8)),
            [
                .foreign(message: "Approval requested: test"),
                .chau7(key: "exit", value: "0")
            ]
        )
    }

    func testKeepsSplitPrefixAfterNoise() {
        var parser = TerminalOSC9Parser()

        XCTAssertEqual(parser.ingest(Data("noise\u{1B}]".utf8)), [])
        XCTAssertEqual(
            parser.ingest(Data("9;chau7;branch=main\u{7}".utf8)),
            [.chau7(key: "branch", value: "main")]
        )
    }
}
