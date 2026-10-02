# Remote UX

This document captures the product-level remote-control scope for the iOS companion app.

The transport and payload contract live in
[../../../services/chau7-remote/docs/PROTOCOL.md](../../../services/chau7-remote/docs/PROTOCOL.md).

## Scope (v1)

- Live terminal output streaming
- Simple input with a Send button
- Hold-to-send by default, with a setting to switch to tap-to-send
- Send appends newline by default
- Accountless pairing via pasted JSON payload
- Live Activity / Dynamic Island status for the most relevant remote AI task
- Support for multiple Macs in the iOS app

## Non-Goals (v1)

- Full TUI control with arrow / ctrl / esc toolbars
- File transfer
- Clipboard sync
- Multi-user collaboration

## Live Activity Behavior

- macOS is the source of truth for remote AI task state
- macOS exports one distilled activity payload over the remote-control channel
- iOS renders one Live Activity for the highest-priority remote task instead of mirroring every tab
- Action URLs from the Live Activity route back into the app and reuse the remote control paths for open, tab switch, and approvals

## Activity Prioritization

- `waiting_input` wins over generic running work
- `completed` and `failed` are short-lived end states
- iOS should not re-infer AI state from tab output once an activity payload exists

## Pairing UX

- Pairing is accountless
- The Mac produces a payload containing relay URL, device ID, public key, pairing code, and expiry
- iOS accepts that payload by scanning the Mac's QR code, a one-tap "Paste & Pair"
  from the clipboard, or manual entry
- Payload validation reports specific errors (missing field, expired code, unreadable text)


## Session picker

- The session selector opens a searchable sheet, centered on the open iPhone session.
- Sessions stay grouped by project with alphabetical titles and stable tab IDs. Rows show the session number, provider, branch, and MCP ownership when available.
- Search matches session titles, projects, branches, providers, and tab numbers. Current returns to the open session; Done closes the sheet.
- Refreshes update changed row metadata without returning to the top or re-centering a user who is browsing. Mac focus and input-pane metadata do not invalidate the picker presentation.
- Tapping the already-open session closes the picker without resubscribing to its terminal stream.
- Automatic reconnects keep the last inventory visible, with switching disabled until synchronization completes. An authoritative empty inventory, explicit disconnect, or pairing change clears stale sessions.
