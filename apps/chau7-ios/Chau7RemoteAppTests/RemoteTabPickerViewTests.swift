import Chau7Core
import SwiftUI
import UIKit
import XCTest

/// Exercise the real SwiftUI scroll surface, rather than only its focus policy.
@MainActor
final class RemoteTabPickerViewTests: XCTestCase {
    func testOpeningCentersSelectedTabAndRefreshPreservesUserScroll() async throws {
        let tabs = (1...60).map { id in
            RemoteTabDescriptor(tabID: UInt32(id), title: "Session \(id)", projectName: "Chau7",
                                branchName: "main", aiProvider: "Codex", isActive: false,
                                isMCPControlled: false)
        }
        let snapshot = RemoteTabPickerSnapshot(orderedTabs: tabs)
        let host = UIHostingController(rootView: picker(snapshot, activeTabID: 45))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        try await settleLayout(host)
        let scroll = try XCTUnwrap(scrollViews(in: host.view).first {
            $0.contentSize.height > 2000 && $0.bounds.height > 300
        })
        XCTAssertGreaterThan(scroll.contentOffset.y, 2000, "picker should open around session 45")

        // Browse away from the selected tab, then update metadata. It must
        // update the row without re-focusing the selection or recreating scroll.
        scroll.setContentOffset(CGPoint(x: 0, y: 600), animated: false)
        let browsedOffset = scroll.contentOffset.y
        var changed = tabs
        changed[0] = RemoteTabDescriptor(tabID: 1, title: "Renamed session", projectName: "Chau7",
                                         branchName: "feature", isActive: true, isMCPControlled: false)
        host.rootView = picker(RemoteTabPickerSnapshot(orderedTabs: changed), activeTabID: 45)
        try await settleLayout(host)
        XCTAssertEqual(scroll.contentOffset.y, browsedOffset, accuracy: 2)

        // Duplicate refreshes and transient reconnect presentation also keep
        // the same scroll view and browsing offset.
        host.rootView = picker(RemoteTabPickerSnapshot(orderedTabs: changed), activeTabID: 45)
        try await settleLayout(host)
        XCTAssertEqual(scroll.contentOffset.y, browsedOffset, accuracy: 2)
        host.rootView = picker(RemoteTabPickerSnapshot(orderedTabs: changed), activeTabID: 45,
                               inventoryState: .syncing, connected: false)
        try await settleLayout(host)
        XCTAssertEqual(scroll.contentOffset.y, browsedOffset, accuracy: 2)

        // A real selection change should bring the newly open tab into view.
        host.rootView = picker(snapshot, activeTabID: 55)
        try await settleLayout(host)
        XCTAssertGreaterThan(scroll.contentOffset.y, 3000)

    }

    private func picker(
        _ snapshot: RemoteTabPickerSnapshot, activeTabID: UInt32,
        inventoryState: RemoteTabInventoryState = .ready, connected: Bool = true
    ) -> EquatableView<RemoteTabPickerView> {
        RemoteTabPickerView(snapshot: snapshot, activeTabID: activeTabID,
                            inventoryState: inventoryState, isConnected: connected, onSelect: { _ in }).equatable()
    }

    private func settleLayout<V: View>(_ host: UIHostingController<V>) async throws {
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.view.layoutIfNeeded()
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? [])
            + view.subviews.flatMap { scrollViews(in: $0) }
    }
}
