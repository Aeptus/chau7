#!/usr/bin/env bash
# Verifies that a Chau7 .app bundle is signed in a way that PRESERVES its macOS
# TCC grants (Full Disk Access, Accessibility, …). TCC binds grants to the code
# signature; a drifting signature — different Team ID, missing hardened runtime,
# or a development `get-task-allow`/library-validation-disabled build — makes
# macOS stop honoring the existing grant, so the app's child processes (codex,
# claude, shells) start failing with "Operation not permitted" in protected
# folders like ~/Downloads while the app itself looks fine.
#
# Usage: check-signing.sh [path-to-app] [--strict]
#   path-to-app  defaults to /Applications/Chau7.app
#   --strict     exit non-zero on any concern (default: warn-only, exit 0)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=apps/chau7-macos/Scripts/logging.sh
source "$ROOT_DIR/Scripts/logging.sh" 2>/dev/null || true
command -v log_info >/dev/null 2>&1 || log_info() { echo "[INFO] $*"; }
command -v log_warn >/dev/null 2>&1 || log_warn() { echo "[WARN] $*" >&2; }

EXPECTED_TEAM="XQ8B6NS6H2"
APP="${1:-/Applications/Chau7.app}"
STRICT=0
[[ "${2:-}" == "--strict" || "${1:-}" == "--strict" ]] && STRICT=1
[[ "${1:-}" == "--strict" ]] && APP="/Applications/Chau7.app"

if [[ ! -d "$APP" ]]; then
  log_info "check-signing: no app bundle at '$APP' — skipping."
  exit 0
fi

info="$(codesign -dvvv "$APP" 2>&1 || true)"
ents="$(codesign -d --entitlements - "$APP" 2>/dev/null || true)"
issues=0

team="$(printf '%s\n' "$info" | sed -n 's/^TeamIdentifier=//p' | head -1)"
if [[ "$team" != "$EXPECTED_TEAM" ]]; then
  log_warn "Signing drift: Team ID '$team' != expected '$EXPECTED_TEAM'. macOS may treat this as a different app and drop its TCC grants (Full Disk Access)."
  issues=$((issues + 1))
fi

if ! printf '%s\n' "$info" | grep -q "flags=.*runtime"; then
  log_warn "Signing drift: hardened runtime flag is missing. Inconsistent runtime flags across builds can disturb TCC grants."
  issues=$((issues + 1))
fi

if printf '%s\n' "$ents" | grep -q "get-task-allow"; then
  log_warn "Signing drift: 'com.apple.security.get-task-allow' is present. This is a debuggable/development build and reliably orphans TCC grants (Full Disk Access). Never install a get-task-allow build as the production com.chau7.app."
  issues=$((issues + 1))
fi

if printf '%s\n' "$ents" | grep -q "disable-library-validation"; then
  log_warn "Signing note: 'com.apple.security.cs.disable-library-validation' is present (development-only signing)."
  issues=$((issues + 1))
fi

if [[ "$issues" -eq 0 ]]; then
  log_info "Signing looks TCC-stable for '$APP' (Team $EXPECTED_TEAM, hardened runtime, no development entitlements)."
  exit 0
fi

log_warn "$issues signing concern(s) for '$APP'. If terminal commands later fail with 'Operation not permitted', re-grant Full Disk Access to Chau7 in System Settings → Privacy & Security → Full Disk Access (or run scripts/grant-dev-fda.sh for dev builds)."
[[ "$STRICT" -eq 1 ]] && exit 1
exit 0
