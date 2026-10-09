import Darwin
import Foundation
import XCTest
@testable import Chau7

@MainActor
final class MCPClientConnectionsTests: XCTestCase {
    func testStopPreservesReaderOwnershipUntilTeardown() async {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[1]) }
        let descriptor = pair[0]
        let session = MCPSession(fd: descriptor, controlService: TerminalControlService())
        let clients = MCPClientConnections()
        clients.insert(session, descriptor: descriptor)
        clients.stopAll()
        XCTAssertEqual(clients.count, 0)
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0, "Only the session's reader may close its original fd")

        let exited = expectation(description: "reader wakes after stop")
        DispatchQueue.global().async {
            session.run()
            exited.fulfill()
        }
        await fulfillment(of: [exited], timeout: 5)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1)

        // Reuse the old reader number for an unrelated descriptor. Repeated
        // stop calls must never close the newly allocated resource.
        let replacement = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(replacement, 0)
        defer { Darwin.close(replacement) }
        if replacement != descriptor {
            XCTAssertEqual(dup2(replacement, descriptor), descriptor)
        }
        defer { if replacement != descriptor { Darwin.close(descriptor) } }
        session.stop()
        clients.stopAll()
        XCTAssertGreaterThanOrEqual(fcntl(descriptor, F_GETFD), 0)
    }

    func testLateDisconnectDoesNotRemoveReplacementSession() {
        // Registry keys model a reused fd; each session still owns a distinct
        // real socket so this test cannot double-close test-runner resources.
        var firstPair: [Int32] = [-1, -1]
        var secondPair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &firstPair), 0)
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &secondPair), 0)
        defer {
            for descriptor in firstPair + secondPair {
                Darwin.close(descriptor)
            }
        }
        let first = MCPSession(fd: firstPair[0], controlService: TerminalControlService())
        let replacement = MCPSession(fd: secondPair[0], controlService: TerminalControlService())
        let clients = MCPClientConnections()
        clients.insert(first, descriptor: 100)
        clients.insert(replacement, descriptor: 100)
        clients.remove(first, descriptor: 100)
        XCTAssertEqual(clients.count, 1)
        clients.remove(replacement, descriptor: 100)
        XCTAssertEqual(clients.count, 0)
        first.stop()
        replacement.stop()
    }
}
