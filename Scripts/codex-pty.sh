#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${AI_TTY_LOG_DIR:-$HOME/Library/Logs/Chau7}"
LOG_FILE="${AI_CODEX_TTY_LOG:-$LOG_DIR/codex-pty.log}"

export CHAU7_LOG_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CHAU7_LOG_NAME="codex-pty"
export CHAU7_LOG_NAME
source "$SCRIPT_DIR/logging.sh"

log_init "Codex PTY Wrapper"
log_info "TTY log: $LOG_FILE"
log_info "Args: $*"

run_cmd mkdir -p "$LOG_DIR"
export CHAU7_PTY_META_LOG="$LOG_FILE"
exec "$SCRIPT_DIR/pty-log-wrapper.py" --log "$LOG_FILE" -- codex "$@"
