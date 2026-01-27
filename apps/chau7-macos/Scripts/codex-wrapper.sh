#!/usr/bin/env bash
set -euo pipefail

# Example wrapper for Codex CLI.
# Adjust the actual "codex" invocation to your setup.
# Usage: ./codex-wrapper.sh <your usual codex args...>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EMIT="$SCRIPT_DIR/ai-event.sh"

export CHAU7_LOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHAU7_LOG_NAME="codex-wrapper"
export CHAU7_LOG_NAME
source "$SCRIPT_DIR/logging.sh"

log_init "Codex Wrapper"
log_info "Args: $*"

finish() {
  local code=$?
  log_finish "$code"
}

trap finish EXIT

"$EMIT" info "Codex" "Started: $*"

if codex "$@"; then
  log_ok "Codex finished successfully."
  "$EMIT" finished "Codex" "Finished: $*"
  exit 0
else
  code=$?
  log_error "Codex failed with code $code."
  "$EMIT" failed "Codex" "Failed: $*"
  exit "$code"
fi
