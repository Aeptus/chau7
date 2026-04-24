import AppKit
import Foundation

/// Hover-card interaction state machine — shows a tab-preview card after a
/// brief mouse-hover delay, switches instantly between tabs while the card
/// is already visible, and dismisses via a short grace period so the user
/// can move the pointer from the tab chip onto the card itself.
///
/// Stored state (`hoverCardTabID`, `hoverCardAnchorX`, `hoverCardTimer`,
/// `hoverCardDismissTimer`) remains on `OverlayTabsModel` — stored
/// properties can't migrate into an extension. The methods that drive the
/// state machine live here.
///
/// Two delays, both carefully tuned:
///   - **0.4s appearance delay** on `tabHoverBegan` — avoids flashing
///     cards during rapid mouse sweeps across the tab bar.
///   - **0.15s dismiss delay** on `tabHoverEnded` / `hoverCardMouseExited`
///     — covers the user's travel time from tab chip to card body
///     without looking sluggish.
extension OverlayTabsModel {
    /// Called when the mouse enters a tab chip. Shows the hover card after a delay,
    /// or switches instantly if the card is already visible for another tab.
    func tabHoverBegan(id: UUID, anchorX: CGFloat) {
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
        hoverCardTimer?.cancel()

        if hoverCardTabID != nil {
            // Card already visible — switch instantly: stop old, start new
            stopProcessMonitoring(forTabID: hoverCardTabID)
            hoverCardTabID = id
            hoverCardAnchorX = anchorX
            startProcessMonitoring(forTabID: id)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.hoverCardTabID = id
            self?.hoverCardAnchorX = anchorX
            self?.startProcessMonitoring(forTabID: id)
        }
        hoverCardTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Called when the mouse exits a tab chip. Starts a short dismiss delay
    /// so the user can move the mouse from the tab to the card.
    func tabHoverEnded(id: UUID) {
        hoverCardTimer?.cancel()
        hoverCardTimer = nil

        guard hoverCardTabID == id else { return }
        startHoverCardDismissTimer()
    }

    /// Called when the mouse enters the hover card body.
    func hoverCardMouseEntered() {
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
    }

    /// Called when the mouse exits the hover card body.
    func hoverCardMouseExited() {
        startHoverCardDismissTimer()
    }

    /// Immediately hides the hover card (e.g. on tab select, close, rename, drag).
    func dismissHoverCard() {
        hoverCardTimer?.cancel()
        hoverCardTimer = nil
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
        stopProcessMonitoring(forTabID: hoverCardTabID)
        hoverCardTabID = nil
    }

    func startHoverCardDismissTimer() {
        hoverCardDismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stopProcessMonitoring(forTabID: self?.hoverCardTabID)
            self?.hoverCardTabID = nil
        }
        hoverCardDismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func startProcessMonitoring(forTabID id: UUID?) {
        guard let id, let session = tabs.first(where: { $0.id == id })?.session else { return }
        session.startProcessMonitoring()
    }

    func stopProcessMonitoring(forTabID id: UUID?) {
        guard let id, let session = tabs.first(where: { $0.id == id })?.session else { return }
        session.stopProcessMonitoring()
    }
}
