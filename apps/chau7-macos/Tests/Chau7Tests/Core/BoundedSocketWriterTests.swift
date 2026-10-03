import Darwin
import Foundation
import XCTest
@testable import Chau7Core

final class BoundedSocketWriterTests: XCTestCase {
    private func sockets() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        var size: Int32 = 4096
        _ = setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(pair[1], SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return (pair[0], pair[1])
    }

    private func readToEOF(_ socket: Int32) -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(socket, &bytes, bytes.count, 0)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }

    func testPartialWritesDeliverEveryByteAndFinishDrainsInOrder() throws {
        let (socket, peer) = try sockets()
        defer { Darwin.close(socket)
            Darwin.close(peer)
        }
        let writer = try XCTUnwrap(BoundedSocketWriter(socket: socket))
        let frame = Data(repeating: 65, count: 2 * 1024 * 1024)
        XCTAssertTrue(writer.enqueue(frame))
        XCTAssertTrue(writer.enqueue(Data("\nsecond\n".utf8)))
        writer.finish()
        XCTAssertEqual(readToEOF(peer), frame + Data("\nsecond\n".utf8))
        XCTAssertFalse(writer.enqueue(Data("late".utf8)))
    }

    func testAdmissionDoesNotWaitForUnreadPeerAndDeadlineWakesReader() throws {
        let (socket, peer) = try sockets()
        defer { Darwin.close(socket)
            Darwin.close(peer)
        }
        let writer = try XCTUnwrap(BoundedSocketWriter(socket: socket, timeout: 0.08))
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(writer.enqueue(Data(repeating: 65, count: 2 * 1024 * 1024)))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.25)
        // Wait for the write deadline without draining the peer.
        let closed = expectation(description: "backpressured writer closes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        XCTAssertFalse(writer.isOpen)
        XCTAssertLessThan(readToEOF(peer).count, 2 * 1024 * 1024)
    }

    func testDeadlineIncludesTimeWaitingOnWriterQueue() throws {
        let (socket, peer) = try sockets()
        defer { Darwin.close(socket)
            Darwin.close(peer)
        }
        let queue = DispatchQueue(label: "writer.deadline.fixture")
        let writer = try XCTUnwrap(BoundedSocketWriter(socket: socket, timeout: 0.02, maxPendingBytes: 1024, maxPendingFrames: 4, queue: queue))
        queue.suspend()
        XCTAssertTrue(writer.enqueue(Data("expired frame\n".utf8)))
        writer.finish()
        let expired = expectation(description: "admitted deadline expires")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.06) { expired.fulfill() }
        wait(for: [expired], timeout: 2)
        queue.resume()
        XCTAssertEqual(readToEOF(peer), Data())
    }

    func testQueueOverflowClosesOnlyItsConnection() throws {
        let (socket, peer) = try sockets()
        defer { Darwin.close(socket)
            Darwin.close(peer)
        }
        let writer = try XCTUnwrap(BoundedSocketWriter(socket: socket, maxPendingBytes: 3))
        XCTAssertFalse(writer.enqueue(Data("four".utf8)))
        XCTAssertFalse(writer.isOpen)
        XCTAssertEqual(readToEOF(peer), Data())
    }

    func testCloseRejectsLateCallbacksAndIsIdempotent() throws {
        let (socket, peer) = try sockets()
        defer { Darwin.close(socket)
            Darwin.close(peer)
        }
        let writer = try XCTUnwrap(BoundedSocketWriter(socket: socket))
        writer.close()
        writer.close()
        writer.finish()
        XCTAssertFalse(writer.enqueue(Data("stale notification".utf8)))
        XCTAssertEqual(readToEOF(peer), Data())
    }

    func testBrokenPeerDoesNotRaiseSIGPIPE() throws {
        let (socket, peer) = try sockets()
        defer { Darwin.close(socket) }
        let writer = try XCTUnwrap(BoundedSocketWriter(socket: socket))
        Darwin.close(peer)
        XCTAssertTrue(writer.enqueue(Data("frame\n".utf8)))
        writer.finish()
        let completed = expectation(description: "broken socket completes")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { completed.fulfill() }
        wait(for: [completed], timeout: 2)
        XCTAssertFalse(writer.isOpen)
    }
}
