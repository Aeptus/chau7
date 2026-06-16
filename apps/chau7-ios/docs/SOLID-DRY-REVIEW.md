# iOS App — SOLID / DRY Review

Scope: `apps/chau7-ios` (`Chau7RemoteApp` + `Chau7RemoteWidget` targets). Shared
protocol/model types live in `Chau7Core` (`apps/chau7-macos/Sources/Chau7Core`)
and are consumed by both platforms.

Date: 2026-06-16

## Summary

The codebase is, on the whole, in good shape: value types are used well, the
crypto/transport/buffering concerns are already split into focused types
(`RemoteCryptoSession`, `RemoteTerminalOutputStore`, `RemoteTerminalRendererStore`,
`RemoteReconnectBackoff`, `RemoteLiveActivityManager`), and the frame-decode
pipeline (`RemoteFrameProcessor` → `applyProcessedFrame` → `handleProcessedFrame`)
is a clean closed dispatch. Tests-friendly helpers (`RemoteReconnectBackoff`,
`ANSIStripper`, `RemoteActivityURLAction`) are pure and isolated.

The dominant structural issue is `RemoteClient` (a ~1.7k-line `@MainActor`
god object) carrying ~12 responsibilities. Most other findings are localized
DRY issues, some of which are fixed in this change set.

## Changes applied in this review

1. **DRY — duplicated approval-notification scheduling.** The
   `UNMutableNotificationContent` construction + `UNNotificationRequest` add
   block was copy-pasted in both `applyPendingApprovals(_:)` and
   `upsertPendingApproval(_:)`. Extracted into a single
   `scheduleApprovalNotification(for:)` helper (which now also owns the
   `shouldScheduleLocalApprovalNotification` guard).

2. **DRY — stringly-typed notification identifiers.** Category IDs
   (`"MCP_APPROVAL"`, `"INTERACTIVE_PROMPT"`), action IDs (`"APPROVE"`,
   `"DENY"`), and `userInfo` keys (`"request_id"`, `"prompt_id"`, `"tab_id"`,
   `"open_approvals"`, `"approved"`) were duplicated across `RemoteClient`
   (scheduler) and `AppDelegate` (handler). A typo on either side silently
   breaks the action contract. Centralized into `RemoteNotificationID` in
   `RemoteModels.swift` and referenced from both sites.

   Deliberately left as literals because they belong to *different* contracts:
   JSON `CodingKeys` (wire protocol), telemetry `metadata` keys, and
   `RemoteActivityURLAction` URL query params. Coupling them to the
   notification constants would be false sharing.

## Recommended follow-ups (not applied — larger / require compiler in loop)

### 1. SRP — decompose `RemoteClient` (highest impact)

`RemoteClient` currently owns all of: WebSocket transport + receive loop,
connection-generation invalidation, crypto session establishment, pairing &
trusted-identity Keychain persistence, private-key management, reconnect
orchestration, frame encode/decode dispatch, terminal-output flush
coordination, the approval state machine + history, interactive prompts,
local-notification scheduling, telemetry buffering/emission, Live Activity
forwarding, background-task keepalive, push-token/auth state, deep-link URL
actions, and the pending-state HTTP fetch.

Suggested collaborators (each independently testable, mirroring the existing
`RemoteReconnectBackoff`/`RemoteTerminalOutputStore` pattern):

- `RemoteTransport` — owns `URLSessionWebSocketTask`, `connectionGeneration`,
  `listen()`, `send(_:)`, `nextSeq()`. Exposes an async stream of decoded
  frames; hides generation bookkeeping.
- `RemoteSession` — `nonceIOS/nonceMac/macPublicKey/crypto`, key agreement and
  `establishSessionIfPossible()`.
- `PairingStore` — wraps all `KeychainStore` access for pairing payload,
  trusted identity, and the iOS/Mac keys (currently a mix of `static` and
  instance methods plus raw `"mac_public_key"`/`"ios_private_key"` string keys
  scattered through the class).
- `ApprovalCoordinator` — `pendingApprovals`, `pendingApprovalResponses`,
  `approvalResponsesInFlight`, response state machine, `approvalHistory`.
- `RemoteNotificationScheduler` — building/scheduling/removing
  `UNNotificationRequest`s (approval + interactive prompt). Today the content
  scaffolding (`sound`/`interruptionLevel`/`relevanceScore`/trigger) is
  repeated across the approval and interactive-prompt builders; a single
  `makeContent(...)` factory removes that.
- `TelemetryEmitter` — buffer + flush of `RemoteClientTelemetryEvent`.
- `BackgroundKeepalive` — `beginBackgroundKeepalive`/`end`/expiration.

`RemoteClient` then becomes a thin coordinator wiring these together. This is
the change that most improves testability — almost none of the current logic
can be exercised without a live socket and `@MainActor` singleton.

### 2. Stringly-typed connection status (DRY + fragility)

`status` is a free `String`. Magic-string comparisons against it are spread
across files and silently break on a typo:

- `TerminalView.statusColor` compares against `"Encrypted"` / `"Session ready"`.
- `RemoteClient.scheduleHandshake` compares against `"Connecting"` and assigns
  `"Waiting for your Mac..."`.
- Status strings are assigned in ~15 places in `RemoteClient`.

Introduce a `RemoteConnectionStatus` enum with a `displayText` (and optionally
`indicatorColor`) computed property. Views switch on the enum instead of
string-matching, and the human-readable text lives in exactly one place.

### 3. DIP / testability — singleton coupling

`RemoteClient.shared` is referenced directly from `AppDelegate`,
`Chau7RemoteApp`, and `TermKey`. Views take a concrete `RemoteClient`. For
SwiftUI `@Observable` this is idiomatic, but there's no seam for previews or
unit tests. If/when `RemoteClient` is decomposed (#1), inject the coordinator
via the environment rather than reaching for `.shared`, and let the
`AppDelegate` receive its dependency rather than hard-referencing the
singleton.

### 4. OCP/DRY — widget status styling

`Chau7RemoteWidget` has four parallel `switch` statements over
`RemoteActivityStatus` (`backgroundTint`, `tint`, `iconName`,
`shortStatusLabel`). Adding a status means editing four sites. Collapse into a
single `RemoteActivityStatus.style` mapping returning a small
`ActivityStatusStyle { tint; backgroundOpacity; iconName; shortLabel }` value.

### 5. Minor

- `RemoteTerminalRendererStore.setActiveTab(_:fallbackText:)` and
  `replaceSnapshot(_:for:)` ignore their `fallbackText` / `data` parameters
  (they only trigger a refresh). Either consume them or drop the parameters to
  avoid a misleading API (ISP — callers pass data the method doesn't use).
- `applyPendingApprovals` and `upsertPendingApproval` still duplicate the
  "upsert into `pendingApprovals` keyed by `requestID`" shape; once an
  `ApprovalCoordinator` exists this collapses naturally.
- `RemoteClient.appVersion` is a hard-coded `"1.1.0"` string constant; prefer
  reading `CFBundleShortVersionString` so it can't drift from the build.

## What's already good (keep doing this)

- Pure, isolated, testable units: `RemoteReconnectBackoff`, `ANSIStripper`,
  `RemoteActivityURLAction.init?(url:)`, `RemoteTerminalRenderStateDecoder`.
- Closed-set frame dispatch via `RemoteFrameType` — adding a frame type is a
  single `switch` case, compiler-enforced.
- Crypto concerns fully contained in `RemoteCryptoSession` with `nonisolated`
  methods suitable for off-main work.
- `AppSettings` already centralizes `@AppStorage` keys/defaults — the model to
  follow for the status and notification constants above.
</content>
