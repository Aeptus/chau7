# iOS App — SOLID / DRY Review

Scope: `apps/chau7-ios` (`Chau7RemoteApp` + `Chau7RemoteWidget` targets). Shared
protocol/model types live in `Chau7Core` (`apps/chau7-macos/Sources/Chau7Core`)
and are consumed by both platforms.

Date: 2026-06-16

> **Build status / handover note.** These changes were authored in an
> environment **without a Swift/Xcode toolchain**, so they have **not been
> compiled or run**. They are structured, mechanical refactors intended to be
> verified (`swift`-less iOS target → build in Xcode) and finished by a
> developer with the toolchain. New source files were added to the
> `Chau7RemoteApp/` folder, which is a `PBXFileSystemSynchronizedRootGroup` in
> the project, so they are picked up automatically — confirm target membership
> if Xcode reports "cannot find type in scope".

## Summary

The codebase was already in good shape: value types used well, crypto /
transport / buffering split into focused types, and a clean closed frame
dispatch. The dominant issue was `RemoteClient`, a ~1.7k-line `@MainActor` god
object carrying ~12 responsibilities.

This pass extracts the cleanly-separable concerns out of `RemoteClient` into
single-responsibility collaborators, replaces the stringly-typed status with an
enum, and clears the smaller DRY/OCP items. The tightly-coupled transport /
session / approval **control flow** is intentionally left in `RemoteClient`
(see "Remaining").

## Applied

### DRY

1. **Approval-notification scheduling** was copy-pasted in two methods — unified
   (originally into a helper, now owned by `RemoteNotificationScheduler`).
2. **Stringly-typed notification identifiers** (category IDs, action IDs,
   `userInfo` keys) duplicated across scheduler and handler → centralized in
   `RemoteNotificationID` (`RemoteModels.swift`), referenced from both
   `RemoteClient` and `AppDelegate`. Left distinct contracts (JSON `CodingKeys`,
   telemetry metadata, URL query params) decoupled on purpose.

### SRP — collaborators extracted from `RemoteClient`

Each new type mirrors the existing `RemoteReconnectBackoff` /
`RemoteTerminalOutputStore` pattern (small, focused, independently testable):

- **`RemoteNotificationScheduler`** (`RemoteNotificationScheduler.swift`) — all
  `UserNotifications` content building, scheduling, and removal for approvals and
  interactive prompts. Collapses the previously-duplicated content scaffolding
  (`sound`/`interruptionLevel`/`relevanceScore`/trigger) into one `makeContent`
  factory. `RemoteClient` keeps only the *whether-to-notify* gate
  (`shouldScheduleLocalApprovalNotification`).
- **`RemotePairingStore`** (`RemotePairingStore.swift`) — all Keychain access for
  the device key, Mac public key, pairing payload, and trusted identity. Removes
  the raw `"ios_private_key"` / `"mac_public_key"` / `"pairing_payload"` /
  `"trusted_pairing_identity"` string literals and the mixed static/instance
  persistence helpers from `RemoteClient`.
- **`RemoteTelemetryBuffer`** (`RemoteTelemetryBuffer.swift`) — bounded FIFO for
  pre-session telemetry events (capacity/eviction policy in one value type).
- **`BackgroundKeepalive`** (`BackgroundKeepalive.swift`) — the single
  `UIBackgroundTask` lifecycle + expiration race. `RemoteClient` supplies an
  `onExpire` closure for its own teardown.

### OCP / clarity

- **`RemoteConnectionStatus`** (`RemoteConnectionStatus.swift`) — replaces the
  free-form `status: String`. Display text lives in one `displayText`; views
  switch over `isEncryptedSession` / the enum instead of matching magic strings
  like `"Encrypted"` / `"Session ready"` / `"Connecting"`. Updated
  `RemoteClient`, `TerminalView`, `SettingsView`.
- **Widget status styling** — four parallel `switch`es over `RemoteActivityStatus`
  (`backgroundTint` / `tint` / `iconName` / `shortStatusLabel`) collapsed into a
  single `RemoteActivityStatus.widgetStyle` → `ActivityStatusStyle` mapping.
- **`RemoteClient.appVersion`** now reads `CFBundleShortVersionString` (falling
  back to `"1.1.0"`) instead of a hard-coded constant that could drift.
- **`RemoteTerminalRendererStore`** — dropped the unused `fallbackText:` /
  `data:` parameters from `setActiveTab(_:)` and `replaceSnapshot(for:)`
  (ISP: callers no longer pass values the methods ignored). Updated call sites.

## Remaining (next, needs the compiler in the loop)

1. **Transport / session / approval split.** `RemoteClient` still owns the
   WebSocket receive loop, `connectionGeneration` invalidation, handshake/
   reconnect tasks, crypto session establishment, and the approval response
   state machine. These share mutable control flow (generation counters,
   recursive `listen()`, in-flight response bookkeeping) that is risky to split
   without iterative compilation. Suggested targets: `RemoteTransport`,
   `RemoteSession`, `ApprovalCoordinator`. Doing this also requires deciding how
   the observed UI state (`pendingApprovals`, `outputText`, `tabs`, `status`)
   is exposed to views (facade forwarding vs. nested `@Observable`).
2. **DIP / testability.** `RemoteClient.shared` is referenced directly from
   `AppDelegate`, `Chau7RemoteApp`, and `TermKey`. Once #1 lands, inject the
   coordinator through the SwiftUI environment instead of reaching for `.shared`
   so previews/tests have a seam.

## What's already good (keep doing this)

- Pure, isolated units: `RemoteReconnectBackoff`, `ANSIStripper`,
  `RemoteActivityURLAction.init?(url:)`, `RemoteTerminalRenderStateDecoder`, and
  now `RemoteTelemetryBuffer` / `RemotePairingStore` / `RemoteConnectionStatus`.
- Closed-set frame dispatch via `RemoteFrameType`.
- Crypto contained in `RemoteCryptoSession` with `nonisolated` methods.
- `AppSettings` / `RemoteNotificationID` / `RemoteConnectionStatus` centralize
  the keys, identifiers, and status text that used to be scattered literals.
</content>
