# Read-only viewers (protocol addition)

Status: implemented in Chau7 Next, the Go agent (`services/chau7-remote`)
and the relay (`services/chau7-relay`). The only viewer client is a debug
tool, `chau7-remote viewer <code>` (see "Viewer client" below); the iOS app
does not show viewers yet. The Swift app never sends `VIEWER_SHARE`, so the
agent rejects every join while it runs under the Swift app and the relay
never knows a code for it: nothing changes for it.

## What it does

The owner shares a link (`chau7-next://view/<code>`, 8 characters) from the
remote control settings. A viewer opens it, the relay delivers a join to the
owner's agent, and the owner approves or denies it (a trusted viewer is let
in at once when "auto-approve known viewers" is on). Approved viewers see the
shared terminal (tab list, output, snapshots) and can never type into it.
The owner can disconnect or revoke a viewer, change the maximum (1 to 10),
or stop sharing, which ends every viewing.

## Frames

Same 20-byte header as every other frame (`SPEC-Remote-Control.md`). Payloads
are UTF-8 JSON except `VIEWER_OUTPUT`. These frames are sent in clear between
the agent and the relay: viewers have no pairing keys. See "Security" below.

| Code | Name | Direction | Payload |
|---|---|---|---|
| `0x60` | `VIEWER_SHARE` | app to agent (IPC), agent to relay | `{"share_code": "abcd1234" or null, "max_viewers": 5}` |
| `0x61` | `VIEWER_JOIN` | relay to agent, agent to app | `{"viewer_id": "...", "name": "...", "share_code": "abcd1234"}` |
| `0x62` | `VIEWER_DECISION` | app to agent, agent to relay | `{"viewer_id": "...", "approved": true, "reason": "..."}` |
| `0x63` | `VIEWER_LEAVE` | both ways | `{"viewer_id": "..."}` |
| `0x64` | `VIEWER_OUTPUT` | agent to relay | `id_len (u8) | viewer_id | encoded inner frame` |

### Rules in the agent

- `VIEWER_SHARE` with `share_code: null` stops sharing; a new code replaces
  the old one. Either way every pending viewer gets
  `VIEWER_DECISION {approved: false, reason: "share_ended"}` and every
  approved viewer a `VIEWER_LEAVE` (to the relay).
  `max_viewers` is clamped to 1..10 (default 5).
- `VIEWER_JOIN` from the relay is rejected by the agent itself (it never
  reaches the app) with `reason` `not_sharing`, `invalid_code` (the code is
  compared case-insensitively) or `max_viewers`. A valid join is forwarded
  to the app with the code normalized. An already approved viewer that joins
  again gets `approved: true` back at once.
- `VIEWER_DECISION` from the app is applied only to a pending viewer and
  passed to the relay. An approval over the maximum turns into a rejection
  (`max_viewers`); a rejection without a reason gets `denied`.
- `VIEWER_LEAVE` from the app (disconnect, revoke) is passed to the relay;
  from the relay (the viewer closed) it is passed to the app.
- For each approved viewer, the agent copies every `TAB_LIST`, `OUTPUT`,
  `SNAPSHOT` and `TERMINAL_GRID_SNAPSHOT` frame the app sends into one
  `VIEWER_OUTPUT` (the inner frame is the app's frame, not encrypted). Inputs,
  approvals, prompts and telemetry are never copied, and nothing a viewer
  sends other than `VIEWER_JOIN` and `VIEWER_LEAVE` is read.

### What the app does

Chau7 Next (`apps/chau7-next/crates/chau7_next/src/remote/mod.rs`,
`chau7_next_core/src/remote/viewer_protocol.rs`):

- sends `VIEWER_SHARE` when sharing starts or stops, when the maximum
  changes, and again after the agent reconnects;
- on `VIEWER_JOIN`, adds the viewer (auto-approved when trusted, rejected
  over the maximum, else pending in the viewer list) and answers at once
  for the first two cases;
- sends `VIEWER_DECISION` when the owner approves or denies, and
  `VIEWER_LEAVE` when the owner disconnects or revokes a viewer.

### Agent and relay

- The agent sends `VIEWER_SHARE` to the relay when the code changes (after
  the decisions and leaves that end the old viewings) and again after each
  relay reconnect. When the relay connection drops, every viewing ends and
  the app gets a `VIEWER_LEAVE` per viewer.

## Relay (`services/chau7-relay`)

Routing lives in `src/viewer.js` (tested by `test/viewer.test.js`), wired
into the session Durable Object in `src/session.ts` and the worker in
`src/worker.ts`.

- Registry: on `VIEWER_SHARE` from a Mac, the Mac's session object records
  the code in a registry object named `share:<code>` (first device wins; a
  Mac cannot take a code another device holds). The entry is removed when
  the Mac stops sharing, changes code, or disconnects. Viewer frames from the
  Mac (0x60 to 0x64) are never forwarded to the phone.
- `GET /view/<code>` (WebSocket, no pairing token): the code must be 8
  letters or digits; attempts are limited to 60 per hour per IP; the worker
  looks the code up (404 when unknown) and hands the socket to the Mac's
  session object. There the socket is rejected at once, with a
  `VIEWER_DECISION` (`viewer_id` empty) then a close, when the code is not
  the one shared (`not_sharing`, `invalid_code`) or the session already has
  20 viewer sockets (`max_viewers`).
- The viewer's first `VIEWER_JOIN` names its `viewer_id` (1 to 255 bytes)
  and `name` (cut to 100 characters); the relay sends it to the agent with
  the code from the URL. A `viewer_id` already connected is refused
  (`viewer_id_in_use`); with no Mac connected the answer is `host_offline`.
- From the agent, `VIEWER_DECISION`, `VIEWER_LEAVE` and `VIEWER_OUTPUT` go to
  the viewer with that `viewer_id`, unchanged. A rejection or a leave closes
  the viewer's socket.
- From a viewer, only the first `VIEWER_JOIN` and `VIEWER_LEAVE` are read
  (the leave always carries the socket's own id); everything else is
  dropped. A viewer socket that closes after joining becomes a
  `VIEWER_LEAVE` to the agent. When the Mac disconnects, every viewer gets a
  `VIEWER_LEAVE` and is closed.

## Viewer client

`chau7-remote viewer [-relay URL] [-name NAME] [-id ID] <code>`
(`services/chau7-remote/internal/viewer`) is a debug viewer: it connects to
`<relay>/view/<code>` (the relay URL defaults to `$CHAU7_RELAY_URL`, a
trailing `/connect` is dropped), sends `VIEWER_JOIN`, waits for the
decision, then writes `OUTPUT` and `SNAPSHOT` payloads to stdout and other
frames as status lines on stderr, until the owner ends the viewing or
Ctrl-C (which sends `VIEWER_LEAVE`). `-id` reuses an id, to be a known
viewer. `go test ./internal/viewer -run TestEndToEnd` runs the agent, a fake
app, the relay (`wrangler dev`) and this client together (see the test for
the command).

An iOS or web viewer would do the same and render the inner frames with the
existing terminal views, read only.

## Security

Viewer traffic is protected by TLS to the relay but is not end-to-end
encrypted: the relay can read what viewers see. The share code (32 bits)
only gates who may ask (the relay limits attempts per IP); the owner's
approval is the real check. A `viewer_id` is chosen by the viewer, so a
"known viewer" (auto-approve) is only as trustworthy as the secrecy of the
id and the code: keep auto-approve for low-stakes sharing. Before
shipping viewers to users, add an end-to-end key (for example a key in the
link fragment, never sent to the relay) and encrypt `VIEWER_OUTPUT` with it.
