import Darwin
import Foundation
import XCTest
@testable import Chau7

@MainActor
final class MCPSessionTransportTests: XCTestCase {
    func testSocketSessionDrainsResponsesAfterPeerWriteEOF() async throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        let peer = pair[1]
        defer { Darwin.close(peer) }
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(peer, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let session = MCPSession(fd: pair[0], controlService: TerminalControlService())
        let task = Task.detached { session.run() }
        let requests = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}
        {"jsonrpc":"2.0","method":"notifications/initialized"}
        {"jsonrpc":"2.0","id":2,"method":"ping"}
        invalid-json

        """
        let bytes = Data(requests.utf8)
        let written = bytes.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
        XCTAssertEqual(written, bytes.count)
        shutdown(peer, SHUT_WR)
        let responseData = await Task.detached {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = recv(peer, &buffer, buffer.count, 0)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            return data
        }.value
        await task.value
        let responses = try String(decoding: responseData, as: UTF8.self)
            .split(separator: "\n").map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses[0]["id"] as? Int, 1)
        XCTAssertNotNil(responses[0]["result"])
        XCTAssertEqual(responses[1]["id"] as? Int, 2)
        XCTAssertNotNil(responses[1]["result"])
        XCTAssertEqual((responses[2]["error"] as? [String: Any])?["code"] as? Int, -32700)
    }
}
