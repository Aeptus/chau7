#!/usr/bin/env bash
# Opens System Settings → Privacy & Security → Full Disk Access so a LOCAL dev
# build of Chau7 can be granted access.
#
# Local dev builds use bundle id `com.chau7.app.dev` — a SEPARATE app identity
# from production `com.chau7.app`. TCC grants are per-identity, so the dev build
# needs its OWN Full Disk Access; otherwise the CLIs it spawns (codex, claude,
# shells) fail with "Operation not permitted" in protected folders like
# ~/Downloads. This is a one-time setup per dev build.
set -euo pipefail

cat <<'EOF'
Local Chau7 dev builds use bundle id 'com.chau7.app.dev' — a separate app
identity from production 'com.chau7.app'. macOS TCC grants are per-identity,
so the dev build needs its own Full Disk Access.

Without it, codex/claude/shells launched from the dev build fail with
"Operation not permitted" in ~/Downloads and other protected folders.

Opening System Settings → Privacy & Security → Full Disk Access…
  1. Click '+' and add your dev build of Chau7.app (or toggle it on if listed).
  2. Quit and relaunch the dev build.
EOF

open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
