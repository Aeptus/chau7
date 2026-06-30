# iOS App — Hardening & Efficiency Plan

Companion to `SOLID-DRY-REVIEW.md`. Covers security hardening and performance
for the Chau7 Remote iOS app and, where the protocol requires it, the Go relay
client (`services/chau7-remote`) and shared `Chau7Core`.

> **Environment note.** This repo's working environment has **no Swift/Xcode/Go
> toolchain**, so anything here that changes the handshake or crypto must be
> built and exercised end-to-end (real iOS device ↔ Mac relay) by a developer
> with the toolchain. Each item is tagged **[needs-e2e]** where that applies.

## Priority tiers

| Tier | Item | Scope |
|---|---|---|
| **P0** | 1. Direction-separated AEAD nonces (fix nonce reuse) | iOS + Go + version bump |
| **P0** | 2. iOS receive-side replay protection | iOS only |
| **P1** | 3. Enforce `wss://` + relay cert pinning | iOS |
| **P1** | 7. Cache `JSONEncoder`/`Decoder`/`ISO8601DateFormatter`/device name | iOS |
| **P2** | 4. Lock-screen notification privacy | iOS |
| **P2** | 5. Mac key fingerprint verification UX | iOS |
| **P2** | 8. Frame-rate backpressure / DoS guard | iOS (+ Go optional) |
| **P2** | 9. Threshold the per-frame `Task.detached` | iOS |
| **P3** | 6. Consolidate crypto into `Chau7Core` + unit tests | iOS + Chau7Core |
| **P3** | 10. Telemetry batching | iOS + Go |
| **P3** | 11. ANSIStripper byte scanner / renderer dirty-rect | iOS |

## Recommended execution order

Front-load the safe, iOS-only, additive changes (no protocol break, testable in
isolation), then the coordinated crypto bump, then polish.

```
Phase A (safe, iOS-only, no wire change)   → items 2, 7, 3, 4, 9
Phase B (coordinated protocol bump)        → items 1, 6   [needs-e2e]
Phase C (UX + robustness)                  → items 5, 8
Phase D (perf polish, optional)            → items 10, 11
```

---

## Phase A — safe iOS-only changes

### Item 2 — Receive-side replay protection  **[P0]**
- **Why:** The Go side rejects stale frames (`agent.go:930`, `maxReceivedSeq`).
  iOS does not — `RemoteFrameProcessor.process` decrypts and dispatches with no
  sequence check (`RemoteClient.swift`). A malicious relay can replay captured
  encrypted frames (e.g. `input`, `tabList`).
- **Where:** `RemoteCrypto.swift` (`RemoteCryptoSession`), `RemoteClient.swift`
  (`RemoteFrameProcessor` / `applyProcessedFrame`).
- **How:** Track `maxReceivedSeq: UInt64` on the session (or client). In the
  decrypt/dispatch path, reject `frame.seq <= maxReceivedSeq` for encrypted
  frames; on success set `maxReceivedSeq = frame.seq`. Reset to 0 everywhere
  `seqCounter` resets (`disconnect`, `handlePairAccept`, session establish).
  Keep unencrypted handshake frames (hello/pair*) exempt, matching Go.
- **Risk:** Low. Additive; only rejects out-of-order/duplicate frames. Confirm
  the relay never legitimately re-sends a lower seq after reconnect (Go resets
  `maxReceivedSeq = 0` on `resetSession`, `agent.go:895` — mirror that).
- **Test:** Unit test (see item 6) feeding a duplicate frame → rejected.

### Item 7 — Cache expensive allocations on hot paths  **[P1]**
- **Why:** Fresh `JSONEncoder()`/`JSONDecoder()` at 15 sites, several per-frame;
  `ISO8601DateFormatter()` allocated **per approval** (`RemoteClient.swift:1347`,
  expensive); `UIDevice.current.name` read on every telemetry event.
- **Where:** `RemoteClient.swift`, `RemoteModels.swift`, `RemotePairingStore.swift`.
- **How:**
  - Add `static let` shared `JSONEncoder`/`JSONDecoder` (MainActor-scoped; all
    JSON encode/decode runs on MainActor — the detached path only does binary
    `RemoteFrame.decode`). Replace the 15 call sites.
  - Add a `static let iso8601 = ISO8601DateFormatter()` (thread-safe) for
    `parseRemoteTimestamp`.
  - Cache `deviceName` once in `init` instead of reading `UIDevice.current.name`
    in `emitTelemetry`.
