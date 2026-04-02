import Foundation
import Chau7Core

/// Read-only remote viewing of terminal sessions.
/// Extends the existing E2E encrypted remote control to support
/// view-only connections where the viewer can see terminal output
/// but cannot send input.
///
/// Permission model:
/// - Owner must explicitly approve each viewer
/// - Viewers get a unique link/token
/// - Owner can revoke viewer access at any time
/// - Viewer count is shown in the status bar
@MainActor
@Observable
final class RemoteViewerMode {
    static let shared = RemoteViewerMode()

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "feature.remoteViewer")
            Log.info("RemoteViewerMode: \(isEnabled ? "enabled" : "disabled")")
        }
    }

    var isSharing = false
    var connectedViewers: [RemoteViewer] = []
    var pendingApprovals: [RemoteViewer] = []
    var shareLink: String?

    /// Maximum simultaneous viewers
    var maxViewers: Int {
        get { UserDefaults.standard.integer(forKey: "remoteViewer.maxViewers").clamped(to: 1 ... 10) }
        set { UserDefaults.standard.set(newValue, forKey: "remoteViewer.maxViewers") }
    }

    /// Whether to auto-approve known viewers
    var autoApproveKnown: Bool {
        get { UserDefaults.standard.bool(forKey: "remoteViewer.autoApproveKnown") }
        set { UserDefaults.standard.set(newValue, forKey: "remoteViewer.autoApproveKnown") }
    }

    /// Known viewer IDs that are auto-approved
    var knownViewerIDs: Set<String> = []

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: "feature.remoteViewer")
        loadKnownViewers()
        Log.info("RemoteViewerMode initialized: enabled=\(isEnabled)")
    }

    // MARK: - Sharing

    func startSharing() {
        guard isEnabled else {
            Log.warn("RemoteViewerMode: cannot start sharing, not enabled")
            return
        }

        // Generate a unique share token
        let token = UUID().uuidString.prefix(8).lowercased()
        shareLink = "chau7://view/\(token)"
        isSharing = true
        Log.info("RemoteViewerMode: started sharing, link=\(shareLink ?? "none")")
    }

    func stopSharing() {
        // Disconnect all viewers
        for viewer in connectedViewers {
            disconnectViewer(viewer.id)
        }
        connectedViewers.removeAll()
        pendingApprovals.removeAll()
        shareLink = nil
        isSharing = false
        Log.info("RemoteViewerMode: stopped sharing")
    }

    // MARK: - Viewer Management

    func approveViewer(_ viewerID: String) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.id == viewerID }) else { return }
        guard connectedViewers.count < maxViewers else {
            Log.warn("RemoteViewerMode: cannot approve viewer \(viewerID), max viewers (\(maxViewers)) reached")
            return
        }
        var viewer = pendingApprovals.remove(at: idx)
        viewer.status = .connected
        viewer.connectedAt = Date()
        connectedViewers.append(viewer)
        Log.info("RemoteViewerMode: approved viewer \(viewerID)")
    }

    func denyViewer(_ viewerID: String) {
        pendingApprovals.removeAll { $0.id == viewerID }
        Log.info("RemoteViewerMode: denied viewer \(viewerID)")
    }

    func disconnectViewer(_ viewerID: String) {
        connectedViewers.removeAll { $0.id == viewerID }
        Log.info("RemoteViewerMode: disconnected viewer \(viewerID)")
    }

    func trustViewer(_ viewerID: String) {
        knownViewerIDs.insert(viewerID)
        saveKnownViewers()
        Log.info("RemoteViewerMode: trusted viewer \(viewerID)")
    }

    func revokeViewer(_ viewerID: String) {
        knownViewerIDs.remove(viewerID)
        disconnectViewer(viewerID)
        saveKnownViewers()
        Log.info("RemoteViewerMode: revoked viewer \(viewerID)")
    }

    // MARK: - Incoming Connection

    func handleViewerConnection(viewerID: String, viewerName: String) {
        let viewer = RemoteViewer(id: viewerID, name: viewerName)

        // Auto-approve known viewers if under capacity
        if autoApproveKnown, knownViewerIDs.contains(viewerID) {
            guard connectedViewers.count < maxViewers else {
                Log.warn("RemoteViewerMode: rejected auto-approve for \(viewerID), max viewers reached")
                return
            }
            var approved = viewer
            approved.status = .connected
            approved.connectedAt = Date()
            connectedViewers.append(approved)
            Log.info("RemoteViewerMode: auto-approved known viewer \(viewerID)")
        } else {
            // Add to pending — capacity is checked when owner approves
            pendingApprovals.append(viewer)
            Log.info("RemoteViewerMode: viewer \(viewerID) pending approval")
            NotificationCenter.default.post(name: .viewerPendingApproval, object: nil, userInfo: ["viewer": viewer])
        }
    }

    /// Send terminal output to all connected viewers
    func broadcastToViewers(data: Data) {
        guard isSharing, !connectedViewers.isEmpty else { return }
        // In real implementation, send via the E2E encrypted channel
        Log.trace("RemoteViewerMode: broadcast \(data.count) bytes to \(connectedViewers.count) viewers")
    }

    // MARK: - Persistence

    private func loadKnownViewers() {
        if let ids = UserDefaults.standard.stringArray(forKey: "remoteViewer.knownIDs") {
            knownViewerIDs = Set(ids)
        }
    }

    private func saveKnownViewers() {
        UserDefaults.standard.set(Array(knownViewerIDs), forKey: "remoteViewer.knownIDs")
    }
}

// MARK: - Supporting Types

struct RemoteViewer: Identifiable, Equatable {
    let id: String
    var name: String
    var status: ViewerStatus = .pending
    var connectedAt: Date?

    var connectionDuration: String {
        guard let start = connectedAt else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

enum ViewerStatus: String {
    case pending, connected, disconnected
}

extension Notification.Name {
    static let viewerPendingApproval = Notification.Name("com.chau7.viewerPendingApproval")
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
