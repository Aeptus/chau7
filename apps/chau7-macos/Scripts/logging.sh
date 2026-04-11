#!/usr/bin/env bash

# Shared logging helpers for Scripts/*

LOG_ROOT_DIR="${CHAU7_LOG_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LOG_DIR="${CHAU7_LOG_DIR:-$LOG_ROOT_DIR/build/logs}"
LOG_NAME="${CHAU7_LOG_NAME:-$(basename "$0")}"
LOG_BASE="${LOG_NAME%.*}"
LOG_FILE="${CHAU7_LOG_FILE:-$LOG_DIR/${LOG_BASE}-$(date '+%Y%m%d-%H%M%S').log}"
LOG_LATEST_FILE="${CHAU7_LOG_LATEST_FILE:-$LOG_DIR/${LOG_BASE}-latest.log}"
LOG_LATEST_GLOBAL_FILE="${CHAU7_LOG_LATEST_GLOBAL_FILE:-$LOG_DIR/latest.log}"
LOG_VERBOSE="${CHAU7_LOG_VERBOSE:-1}"
LOG_COLOR="${CHAU7_LOG_COLOR:-1}"
LOG_SUMMARY="${CHAU7_LOG_SUMMARY:-1}"
LOG_START_TS="${LOG_START_TS:-$(date +%s)}"
LOG_SUPPRESS_HEADER="${CHAU7_LOG_SUPPRESS_HEADER:-0}"

if [[ -n "${NO_COLOR:-}" ]]; then
  LOG_COLOR="0"
fi

mkdir -p "$LOG_DIR"

log_ts() {
  date '+%H:%M:%S'
}

log_line() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  local padded
  local line
  local color
  local reset
  ts="$(log_ts)"
  printf -v padded '%-5s' "$level"
  line="${ts} | ${padded} | ${msg}"
  if [[ "$LOG_VERBOSE" == "1" ]]; then
    if [[ "$LOG_COLOR" == "1" && -t 1 ]]; then
      case "$level" in
        INFO) color=$'\033[34m' ;;
        STEP) color=$'\033[36m' ;;
        OK) color=$'\033[32m' ;;
        WARN) color=$'\033[33m' ;;
        ERROR) color=$'\033[31m' ;;
        *) color=$'\033[0m' ;;
      esac
      reset=$'\033[0m'
      printf '%s | %s%s%s | %s\n' "$ts" "$color" "$padded" "$reset" "$msg"
    else
      printf '%s\n' "$line"
    fi
  fi
  printf '%s\n' "$line" >> "$LOG_FILE"
}

log_divider() {
  local line
  line="---------------------------------------------------------------------"
  if [[ "$LOG_VERBOSE" == "1" ]]; then
    printf '%s\n' "$line"
  fi
  printf '%s\n' "$line" >> "$LOG_FILE"
}

log_init() {
  local title="$1"
  if [[ "$LOG_SUPPRESS_HEADER" == "1" ]]; then
    return
  fi
  log_divider
  log_line INFO "$title"
  log_line INFO "Log file: $LOG_FILE"
  log_line INFO "Root: $LOG_ROOT_DIR"
  if [[ "$LOG_LATEST_FILE" != "$LOG_FILE" ]]; then
    ln -sf "$LOG_FILE" "$LOG_LATEST_FILE" 2>/dev/null || true
    log_line INFO "Latest log: $LOG_LATEST_FILE"
  fi
  if [[ "$LOG_LATEST_GLOBAL_FILE" != "$LOG_FILE" ]]; then
    ln -sf "$LOG_FILE" "$LOG_LATEST_GLOBAL_FILE" 2>/dev/null || true
    log_line INFO "Global latest: $LOG_LATEST_GLOBAL_FILE"
  fi
  log_divider
}

log_info() { log_line INFO "$*"; }
log_warn() { log_line WARN "$*"; }
log_error() { log_line ERROR "$*"; }
log_step() { log_line STEP "$*"; }
log_ok() { log_line OK "$*"; }

log_duration_human() {
  local end
  local elapsed
  local mins
  local secs
  local hours
  end="$(date +%s)"
  elapsed=$((end - LOG_START_TS))
  if ((elapsed < 60)); then
    printf '%ss' "$elapsed"
    return
  fi
  if ((elapsed < 3600)); then
    mins=$((elapsed / 60))
    secs=$((elapsed % 60))
    printf '%sm %ss' "$mins" "$secs"
    return
  fi
  hours=$((elapsed / 3600))
  mins=$(((elapsed % 3600) / 60))
  secs=$((elapsed % 60))
  printf '%sh %sm %ss' "$hours" "$mins" "$secs"
}

log_finish() {
  local code="$1"
  if [[ "$LOG_SUMMARY" != "1" ]]; then
    return
  fi
  log_divider
  if [[ "$code" == "0" ]]; then
    log_ok "Exit: $code"
  else
    log_error "Exit: $code"
  fi
  log_info "Duration: $(log_duration_human)"
  log_info "Log file: $LOG_FILE"
  log_divider
}

run_cmd() {
  log_step "$*"
  if [[ "$LOG_VERBOSE" == "1" ]]; then
    set -o pipefail
    "$@" 2>&1 | while IFS= read -r line; do
      printf '%s\n' "$line" >> "$LOG_FILE"
      if [[ "$LOG_COLOR" == "1" && -t 1 ]]; then
        if [[ "$line" == *"warning:"* || "$line" == *"warning"* ]]; then
          printf '\033[33m%s\033[0m\n' "$line"
        elif [[ "$line" == *"error:"* || "$line" == *"error"* ]]; then
          printf '\033[31m%s\033[0m\n' "$line"
        else
          printf '%s\n' "$line"
        fi
      else
        printf '%s\n' "$line"
      fi
    done
    return "${PIPESTATUS[0]}"
  else
    "$@" >> "$LOG_FILE" 2>&1
  fi
}