- **Risk:** Very low. Behavior-identical; pure allocation reduction.
- **Test:** Existing flows unchanged; spot-check decode of each payload type.

### Item 3 — Enforce `wss://` + relay pinning  **[P1]**
- **Why:** `connect()` uses `pairing.relayURL` with no scheme check
  (`RemoteClient.swift:160`); `relayAPIURLComponents` maps `ws→http`. Cleartext
  transport leaks metadata and removes a defense layer.
- **Where:** `RemoteClient.swift` (`connect`, `relayAPIURLComponents`),
  `PairingSheetView.swift` (validate on paste), `Info.plist` (ATS).
- **How:** Reject any pairing whose `relayURL` scheme is not `wss`/`https`;
  surface a clear error in the pairing sheet. Keep ATS strict (no arbitrary
  loads). Optionally pin the relay leaf/intermediate via a
  `URLSessionDelegate` `didReceive challenge` (the relay host is known), with a
  documented rotation path.
- **Risk:** Low–medium. Pinning needs a cert-rotation story; ship scheme
  enforcement first, pinning behind a follow-up once the relay cert lifecycle is
  documented.
- **Test:** Paste a `ws://` payload → rejected; `wss://` → connects.

### Item 4 — Lock-screen notification privacy  **[P2]**
- **Why:** Approval/prompt bodies include command, flagged action, and
  abbreviated cwd at `.timeSensitive` (`RemoteNotificationScheduler.swift`),
  visible on the lock screen.
- **Where:** `RemoteNotificationScheduler.swift`, `SettingsView.swift` (toggle).
- **How:** Add a "Hide sensitive details on lock screen" setting (default on).
  When set, schedule a generic title/body ("Command approval needed") and reveal
  detail only in-app. Optionally key off device-locked state.
- **Risk:** Low.
- **Test:** Toggle on → notification body generic; in-app cards still detailed.

### Item 9 — Threshold the per-frame `Task.detached`  **[P2]**
- **Why:** Every received frame spawns a detached task for decode/decrypt
  (`RemoteClient.swift:412`). Worth it for large `output`/`snapshot`/grid frames,
  pure overhead for tiny control frames.
- **Where:** `RemoteClient.swift` (`listen`/processing).
- **How:** Only offload when `data.count` exceeds a threshold (e.g. 8 KB);
  process small frames inline on MainActor. Tune the threshold with Instruments.
- **Risk:** Low. Keep ordering guarantees (still serialize via the receive loop).
- **Test:** Mixed traffic still renders correctly; check signpost timings.

---

## Phase B — coordinated protocol bump

### Item 1 — Direction-separated AEAD nonces  **[P0] [needs-e2e]**
- **Why (critical):** iOS and Go derive the **same** key and **same** 4-byte
  nonce prefix and both start `seq` at 1 (`RemoteCrypto.swift:15-31`,
  `agent.go:898-917,243`). Nonce = `prefix‖seqLE`, so the first encrypted frame
  in each direction reuses key+nonce → ChaCha20-Poly1305 nonce reuse
  (keystream-XOR plaintext recovery + Poly1305 forgery). A semi-trusted relay
  can exploit it, defeating E2E.
- **Where:** `RemoteCrypto.swift` (iOS), `agent.go` (`newCryptoSession`,
  `makeNonce`, encrypt/decrypt), `Chau7Core/RemoteFrame.swift` (version),
  HELLO/handshake on both ends.
- **How (design — pick one, apply identically both sides):**
  - **Option A (minimal):** keep one key, derive two prefixes —
    `prefixC2S = HKDF(shared, info:"nonce-c2s")`,
    `prefixS2C = HKDF(shared, info:"nonce-s2c")`. The client (iOS) encrypts with
    C2S and decrypts with S2C; the Mac does the inverse. Overlapping seq spaces
    are now safe (distinct prefixes).
  - **Option B (stronger):** derive two directional keys
    (`info:"key-c2s"` / `"key-s2c"`) and keep a single prefix.
  - Recommend **A** for the smallest, most auditable change.
