# Parity inventory format

One file per Swift module (`<Module>.md`, named like the folder under
`apps/chau7-macos/Sources/Chau7/`, or `Chau7Core.md`). Each file is the
definition of "done" for that module: Chau7 Next reaches parity for the module
when every row is `done` or `dropped`.

Agents porting a feature pick rows from these files, and update the row's
status in the same PR as the code.

## File layout

```markdown
# <Module>

Swift: `apps/chau7-macos/Sources/Chau7/<Module>/` (<N> files, <L> lines)
Swift tests: `<test files>` or none
Wave: <1-5> (see README.md)
Depends on: <other modules this one needs first, or none>

<Two or three sentences: what the module does for the user.>

## Features

| ID | Feature | Swift source | Tests | Rust | Status | macOS API |
|---|---|---|---|---|---|---|
| OVL-001 | Drag a tab to reorder, neighbors spring aside | `Overlay/TabBarView.swift` | `TabDragLayoutTests` | `tab_bar.rs` | done | |
| OVL-002 | ... | | | | missing | NSStatusItem |

## Notes

<Anything an agent needs: tricky behavior, file formats, defaults, settings
keys, wire formats. Optional.>
```

## Columns

- **ID**: module prefix (3 letters, see README.md) and a 3-digit number.
  Never renumber; add new rows at the end.
- **Feature**: one thing a user can see or rely on, in plain words. One row
  per behavior a person would notice if it were missing ("Cmd-click a file
  path opens it in the editor pane"), not per Swift type or function. Settings
  rows name the setting and what it changes. Group tiny related options into
  one row when they are always implemented together.
- **Swift source**: main file(s), relative to `Sources/Chau7/` (or
  `Sources/Chau7Core/`).
- **Tests**: Swift test class(es) covering it, or empty.
- **Rust**: file(s) in `apps/chau7-next/crates/` that implement it, or empty.
- **Status**:
  - `done`: Chau7 Next does it, same behavior.
  - `partial`: Chau7 Next does some of it; say what is missing in Notes or in
    the Feature cell.
  - `missing`: not in Chau7 Next.
  - `dropped`: decided not to port (only the user decides this).
  - `n/a`: internal plumbing with no user-visible effect that the Rust design
    does not need (say why in Notes).
- **macOS API**: the macOS-only API the feature relies on (Keychain,
  UNUserNotificationCenter, NSStatusItem, SMAppService, LaunchAgent, NSWorkspace,
  Sparkle, Unix sockets, ...). Empty when the feature is plain logic or UI.
  When porting a row with a value here, put the OS call behind a trait in
  `chau7_next` (macOS implementation plus a stub elsewhere), see AGENTS.md.

## Rules

- Read the Swift code; do not guess features from file names.
- Check the Rust code before writing `done` or `partial`.
- Debug-only and developer-only features are still listed (they count for
  parity), marked "(dev)" at the start of the Feature cell.
- No em dashes.
