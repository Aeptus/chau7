# Chau7Core

Pure Swift library with zero UI dependencies, used by the iOS remote app, its widget and their tests. It started as the shared core of the former Swift macOS app; the logic only that app used has been removed, so everything here is reachable from the iOS targets.

## What belongs here

- Remote protocol: `RemoteFrame`, `FrameParser`, `RemoteWirePayloads`, `RemoteCryptoSession`, `RemoteReplayGuard`, `RelayToken`
- Remote state: `PendingStateReconciler`, `RemoteActivityState`, `RemoteReconnectBackoff`, `RemoteTabSelectionPolicy`
- Terminal data: `RemoteTerminalGridSnapshot`, `RemoteOutputBuffering`, `ANSIStripper`, `TerminalColorScheme`, `TerminalKeyPress`
- Prompts and approvals: `InteractivePromptDetector`, `RemoteInteractivePrompt`, `ApprovalSeverity`
- Notification model: `CanonicalNotificationModel`, `NotificationContentFormatter`, provider adapters

## What does NOT belong here

- Anything that imports UIKit, SwiftUI, ActivityKit or Metal
- Singleton managers (those live in the app targets)
- View models or UI state
- Code no iOS target uses

## Testing

The tests in `Tests/Chau7CoreTests/` of this package exercise the target via `@testable import Chau7Core`.

```bash
swift test --package-path apps/chau7-ios/Chau7Core
```