- **Versioning / no insecure downgrade:** bump `RemoteFrame` version to `2`;
  `decode` must accept `2` and the handshake must negotiate it. Because the same
  vendor ships both ends, **require v2 and reject v1** (no fallback to the broken
  scheme — fallback would be a downgrade vector). Old clients simply fail to pair
  with a clear message and must update.
- **Risk:** High blast radius (breaks the wire). Mitigate with the version gate,
  shared test vectors, and staged rollout. **Cannot be validated in this repo
  environment** — requires real iOS↔relay handshake.
- **Test:** Known-answer vectors shared between Swift and Go (same shared secret
  + nonces → identical key/prefixes/ciphertext); round-trip both directions;
  assert a v1 peer is rejected.

### Item 6 — Consolidate crypto into `Chau7Core` + unit tests  **[P3, do with item 1]**
- **Why:** `RemoteCryptoSession` lives only in the iOS target, so it has no test
  coverage and duplicates the Go logic conceptually. Moving it into `Chau7Core`
  gives one audited Swift implementation testable from the macOS XCTest target.
- **Where:** new `Chau7Core/RemoteCryptoSession.swift`; iOS imports it; tests in
  `apps/chau7-macos/Tests/Chau7Tests/`.
- **How:** Move the type into `Chau7Core` (it already only depends on CryptoKit +
  `RemoteFrame`). Add tests: encrypt→decrypt round-trip, replay rejection,
  direction separation, tamper (bit-flip) rejection, KATs matching Go.
- **Risk:** Low (move + import); pairs naturally with item 1 since both touch the
  same file.

---

## Phase C — UX & robustness

### Item 5 — Mac key fingerprint verification  **[P2]**
- **Why:** Trust is TOFU via the pasted payload. A visible fingerprint lets users
  confirm they're paired with the right Mac (defense against a tampered payload).
- **Where:** `SettingsView.swift`, reuse `CryptoUtils.fingerprint` (`RemoteModels.swift:344`).
- **How:** Show the stored Mac public-key fingerprint in Settings → Connection,
  and the local iOS key fingerprint, so both can be compared with the Mac UI.
- **Risk:** Low.

### Item 8 — Frame-rate backpressure / DoS guard  **[P2]**
- **Why:** A hostile relay can flood frames; the detached-task-per-frame path has
  no rate cap (byte caps exist for output, not frame count).
- **Where:** `RemoteClient.swift` (receive loop), optionally `agent.go`.
- **How:** Add a simple token-bucket / max in-flight processing window on the
  receive loop; drop or coalesce beyond a ceiling and emit telemetry. Pair with
  item 9's threshold.
- **Risk:** Medium — tune so legitimate bursts (large snapshots) aren't dropped.

---

## Phase D — perf polish (optional)

### Item 10 — Telemetry batching  **[P3] [needs-e2e]**
- Coalesce telemetry events into one frame on a short timer instead of one
  encrypted frame per event. Requires the Go side to accept a batched payload →
  coordinated, lower priority.

### Item 11 — ANSIStripper byte scanner / renderer dirty-rect  **[P3]**
- `ANSIStripper` already offloads >4 KB; if it shows in traces, replace the
  scalar-by-scalar `String` build with a byte scanner.
- The experimental grid canvas redraws the full viewport each update; add
  dirty-rect invalidation if profiling justifies it.

---

## Cross-cutting

**Testing strategy**
- Pure/unit-testable now (via item 6 in `Chau7Core`): crypto round-trip, replay,
  direction separation, frame decode bounds, `RemoteActivityURLAction`, backoff.
- **[needs-e2e]** (toolchain dev): the handshake/version negotiation (item 1),
  wss enforcement against a live relay, notification rendering, Live Activity.
- Profile items 7/9/11 with Instruments (Time Profiler + os_signpost regions
  already present: `RemoteFrameProcess`, `RemoteAppendOutput`, `ANSIStrip`).

**Rollout / compatibility**
- Phase A ships independently (no wire change).
- Phase B is a hard protocol bump: release iOS + relay together, version-gated,
  no insecure fallback; bump `CFBundleShortVersionString` and the relay build.

