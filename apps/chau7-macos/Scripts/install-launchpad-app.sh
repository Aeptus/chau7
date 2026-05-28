#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Chau7"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_MODE="${BUILD_MODE:-release}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-0}"
SRC_APP="$ROOT_DIR/build/$APP_NAME.app"
DST_APP="/Applications/$APP_NAME.app"

# Snapshot CHAU7_* env vars from the caller's shell before this script
# sets its own (CHAU7_LOG_ROOT / CHAU7_LOG_NAME below) so we can forward
# only the caller-provided ones to the launched app via `open --env`.
CHAU7_OPEN_ENV=()
while IFS='=' read -r _v _value; do
  case "$_v" in
    CHAU7_*) CHAU7_OPEN_ENV+=(--env "$_v=$_value") ;;
  esac
done < <(env)
unset _v _value

export CHAU7_LOG_ROOT="$ROOT_DIR"
CHAU7_LOG_NAME="install-launchpad-app"
export CHAU7_LOG_NAME

# shellcheck source=apps/chau7-macos/Scripts/logging.sh
source "$ROOT_DIR/Scripts/logging.sh"

log_init "Install Launchpad App"
log_info "Build mode: $BUILD_MODE"
log_info "Source app: $SRC_APP"
log_info "Destination app: $DST_APP"
log_info "Bundle identifier: com.chau7.app"
log_info "Codesign identity: ${CHAU7_CODESIGN_IDENTITY:-auto}"

RUNNING_CHAU7="$(
  ps -axo pid=,args= 2>/dev/null \
    | awk 'match($0, /^[[:space:]]*[0-9]+[[:space:]]+.+\/Chau7\.app\/Contents\/MacOS\/Chau7([[:space:]]|$)/) { print $0 }' \
    | sed 's/^[[:space:]]*//'
)"
if [[ -n "$RUNNING_CHAU7" ]]; then
  log_error "Refusing to install Launchpad app while Chau7 is running."
  while IFS= read -r proc; do
    [[ -n "$proc" ]] || continue
    log_error "  $proc"
  done <<< "$RUNNING_CHAU7"
  log_error "Replacing a running app causes TCC code-requirement mismatches and repeated permission prompts."
  log_info "Quit Chau7 and rerun this script."
  exit 1
fi

CHAU7_LOG_FILE="$LOG_FILE" CHAU7_LOG_SUMMARY=0 CHAU7_LOG_SUPPRESS_HEADER=1 \
  BUNDLE_IDENTIFIER="com.chau7.app" OPEN_AFTER_BUILD=0 BUILD_MODE="$BUILD_MODE" \
  CHAU7_CODESIGN_PURPOSE="${CHAU7_CODESIGN_PURPOSE:-install}" \
  "$ROOT_DIR/Scripts/build-and-run.sh"

run_cmd /usr/bin/ditto "$SRC_APP" "$DST_APP"
run_cmd codesign -d -vvv "$DST_APP"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  if [[ ${#CHAU7_OPEN_ENV[@]} -gt 0 ]]; then
    run_cmd open "${CHAU7_OPEN_ENV[@]}" "$DST_APP"
  else
    run_cmd open "$DST_APP"
  fi
else
  log_info "Skipping app launch (OPEN_AFTER_INSTALL=$OPEN_AFTER_INSTALL)"
fi

log_ok "Launchpad app installed at $DST_APP"
