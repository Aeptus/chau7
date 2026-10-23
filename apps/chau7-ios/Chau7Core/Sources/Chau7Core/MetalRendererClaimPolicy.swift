/// Protects the window-shared Metal renderer from stale SwiftUI updates.
///
/// A representable can be updated with an `isInteractive` value captured
/// before split-pane focus changed. Renderer ownership therefore requires
/// agreement between that rendered value and the controller's live focus.
public enum MetalRendererClaimPolicy {
    public static func shouldClaim(
        isInteractive: Bool,
        isAuthoritativeFocusOwner: Bool
    ) -> Bool {
        isInteractive && isAuthoritativeFocusOwner
    }
}
