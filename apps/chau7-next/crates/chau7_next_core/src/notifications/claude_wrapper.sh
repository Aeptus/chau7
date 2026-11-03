#!/usr/bin/env bash
# Chau7 Next session wrapper. Never rewrites provider or Swift configuration.
set -e
_wrapper_dir="$(cd -- "$(dirname -- "$0")" && pwd -P)"
_real=""
_old_ifs="$IFS"
IFS=:
for _entry in $PATH; do
  [ -n "$_entry" ] || _entry=.
  [ -x "$_entry/claude" ] || continue
  _resolved_dir="$(cd -- "$_entry" 2>/dev/null && pwd -P)" || continue
  [ "$_resolved_dir" = "$_wrapper_dir" ] && continue
  _real="$_resolved_dir/claude"
  break
done
IFS="$_old_ifs"
if [ -z "$_real" ]; then
  printf '%s\n' 'Chau7 Next: Claude executable not found on PATH.' >&2
  exit 127
fi
if [ "${TERM_PROGRAM:-}" != Chau7Next ] || [ -z "${CHAU7_NEXT_TAB_ID:-}" ] || ! command -v python3 >/dev/null 2>&1; then
  exec "$_real" "$@"
fi
export CHAU7_TAB_ID=
exec python3 "$_wrapper_dir/chau7-next-claude-wrapper.py" "$_real" "$@"
