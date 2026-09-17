/// Selection rules shared by the Mac stream producer and the iPhone viewer.
///
/// A remote tab selection is a stream subscription. Once established, Mac
/// window focus is only local UI state and must not replace that subscription.
public enum RemoteTabSelectionPolicy {
    public static func resolvedActiveTabID(
        currentActiveTabID: UInt32,
        incoming tabs: [RemoteTabDescriptor]
    ) -> UInt32 {
        if currentActiveTabID != 0,
           tabs.contains(where: { $0.tabID == currentActiveTabID }) {
            return currentActiveTabID
        }
        return tabs.first(where: \.isActive)?.tabID ?? tabs.first?.tabID ?? 0
    }

    public static func followsMacFocus(hasExplicitRemoteSelection: Bool) -> Bool {
        !hasExplicitRemoteSelection
    }
}
