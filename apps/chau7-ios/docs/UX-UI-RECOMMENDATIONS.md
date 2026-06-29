# iOS UX / UI Recommendations

Recommendations to improve the user experience and interface of the **Chau7 Remote**
iOS companion app (`apps/chau7-ios`). Every item is grounded in the current code and
ordered by impact.

Scope reviewed: `Chau7RemoteApp.swift`, `TerminalView.swift`, `ApprovalsView.swift`,
`SettingsView.swift`, `PairingSheetView.swift`, `RemoteTerminalRendererView.swift`,
`Chau7RemoteWidget.swift`, plus `docs/REMOTE-UX.md` and `docs/ARCHITECTURE.md`.

## Implementation status

Items **1–10 and 12–15 are implemented.** Item **11 (multiple Macs)** remains a
roadmap item — it is a larger feature (named Mac switching, multi-pairing storage)
and was intentionally left out of this pass.

Notable refinements made during implementation:

- **#13 (ANSI/renderer):** rather than enabling raw ANSI in the basic text view
  (which would show unprocessed escape codes), the **Rich Terminal Renderer** — the
  only path that draws real color — is now the default, with a text fallback. The
  Display toggles gained explanatory footer text.
- **#9 (accessibility):** added VoiceOver labels to icon-only controls, a Settings
  text-size slider applied to the text renderer, and combined accessibility elements.
  The Rust grid canvas still has no per-cell VoiceOver representation (it falls back
  to the accessible text view when unavailable).
- **#12 (notifications while locked):** the Keychain accessibility class
  (`AfterFirstUnlockThisDeviceOnly`) and `remote-notification` background mode were
  already correct. The fix was adding the missing
  `com.apple.developer.usernotifications.time-sensitive` entitlement, without which
  iOS silently downgrades the `.timeSensitive` approval alerts so they don't break
  through Focus / the Lock Screen.

---

## Summary

The app is functionally complete and the Live Activity / Dynamic Island work is
strong. The biggest gaps are in **first-run onboarding**, **the empty/unpaired
state**, **accessibility**, and a few **interaction sharp edges** (aggressive
auto-navigation, a default that contradicts the docs, scattered connection
controls). Fixing the P0/P1 items below would meaningfully raise the perceived
quality and approachability of the app with relatively little code.

| Priority | Theme | Items |
|----------|-------|-------|
| **P0** | Onboarding & empty states | 1, 2, 3 |
| **P0** | Correctness vs. docs | 4 |
| **P1** | Interaction polish | 5, 6, 7, 8 |
| **P1** | Accessibility | 9 |
| **P2** | Settings & connection IA | 10, 11, 12 |
| **P2** | Visual & terminal refinements | 13, 14, 15 |

---

## P0 — Onboarding & first impression

### 1. No real onboarding; first run drops the user into an empty black terminal

**Current:** On launch `RemoteRootView` shows a 1.4s splash with a random tip
(`Chau7RemoteApp.swift:178-217`), then lands on the Terminal tab. If the user has
not paired, `outputView` renders an empty black `UITextView`
(`RemoteTerminalRendererView.swift:73-91`) with no guidance. The only hint that
pairing exists is a small "Pair" text button in the nav bar
(`TerminalView.swift:32-34`).

**Why it matters:** A new user sees a blank black screen and has to discover the
pairing flow on their own. The splash tips assume the user already knows what
Chau7 is.

**Recommendation:**
- Add a first-run onboarding flow (2–3 paged screens or a single explainer card):
  what the app does, that it needs a Mac running Chau7, and how to pair.
- Replace the empty terminal with a `ContentUnavailableView` when
  `client.pairingInfo == nil`, with a prominent "Pair with your Mac" call-to-action
  that opens the pairing sheet — mirroring the good empty state already used in
  `ApprovalsView` (`ApprovalsView.swift:17-25`).

### 2. Pairing requires pasting raw JSON — high-friction and error-prone

**Current:** `PairingSheetView` asks the user to paste a JSON payload and shows a
`TextEditor` of raw JSON (`PairingSheetView.swift:14-30`). The only feedback on a
bad paste is "Invalid pairing JSON" (`PairingSheetView.swift:69`).

**Why it matters:** Pasting JSON is a developer-grade interaction. `docs/REMOTE-UX.md`
already anticipates this ("QR can be added later"). Most users will not understand a
JSON validation error.

**Recommendation:**
- Add **QR-code pairing** as the primary path (camera scan of a code shown by the
  Mac), keeping paste-JSON as the fallback. This is already called out as a planned
  enhancement in the UX doc.
