#!/usr/bin/env bash
set -euo pipefail

# Example wrapper for Claude CLI.
# Adjust the actual "claude" invocation to your setup.
# Usage: ./claude-wrapper.sh <your usual claude args...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="$SCRIPT_DIR/ai-event.sh"

CHAU7_LOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export CHAU7_LOG_ROOT
CHAU7_LOG_NAME="claude-wrapper"
export CHAU7_LOG_NAME
# shellcheck source=apps/chau7-macos/Scripts/logging.sh
source "$SCRIPT_DIR/logging.sh"

log_init "Claude Wrapper"
log_info "Args: $*"

# shellcheck disable=SC2329 # Invoked via `trap finish EXIT`
finish() {
  local code=$?
  log_finish "$code"
}

trap finish EXIT

"$EMIT" info "Claude" "Started: $*"

if claude "$@"; then
  log_ok "Claude finished successfully."
  "$EMIT" finished "Claude" "Finished: $*"
  exit 0
else
  code=$?
  log_error "Claude failed with code $code."
  "$EMIT" failed "Claude" "Failed: $*"
  exit "$code"
fi
