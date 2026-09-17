import Chau7Core
import XCTest

final class TerminalWriteQueueTests: XCTestCase {
    func testClipboardReplyIsNonBlockingOrderedAndCoalesced() {
        let queue = TerminalWriteQueue()
        let entered = expectation(description: "writer backpressured")
        let reply = expectation(description: "clipboard reply runs")
        let finished = expectation(description: "later work runs")
        let release = DispatchSemaphore(value: 0)
        let order = LockedOrder()
        defer { release.signal() }
        queue.async {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            order.append("input")
        }
        wait(for: [entered], timeout: 1)
        let started = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(queue.enqueueClipboardReply {
            XCTAssertFalse(Thread.isMainThread)
            order.append("clipboard")
            reply.fulfill()
        })
        XCTAssertFalse(queue.enqueueClipboardReply { XCTFail("duplicate reply") })
        XCTAssertTrue(queue.hasPendingClipboardReply)
        queue.async { order.append("destroy")
            finished.fulfill()
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.2)
        release.signal()
        wait(for: [reply, finished], timeout: 2)
        XCTAssertEqual(order.values, ["input", "clipboard", "destroy"])
        XCTAssertFalse(queue.hasPendingClipboardReply)
        let next = expectation(description: "later clipboard request")
        XCTAssertTrue(queue.enqueueClipboardReply { next.fulfill() })
        wait(for: [next], timeout: 1)
    }

    func testClipboardBoundCountsUTF8AndDoesNotTruncate() {
        XCTAssertEqual(TerminalWriteQueue.boundedClipboardText("é", maxBytes: 2), "é")
        XCTAssertEqual(TerminalWriteQueue.boundedClipboardText("éé", maxBytes: 3), "")
        XCTAssertEqual(TerminalWriteQueue.boundedClipboardText("", maxBytes: 0), "")
        XCTAssertEqual(TerminalWriteQueue.boundedClipboardText("x", maxBytes: -1), "")
    }

    private final class LockedOrder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func append(_ value: String) {
            lock.lock()
            defer { lock.unlock() }
            items.append(value)
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }
}
