#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${AI_TTY_LOG_DIR:-$HOME/Library/Logs/Chau7}"
LOG_FILE="${AI_CLAUDE_TTY_LOG:-$LOG_DIR/claude-pty.log}"

CHAU7_LOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export CHAU7_LOG_ROOT
CHAU7_LOG_NAME="claude-pty"
export CHAU7_LOG_NAME
# shellcheck source=apps/chau7-macos/Scripts/logging.sh
source "$SCRIPT_DIR/logging.sh"

log_init "Claude PTY Wrapper"
log_info "TTY log: $LOG_FILE"
log_info "Args: $*"

run_cmd mkdir -p "$LOG_DIR"
export CHAU7_PTY_META_LOG="$LOG_FILE"
exec "$SCRIPT_DIR/pty-log-wrapper.py" --log "$LOG_FILE" -- claude "$@"