**Acceptance checklist** (status as implemented on `claude/ios-solid-dry-review-m3v0xa`)
- [x] 1. Distinct nonce prefixes per direction (iOS + Go). **[needs-e2e]** — verify handshake on device/relay; no frame-version bump, mismatched builds fail-closed.
- [x] 2. iOS rejects replayed/stale encrypted frames
- [x] 3. Non-`wss` pairings rejected (paste-time + connect-time). Relay **pinning deferred** pending a documented cert-rotation story.
- [x] 4. Lock-screen detail hidden when the setting is on (default on)
- [x] 5. Mac + iOS key fingerprints shown in Settings
- [x] 6. Crypto moved to `Chau7Core` with XCTest coverage (round-trip, direction separation, tamper, short-ciphertext). iOS file left as a stub (explicit Xcode ref). **[needs-e2e build]**
- [x] 7. Shared `JSONEncoder`/`Decoder`/`ISO8601`/cached device name
- [x] 8. Frame backpressure: token-bucket throttle (reads slower, no data drop) + rate-limited log
- [x] 9. Small frames processed inline; large frames (>8 KB) offloaded
- [ ] 10. Telemetry batching — **deferred (deliberate)**: wire-coordinated (new frame type + Go decode) for the lowest-value gain; telemetry is sparse. Not worth a speculative protocol change without an e2e loop.
- [ ] 11. ANSIStripper/renderer — **deferred (deliberate)**: rewriting the ANSI parser or adding renderer dirty-rect risks correctness regressions with no profiler/tests to catch them. The current stripper already offloads >4 KB. Revisit only if Instruments shows a hotspot.

## Implementation status

Landed as granular commits on `claude/ios-solid-dry-review-m3v0xa`:
- **Phase A** (safe, iOS-only): items 2, 7, 3, 4, 9 — shippable independently.
- **Phase B** (coordinated): items 1 (iOS + Go) and 6 (crypto → `Chau7Core` +
  tests). **Authored without a Swift/Go toolchain — not compiled.** The
  handshake and the new XCTests must be built and run by the toolchain dev;
  iOS and relay must ship together.
- **Phase C**: items 5, 8.
- **Phase D**: items 10, 11 deferred with rationale above.

## Post-review security fixes (2026-06-29)
Applied to this branch after a code review, as granular commits:

- **Encryption enforcement (fix #1).** `handleProcessedFrame` dispatched purely on
  `frame.type`, so a hostile relay could inject a *plaintext* `.sessionReady` /
  `.approvalRequest` / `.output` (`flagEncrypted=0`) that skipped both AEAD
  decryption and the monotonic-seq replay counter — fabricating approvals and
  undercutting the replay-protection claim. Now any known non-handshake frame
  type must arrive encrypted with a live crypto session or it is dropped; only
  `.hello` / `.pairAccept` / `.pairReject` remain cleartext, matching the Go relay.
- **REST path wss enforcement (fix #2).** The `wss://`-only rule guarded the
  WebSocket but not `relayAPIURLComponents`, which mapped `ws→http`. A legacy
  `ws://` pairing would still fetch pending approvals/prompts (commands +
  directories) over cleartext `http`. The REST path now rejects any non-`wss`
  scheme (case-insensitive).

### Deferred: key-fingerprint length (review item "fix #3")
The 8-byte (64-bit) key fingerprint is short for an out-of-band MITM check
(128-bit is the norm), but it is **not** a display-only value: macOS persists it
as the paired-device `id` (`RemoteControlModels.fingerprint(for:)`) and the relay
matches connecting devices by it (`agent.go FindPairedDeviceByFingerprint(hello.PubKeyFP)`).
Lengthening it is therefore a breaking change across iOS + macOS + Go that
invalidates every persisted pairing and requires a migration — disproportionate
to the gain. Deferred to a deliberate, migrated change rather than bundled here.

## Relationship to the SOLID/DRY review
The remaining structural work there (transport/session/approval split, DIP seam)
is complementary: doing item 6 (crypto → `Chau7Core`) and the transport split
together would make items 1, 2, 8, 9 land in small, individually testable units.
</content>
