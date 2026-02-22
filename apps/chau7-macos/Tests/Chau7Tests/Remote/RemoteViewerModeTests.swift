import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class RemoteViewerModeTests: XCTestCase {

    private var viewerMode: RemoteViewerMode!

    override func setUp() {
        super.setUp()
        viewerMode = RemoteViewerMode.shared
        // Reset state for each test
        viewerMode.stopSharing()
        viewerMode.connectedViewers.removeAll()
        viewerMode.pendingApprovals.removeAll()
        viewerMode.knownViewerIDs.removeAll()
        viewerMode.isEnabled = true
        viewerMode.shareLink = nil
    }

    override func tearDown() {
        viewerMode.stopSharing()
        viewerMode = nil
        super.tearDown()
    }

    // MARK: - Viewer Connection Flow

    func testViewerConnectionPendingToApproved() {
        viewerMode.startSharing()

        // Simulate incoming connection
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        // Should be pending
        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)
        XCTAssertEqual(viewerMode.pendingApprovals.first?.id, "viewer-1")
        XCTAssertEqual(viewerMode.pendingApprovals.first?.name, "Alice")
        XCTAssertEqual(viewerMode.pendingApprovals.first?.status, .pending)
        XCTAssertEqual(viewerMode.connectedViewers.count, 0)

        // Approve
        viewerMode.approveViewer("viewer-1")

        // Should be connected
        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
        XCTAssertEqual(viewerMode.connectedViewers.count, 1)
        XCTAssertEqual(viewerMode.connectedViewers.first?.id, "viewer-1")
        XCTAssertEqual(viewerMode.connectedViewers.first?.status, .connected)
        XCTAssertNotNil(viewerMode.connectedViewers.first?.connectedAt)
    }

    // MARK: - Deny Viewer

    func testDenyViewer() {
        viewerMode.startSharing()
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)

        viewerMode.denyViewer("viewer-1")

        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
    }

    func testDenyNonExistentViewerIsNoop() {
        viewerMode.startSharing()
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        viewerMode.denyViewer("viewer-nonexistent")

        // Original viewer still pending
        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)
    }

    // MARK: - Disconnect Viewer

    func testDisconnectViewer() {
        viewerMode.startSharing()
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")

        XCTAssertEqual(viewerMode.connectedViewers.count, 1)

        viewerMode.disconnectViewer("viewer-1")

        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
    }

    func testDisconnectNonExistentViewerIsNoop() {
        viewerMode.startSharing()
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")

        viewerMode.disconnectViewer("viewer-nonexistent")

        XCTAssertEqual(viewerMode.connectedViewers.count, 1)
    }

    // MARK: - Max Viewers Limit

    func testMaxViewersLimit() {
        viewerMode.startSharing()
        viewerMode.maxViewers = 2

        // Fill up to max with connected viewers
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")
        viewerMode.handleViewerConnection(viewerID: "viewer-2", viewerName: "Bob")
        viewerMode.approveViewer("viewer-2")

        XCTAssertEqual(viewerMode.connectedViewers.count, 2)

        // Next viewer should be rejected (max reached)
        viewerMode.handleViewerConnection(viewerID: "viewer-3", viewerName: "Charlie")

        XCTAssertEqual(viewerMode.connectedViewers.count, 2)
        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
    }

    // MARK: - Auto-Approve Known Viewers

    func testAutoApproveKnownViewer() {
        viewerMode.startSharing()
        viewerMode.autoApproveKnown = true
        viewerMode.knownViewerIDs.insert("viewer-1")

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        // Should skip pending and go straight to connected
        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
        XCTAssertEqual(viewerMode.connectedViewers.count, 1)
        XCTAssertEqual(viewerMode.connectedViewers.first?.status, .connected)
    }

    func testAutoApproveDisabledForKnownViewer() {
        viewerMode.startSharing()
        viewerMode.autoApproveKnown = false
        viewerMode.knownViewerIDs.insert("viewer-1")

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        // Should still be pending when auto-approve is off
        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)
        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
    }

    func testAutoApproveUnknownViewerStillPending() {
        viewerMode.startSharing()
        viewerMode.autoApproveKnown = true

        viewerMode.handleViewerConnection(viewerID: "viewer-unknown", viewerName: "Unknown")

        // Unknown viewer should be pending even with auto-approve on
        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)
        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
    }

    // MARK: - Trust / Revoke Viewer

    func testTrustViewer() {
        viewerMode.trustViewer("viewer-1")

        XCTAssertTrue(viewerMode.knownViewerIDs.contains("viewer-1"))
    }

    func testRevokeViewer() {
        viewerMode.startSharing()
        viewerMode.knownViewerIDs.insert("viewer-1")

        // Connect the viewer
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")
        XCTAssertEqual(viewerMode.connectedViewers.count, 1)

        // Revoke
        viewerMode.revokeViewer("viewer-1")

        XCTAssertFalse(viewerMode.knownViewerIDs.contains("viewer-1"))
        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
    }

    func testTrustMultipleViewers() {
        viewerMode.trustViewer("viewer-1")
        viewerMode.trustViewer("viewer-2")
        viewerMode.trustViewer("viewer-3")

        XCTAssertEqual(viewerMode.knownViewerIDs.count, 3)
        XCTAssertTrue(viewerMode.knownViewerIDs.contains("viewer-1"))
        XCTAssertTrue(viewerMode.knownViewerIDs.contains("viewer-2"))
        XCTAssertTrue(viewerMode.knownViewerIDs.contains("viewer-3"))
    }

    // MARK: - Share Link Generation

    func testShareLinkGeneration() {
        viewerMode.startSharing()

        XCTAssertNotNil(viewerMode.shareLink)
        XCTAssertTrue(viewerMode.shareLink?.hasPrefix("chau7://view/") ?? false)
        XCTAssertTrue(viewerMode.isSharing)
    }

    func testShareLinkClearedOnStop() {
        viewerMode.startSharing()
        XCTAssertNotNil(viewerMode.shareLink)

        viewerMode.stopSharing()

        XCTAssertNil(viewerMode.shareLink)
        XCTAssertFalse(viewerMode.isSharing)
    }

    func testStartSharingWhenDisabled() {
        viewerMode.isEnabled = false
        viewerMode.startSharing()

        XCTAssertNil(viewerMode.shareLink)
        XCTAssertFalse(viewerMode.isSharing)
    }

    func testStopSharingDisconnectsAllViewers() {
        viewerMode.startSharing()

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")
        viewerMode.handleViewerConnection(viewerID: "viewer-2", viewerName: "Bob")
        viewerMode.approveViewer("viewer-2")

        XCTAssertEqual(viewerMode.connectedViewers.count, 2)

        viewerMode.stopSharing()

        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
        XCTAssertNil(viewerMode.shareLink)
        XCTAssertFalse(viewerMode.isSharing)
    }

    // MARK: - Approve Non-Existent Viewer

    func testApproveNonExistentViewerIsNoop() {
        viewerMode.startSharing()

        viewerMode.approveViewer("nonexistent")

        XCTAssertEqual(viewerMode.connectedViewers.count, 0)
        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
    }

    // MARK: - Rejection at Max Viewers

    func testMaxViewersRejectionCleansUpPending() {
        viewerMode.startSharing()
        viewerMode.maxViewers = 1

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")

        // Try to add another — should not appear in pending or connected
        viewerMode.handleViewerConnection(viewerID: "viewer-2", viewerName: "Bob")

        XCTAssertEqual(viewerMode.connectedViewers.count, 1)
        XCTAssertEqual(viewerMode.pendingApprovals.count, 0)
        XCTAssertFalse(viewerMode.connectedViewers.contains(where: { $0.id == "viewer-2" }))
    }

    // MARK: - State Cleanup After Max Viewers

    func testSlotFreedAfterDisconnect() {
        viewerMode.startSharing()
        viewerMode.maxViewers = 1

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.approveViewer("viewer-1")
        XCTAssertEqual(viewerMode.connectedViewers.count, 1)

        // Disconnect frees the slot
        viewerMode.disconnectViewer("viewer-1")
        XCTAssertEqual(viewerMode.connectedViewers.count, 0)

        // New viewer should now be accepted
        viewerMode.handleViewerConnection(viewerID: "viewer-2", viewerName: "Bob")
        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)
        viewerMode.approveViewer("viewer-2")
        XCTAssertEqual(viewerMode.connectedViewers.count, 1)
        XCTAssertEqual(viewerMode.connectedViewers.first?.id, "viewer-2")
    }

    // MARK: - Duplicate Viewer Connection

    func testDuplicateViewerConnectionIgnored() {
        viewerMode.startSharing()

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")
        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        // Should not create duplicate pending entries
        XCTAssertEqual(viewerMode.pendingApprovals.count, 1)
    }

    // MARK: - Revoke While Pending

    func testRevokeViewerWhilePending() {
        viewerMode.startSharing()
        viewerMode.knownViewerIDs.insert("viewer-1")

        viewerMode.handleViewerConnection(viewerID: "viewer-1", viewerName: "Alice")

        // Revoke trust — should also remove from pending if there
        viewerMode.revokeViewer("viewer-1")

        XCTAssertFalse(viewerMode.knownViewerIDs.contains("viewer-1"))
    }
}
#endif
