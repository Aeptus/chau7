#!/usr/bin/env bash
set -euo pipefail

TYPE="${1:-}"
TOOL="${2:-CLI}"
MESSAGE="${3:-}"

if [[ -z "$TYPE" ]]; then
  echo "Usage: $0 <needs_validation|finished|failed|info> <tool> <message>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CHAU7_LOG_ROOT="$ROOT_DIR"
CHAU7_LOG_NAME="ai-event"
export CHAU7_LOG_NAME
source "$ROOT_DIR/Scripts/logging.sh"

log_init "AI Event"

finish() {
  local code=$?
  log_finish "$code"
}

trap finish EXIT

LOG_PATH="${AI_EVENTS_LOG:-$HOME/.ai-events.log}"

TS="$(python3 - <<'PY'
from datetime import datetime
print(datetime.now().astimezone().isoformat(timespec="seconds"))
PY
)"

json_escape() {
  python3 - <<'PY' "$1"
import json,sys
print(json.dumps(sys.argv[1])[1:-1])
PY
}

TYPE_E="$(json_escape "$TYPE")"
TOOL_E="$(json_escape "$TOOL")"
MSG_E="$(json_escape "$MESSAGE")"
TS_E="$(json_escape "$TS")"

mkdir -p "$(dirname "$LOG_PATH")" 2>/dev/null || true
touch "$LOG_PATH"

printf '{"type":"%s","tool":"%s","message":"%s","ts":"%s"}\n' \
  "$TYPE_E" "$TOOL_E" "$MSG_E" "$TS_E" >> "$LOG_PATH"

log_info "Event appended: type=$TYPE tool=$TOOL log=$LOG_PATH"
