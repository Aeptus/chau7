#!/bin/sh
# Usage: mk-target.sh NAME
# Prints a private CARGO_TARGET_DIR for one agent or worktree, seeded from the
# main build with hard links (fast, little disk). Local crates
# (chau7_next, chau7_next_core, chau7_terminal) are removed from the copy:
# Cargo hashes path crates the same in every worktree, so sharing one target
# dir between worktrees silently links another worktree's sources.
set -e
name="$1"
root="$(cd "$(dirname "$0")/../.." && pwd)"
src="${MAIN_TARGET:-$root/target}"
dst="${TARGETS_DIR:-$HOME/chau7-next-targets}/$name"
if [ ! -d "$dst" ]; then
  mkdir -p "$(dirname "$dst")"
  cp -al "$src" "$dst"
  for d in "$dst"/debug/deps "$dst"/debug/.fingerprint "$dst"/debug/build "$dst"/debug/incremental; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -name '*chau7*' -exec rm -rf {} + || true
  done
  # Lock files are hard links too: without this, every copy waits on the others.
  find "$dst" -maxdepth 3 -name ".cargo-*lock" -delete
  rm -f "$dst"/debug/chau7-next "$dst"/debug/chau7-next.d "$dst"/debug/libchau7* 2>/dev/null || true
fi
echo "$dst"
