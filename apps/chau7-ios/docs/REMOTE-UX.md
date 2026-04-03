# Remote UX

This document captures the product-level remote-control scope for the iOS companion app.

The transport and payload contract live in
[services/chau7-remote/docs/PROTOCOL.md](/Users/christophehenner/Downloads/Repositories/Chau7/services/chau7-remote/docs/PROTOCOL.md).

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
- iOS pastes that payload to start pairing
- QR can be added later, but it is not part of the current contract