- Until QR lands: auto-detect a payload already on the clipboard and offer a
  one-tap "Paste & Pair", and make validation errors specific (e.g. "Missing relay
  URL", "Pairing code expired") instead of a single generic string.
- Show a success confirmation (and connection progress) after saving, rather than
  silently dismissing the sheet (`PairingSheetView.swift:73-74`).

### 3. Connection status uses internal jargon

**Current:** The status bar surfaces raw state strings like `"Encrypted"` and
`"Session ready"` (`TerminalView.swift:73`, color logic at `:89-95`), and Settings
shows the same raw `client.status` (`SettingsView.swift:66`).

**Why it matters:** "Encrypted" / "Session ready" are implementation states, not
user concepts. Users think in terms of "Connected to MacBook Pro" / "Reconnecting…".

**Recommendation:**
- Map internal states to human-friendly labels with a clear three-state model:
  Connecting → Connected → Disconnected (with "Reconnecting…" during backoff).
- Pair the colored dot with a text label everywhere (it already has text in the
  status bar; ensure parity in Settings) so status is never color-only.

---

## P0 — Behavior that contradicts the documentation

### 4. `Hold to Send` default contradicts the spec

**Current:** `AppSettings.holdToSendDefault = false` (`SettingsView.swift:6`), i.e.
the shipping default is tap-to-send. But the in-code doc comment says "hold-to-send
default" (`TerminalView.swift:5`), the iOS `README.md` says "Simple input with Send
button (hold-to-send default)", and `docs/REMOTE-UX.md` lists "Hold-to-send by
default".

**Why it matters:** Hold-to-send is a safety feature (it prevents accidental sends
to a live terminal that may be driving an AI agent). The product intent is
hold-to-send ON, but the code ships it OFF. This is a genuine product/UX defect, not
just a docs nit.

**Recommendation:** Decide the intended default and align code + docs. If the safety
rationale stands, set `holdToSendDefault = true`. Either way, remove the
contradiction.

---

## P1 — Interaction polish

### 5. Auto-switching to the Approvals tab can hijack the user mid-task

**Current:** Any increase in `approvalsBadgeCount` force-switches the active tab to
Approvals (`Chau7RemoteApp.swift:207-209`).

**Why it matters:** If the user is reading terminal output or typing input, a new
approval yanks them away from what they were doing. It also fights the user if they
deliberately navigated back.

**Recommendation:** Prefer a non-modal signal — the tab badge already exists
(`Chau7RemoteApp.swift:187`). Consider a lightweight in-context banner ("1 approval
waiting — Review") that the user taps, instead of an automatic tab change. If
auto-switch is kept, gate it (e.g. only when the user is idle, or only for the first
pending approval, never while the input field is focused).

### 6. No "jump to latest" affordance in the terminal

**Current:** The text view auto-scrolls only when already near the bottom
(`RemoteTerminalRendererView.swift:93-109`). Once the user scrolls up to read
history, new output keeps arriving off-screen with no way back except manual scroll.

**Recommendation:** Show a floating "↓ Jump to latest" button when the user is
scrolled away from the bottom (a common terminal/chat pattern), and optionally a
"N new lines" counter.

### 7. Send gives weak confirmation; hold-to-send target is small and undiscoverable

**Current:** On a successful send the input simply clears (`TerminalView.swift:265-267`).
Hold-to-send is a small two-line button labeled "Hold"
(`TerminalView.swift:228-242`) with a 0.4s long-press and no progress indication.

**Recommendation:**
- Add visual progress for the hold gesture (fill/ring animating over the 0.4s) so
  users understand they must keep holding, and add a subtle "sent" confirmation
  (checkmark flash) in addition to the existing haptic.
- Ensure the touch target meets the 44pt minimum.

### 8. The keyboard control bar is always present, even in view-only sessions

**Current:** The esc/tab/^C/^D/^Z/^L + arrow-key bar always renders
(`TerminalView.swift:187-206`), consuming vertical space above the input on every
screen, including when the user is only viewing output or can't send
(`client.canSendInput == false`).

**Recommendation:** Collapse the control-key bar by default behind a small "keys"
toggle, or hide it when the keyboard isn't focused / when input isn't allowed. This
reclaims significant vertical space for terminal output on a phone.

---

## P1 — Accessibility

### 9. No Dynamic Type, no VoiceOver labels on icon-only controls

**Current:** The codebase contains **no** `accessibilityLabel`, `ScaledMetric`, or
`dynamicTypeSize` usage (verified by search). Terminal text is hard-pinned to 13pt
monospace (`RemoteTerminalRendererView.swift:80`, `:218`). Icon-only buttons —
the send arrow (`TerminalView.swift:245`), the `TermKey` control keys
(`TerminalView.swift:338-352`), and the status dot — have no accessibility labels.
The grid canvas (`RemoteTerminalCanvasView`) is a raw `draw(_:)` surface with no
accessibility representation.

**Why it matters:** VoiceOver users hear "arrow up circle" instead of "Send";
control keys are unlabeled; and users who rely on larger text get a fixed-size UI.

**Recommendation:**
- Add `accessibilityLabel` to every icon-only button (Send, esc/tab/^C/etc.,
  connection status, Live Activity actions).
- Make terminal font size user-adjustable (a Settings stepper backed by
  `@AppStorage`, applied via `ScaledMetric`/font size), and let the chrome (status
  bar, chips, approval cards) respond to Dynamic Type.
- Expose the terminal transcript to VoiceOver in the grid path, or at least provide
  the text path as an accessible equivalent.

---

## P2 — Settings & connection information architecture

### 10. Connection controls are scattered across Terminal and Settings

**Current:** Connect/Disconnect and "Pair" live in the Terminal toolbar
(`TerminalView.swift:31-38`, `:97-106`), while Re-pair and Disconnect *also* live in
Settings (`SettingsView.swift:74-80`). The same actions appear in two places with
different labels.

**Recommendation:** Consolidate connection management into one clear home (Settings,
or a dedicated "Connection" sheet). Keep at most a single status/Connect affordance
in the Terminal toolbar. Use consistent verbs.

### 11. "Multiple Macs" is documented but not in the UI

**Current:** Both `README.md` files list "Support for multiple Macs in the iOS app",
but `RemoteClient` stores a single `pairingInfo` (`RemoteClient.swift:57`) and the UI
exposes no Mac picker — Settings shows exactly one relay/device
(`SettingsView.swift:53-72`).

**Recommendation:** Either implement a Mac switcher (a list of paired Macs with
names, active indicator, and quick switch — ideally in the Terminal header next to
the tab menu) or remove the multi-Mac claim from the docs until it ships. If
implementing, let users **name** each Mac so status reads "Connected to
'Studio'/'Laptop'".

### 12. No recovery path when notifications are denied

**Current:** Notification authorization is requested once at launch and the result
is stored as `notificationsAuthorized` (`Chau7RemoteApp.swift:53-61`,
`RemoteClient.swift:207-208`), but **no UI reads it**. If the user denies (or later
disables) notifications, approvals silently stop alerting and there's no in-app
explanation or deep link to fix it.

**Recommendation:** Add a Settings "Notifications" row that reflects current
authorization and, when not granted, explains the impact ("Approval alerts are off")
with a button that opens `UIApplication.openSettingsURLString`.

---

## P2 — Visual & terminal refinements

### 13. ANSI color is off by default, so output is monochrome green

**Current:** `renderANSIDefault = false` (`SettingsView.swift:9`), and the text path
forces green-on-black (`RemoteTerminalRendererView.swift:79-80`). Color is only
available if the user finds and enables two separate Display toggles
(`SettingsView.swift:48-51`), whose interplay (ANSI vs. "Experimental Terminal
Renderer") is not explained.

**Recommendation:** Consider enabling ANSI rendering by default for a more faithful,
modern terminal look, and add one line of helper text under the Display toggles
explaining what each does and how they relate. The classic green monochrome could
become an explicit "theme" choice rather than the implicit default.

### 14. Per-tab AI state isn't surfaced in the tab switcher

**Current:** The tab menu lists titles with a checkmark/MCP icon
(`TerminalView.swift:110-147`). The app's own launch tip advertises the macOS color
system ("green idle, orange running, blue waiting, red stuck" —
`Chau7RemoteApp.swift:228`), and `liveActivityState` already carries status, but the
iOS tab list shows no per-tab state color/icon.

**Recommendation:** Add the same state dot/color to each row in the tab menu (and to
the collapsed menu label) so users can scan which session is waiting, running, or
stuck without opening each one. This reuses a model the product already has.

### 15. Errors are truncated to a single line with no way to read them

**Current:** `lastError` renders as one red line with `lineLimit(1)` in the status
bar (`TerminalView.swift:77-82`). Connection-failure messages are long (e.g. "No
response from your Mac. Make sure Chau7 is open…" — `RemoteClient.swift:506`) and get
cut off.

**Recommendation:** Make errors tappable to reveal the full message (sheet or
expandable row), and consider an inline retry action for connection failures. Pair
recoverable errors with a concrete next step rather than a truncated sentence.

---

## Suggested sequencing

1. **Quick wins (low effort, high impact):** #4 (default fix), #5 (stop hijacking
   tabs), #6 (jump-to-latest), #15 (readable errors), #2 partial (specific paste
   errors + clipboard auto-detect).
2. **First-impression pass:** #1 (onboarding + unpaired empty state), #3 (friendly
   status), #2 full (QR pairing).
3. **Accessibility pass:** #9.
4. **IA & polish:** #8, #10, #11, #12, #13, #14, #7.

These are recommendations only; no app behavior has been changed by this document.
