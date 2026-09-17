#!/usr/bin/env bash

# Rebuild and relaunch the installed Chau7 app without mixing binaries from
# different builds. The command is deliberately conservative: it builds and
# verifies a complete bundle before quitting the running app, then replaces
# the installed bundle atomically and keeps a rollback copy of the previous
# bundle. Session data lives outside the app bundle and is never removed.

set -euo pipefail

APP_NAME="Chau7"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$ROOT_DIR/../.." && pwd)"
BUILD_MODE="${BUILD_MODE:-release}"
DST_APP="${CHAU7_INSTALL_PATH:-/Applications/$APP_NAME.app}"
OPEN_AFTER_INSTALL="${OPEN_AFTER_INSTALL:-1}"
QUIT_TIMEOUT_SECONDS="${CHAU7_QUIT_TIMEOUT_SECONDS:-20}"
FORCE_QUIT=0
ALLOW_DIRTY=0
ALLOW_STALE_SOURCE=0
QUIT_ONLY=0
NO_INSTALL=0
DRY_RUN=0
CHAU7_OPEN_ENV=()

usage() {
  cat <<'USAGE'
Usage: ./Scripts/rebuild-and-relaunch.sh [options]

Build, verify, install, and relaunch the production Chau7 app. The running
app is asked to quit only after the new bundle has built successfully.

Options:
  --release                  Build an optimized release (default)
  --debug                    Build a debug bundle (useful for local iteration)
  --allow-dirty              Allow tracked or untracked source changes
  --allow-stale-source       Allow a checkout behind origin/main or
                             aethyme/integration
  --timeout SECONDS          Graceful quit timeout (default: 20)
  --force                    Permit unsafe SIGTERM/SIGKILL escalation after quit timeout
  --quit-only                Quit Chau7 without building or installing
  --dry-run                  Validate source and print the planned actions only
  --no-install               Build and verify, but do not replace /Applications
  --no-launch                Install but do not relaunch the app
  --install-path PATH        Override the destination app bundle
  -h, --help                 Show this help

Safety defaults:
  - a dirty or stale checkout is rejected unless explicitly allowed;
  - the old app is not quit until the new bundle is verified;
  - no POSIX signal is sent unless --force is explicitly supplied;
  - --force may bypass applicationWillTerminate and can lose the newest in-memory state;
  - the previous app bundle is retained under
    ~/Library/Application Support/Chau7/ReleaseBackups/.

Examples:
  ./Scripts/rebuild-and-relaunch.sh
  ./Scripts/rebuild-and-relaunch.sh --quit-only
  ./Scripts/rebuild-and-relaunch.sh --debug --no-install --no-launch
USAGE
}

die_usage() {
  printf 'error: %s\n\n' "$1" >&2
  usage >&2
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --release)
      BUILD_MODE="release"
      shift
      ;;
    --debug)
      BUILD_MODE="debug"
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --allow-stale-source)
      ALLOW_STALE_SOURCE=1
      shift
      ;;
    --force)
      FORCE_QUIT=1
      shift
      ;;
    --quit-only)
      QUIT_ONLY=1
      shift
      ;;
    --no-install)
      NO_INSTALL=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --no-launch)
      OPEN_AFTER_INSTALL=0
      shift
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die_usage "--timeout requires a number of seconds"
      QUIT_TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --install-path)
      [[ $# -ge 2 ]] || die_usage "--install-path requires a path"
      DST_APP="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "unknown option: $1"
      ;;
  esac
done

if [[ "$BUILD_MODE" != "release" && "$BUILD_MODE" != "debug" ]]; then
  die_usage "BUILD_MODE must be release or debug"
fi
if [[ ! "$QUIT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || ((QUIT_TIMEOUT_SECONDS < 1)); then
  die_usage "--timeout must be a positive integer"
fi
if [[ "$DST_APP" != /* ]]; then
  die_usage "--install-path must be an absolute path"
fi
if [[ "$(basename "$DST_APP")" != "$APP_NAME.app" ]]; then
  die_usage "--install-path must point to a Chau7.app bundle"
fi

# Preserve caller-provided runtime settings when `open` launches the new app.
# Capture before this script adds its own logging variables.
while IFS='=' read -r _v _value; do
  case "$_v" in
    CHAU7_*) CHAU7_OPEN_ENV+=(--env "$_v=$_value") ;;
  esac
done < <(env)
unset _v _value

export CHAU7_LOG_ROOT="$ROOT_DIR"
CHAU7_LOG_NAME="rebuild-and-relaunch"
export CHAU7_LOG_NAME

# shellcheck source=apps/chau7-macos/Scripts/logging.sh
source "$ROOT_DIR/Scripts/logging.sh"

STATUS="success"
LAST_STEP="initialization"
RELEASE_DIR=""
INSTALL_STAGING_DIR=""
BACKUP_PATH=""
MOVED_OLD_APP=0

finish() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    STATUS="failed"
  fi
  if [[ -n "$INSTALL_STAGING_DIR" && -d "$INSTALL_STAGING_DIR" ]]; then
    # This is a uniquely-created temporary directory, never a user path.
    rm -rf -- "$INSTALL_STAGING_DIR"
  fi
  log_divider
  log_info "Release workflow status: $STATUS"
  log_info "Last step: $LAST_STEP"
  log_info "Duration: $(log_duration_human)"
  if [[ "$STATUS" == "success" && -n "$RELEASE_DIR" ]]; then
    log_info "Verified bundle: $RELEASE_DIR/$APP_NAME.app"
  fi
  log_divider
}

trap finish EXIT

running_chau7_pids() {
  ps -axo pid=,comm=,args= 2>/dev/null |
    awk '{
      pid=$1
      $1=""
      process_name=$2
      $2=""
      command=$0
      sub(/^[[:space:]]+/, "", command)
      if (process_name == "Chau7" || command ~ /\/Chau7\.app\/Contents\/MacOS\/Chau7([[:space:]]|$)/) {
        print pid
      }
    }'
}

running_chau7_description() {
  ps -axo pid=,comm=,args= 2>/dev/null |
    awk '{
      pid=$1
      $1=""
      process_name=$2
      $2=""
      command=$0
      sub(/^[[:space:]]+/, "", command)
      if (process_name == "Chau7" || command ~ /\/Chau7\.app\/Contents\/MacOS\/Chau7([[:space:]]|$)/) {
        print pid " " command
      }
    }'
}

wait_for_chau7_exit() {
  local timeout_seconds="$1"
  local deadline=$((SECONDS + timeout_seconds))
  while [[ -n "$(running_chau7_pids)" ]]; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 0.25
  done
  return 0
}

send_signal_to_chau7() {
  local signal="$1"
  local pids
  pids="$(running_chau7_pids)"
  [[ -n "$pids" ]] || return 0
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    log_warn "Sending SIG$signal to Chau7 pid $pid"
    kill "-$signal" "$pid" 2>/dev/null || true
  done <<< "$pids"
}

quit_chau7() {
  LAST_STEP="quit running app"
  local initial_pids
  initial_pids="$(running_chau7_pids)"
  if [[ -z "$initial_pids" ]]; then
    log_info "Chau7 is not running. No quit required."
    return 0
  fi

  log_info "Requesting a graceful quit for Chau7 (timeout: ${QUIT_TIMEOUT_SECONDS}s)."
  if command -v osascript >/dev/null 2>&1; then
    # Both bundle identifiers are supported so a dev instance cannot be left
    # behind while the production bundle is being upgraded.
    osascript -e 'tell application id "com.chau7.app" to quit' >/dev/null 2>&1 || true
    osascript -e 'tell application id "com.chau7.app.dev" to quit' >/dev/null 2>&1 || true
  else
    log_warn "osascript is unavailable; using SIGTERM directly."
  fi

  if wait_for_chau7_exit "$QUIT_TIMEOUT_SECONDS"; then
    log_ok "Chau7 exited cleanly; persisted state had time to flush."
    return 0
  fi

  log_warn "Chau7 did not exit after the AppleScript quit request."
  if [[ "$FORCE_QUIT" != "1" ]]; then
    # SIGTERM has the default POSIX disposition for Chau7. It can therefore
    # terminate the process without running NSApplicationDelegate's
    # applicationWillTerminate callback, which is the final durable restore
    # snapshot. Never trade that snapshot for an automatic timeout escalation.
    log_error "Refusing SIGTERM and SIGKILL to protect session data."
    log_error "Retry with --force only after confirming the app is unrecoverably stuck; forced signals may lose the newest state."
    running_chau7_description >&2
    return 1
  fi

  log_warn "--force supplied; sending SIGTERM may bypass applicationWillTerminate and lose the newest session snapshot."
  send_signal_to_chau7 TERM
  if wait_for_chau7_exit 5; then
    log_warn "Chau7 exited after forced SIGTERM; verify session restoration after relaunch."
    return 0
  fi

  log_warn "Graceful quit and SIGTERM failed; --force permits SIGKILL as a last resort."
  send_signal_to_chau7 KILL
  if wait_for_chau7_exit 5; then
    log_warn "Chau7 was force-terminated. Verify session recovery after relaunch."
    return 0
  fi

  log_error "Unable to stop Chau7 even after SIGKILL."
  running_chau7_description >&2
  return 1
}

check_source_state() {
  LAST_STEP="source preflight"
  local current_sha branch dirty_lines stale_refs ref ref_sha
  current_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached')"
  dirty_lines="$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null || true)"

  log_info "Source: $branch @ $current_sha"
  if [[ -n "$dirty_lines" ]]; then
    log_warn "Checkout has uncommitted or untracked files."
    if [[ "$ALLOW_DIRTY" != "1" ]]; then
      log_error "Refusing a production relaunch from a dirty checkout. Use --allow-dirty only intentionally."
      return 1
    fi
    log_warn "Continuing because --allow-dirty was supplied."
  fi

  stale_refs=""
  for ref in refs/remotes/origin/main refs/heads/aethyme/integration; do
    ref_sha="$(git -C "$REPO_ROOT" rev-parse --verify "$ref" 2>/dev/null || true)"
    [[ -n "$ref_sha" ]] || continue
    if ! git -C "$REPO_ROOT" merge-base --is-ancestor "$ref_sha" "$current_sha"; then
      stale_refs+="${ref#refs/} @ $ref_sha\n"
    fi
  done

  if [[ -n "$stale_refs" ]]; then
    log_warn "Checkout is behind a known integration reference:"
    printf '%b' "$stale_refs" | while IFS= read -r stale_ref; do
      [[ -n "$stale_ref" ]] && log_warn "  $stale_ref"
    done
    if [[ "$ALLOW_STALE_SOURCE" != "1" ]]; then
      log_error "Refusing to install an older build. Update/switch the checkout or use --allow-stale-source intentionally."
      return 1
    fi
    log_warn "Continuing because --allow-stale-source was supplied."
  fi
}

require_command() {
  local command_name="$1"
  if [[ "$command_name" == */* ]]; then
    if [[ ! -x "$command_name" ]]; then
      log_error "Required command not found: $command_name"
      return 1
    fi
    return 0
  fi
  if ! command -v "$command_name" >/dev/null 2>&1; then
    log_error "Required command not found: $command_name"
    return 1
  fi
}

check_install_preflight() {
  local install_parent backup_root
  install_parent="$(dirname "$DST_APP")"
  backup_root="${CHAU7_RELEASE_BACKUP_DIR:-$HOME/Library/Application Support/Chau7/ReleaseBackups}"

  # Resolve permissions and path shape before stopping the running app. The
  # backup directory is application metadata, not session state; creating it
  # early prevents a permissions surprise after a successful graceful quit.
  if ! mkdir -p "$install_parent" "$backup_root"; then
    log_error "Cannot create the install or rollback directory before quitting Chau7."
    return 1
  fi
  if [[ ! -w "$install_parent" ]]; then
    log_error "Install directory is not writable: $install_parent"
    return 1
  fi
  if [[ ! -w "$backup_root" ]]; then
    log_error "Rollback directory is not writable: $backup_root"
    return 1
  fi
  if [[ -L "$DST_APP" ]]; then
    log_error "Refusing to replace symlinked install destination: $DST_APP"
    return 1
  fi
  if [[ -e "$DST_APP" && ! -d "$DST_APP" ]]; then
    log_error "Install destination is not an app bundle directory: $DST_APP"
    return 1
  fi
}

plist_value() {
  local key="$1"
  local plist="$2"
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null
  fi
}

verify_bundle() {
  local app_path="$1"
  local expected_sha="$2"
  local bundle_id actual_sha helper_revision

  [[ -d "$app_path" ]] || { log_error "Bundle not found: $app_path"; return 1; }
  [[ -x "$app_path/Contents/MacOS/$APP_NAME" ]] || {
    log_error "Main executable is missing or not executable: $app_path"; return 1;
  }
  [[ -x "$app_path/Contents/Resources/chau7-remote" ]] || {
    log_error "Bundled chau7-remote helper is missing or not executable: $app_path"; return 1;
  }

  bundle_id="$(plist_value CFBundleIdentifier "$app_path/Contents/Info.plist" || true)"
  if [[ "$bundle_id" != "com.chau7.app" ]]; then
    log_error "Unexpected bundle identifier '$bundle_id' in $app_path"
    return 1
  fi
  actual_sha="$(plist_value Chau7BuildGitSHA "$app_path/Contents/Info.plist" || true)"
  if [[ -z "$expected_sha" || "$actual_sha" != "$expected_sha" ]]; then
    log_error "Bundle SHA mismatch: expected $expected_sha, got $actual_sha"
    return 1
  fi

  if ! command -v go >/dev/null 2>&1; then
    log_error "Cannot verify bundled chau7-remote revision: go is unavailable."
    return 1
  fi
  # Go emits `build vcs.revision=<full-sha>`, not three whitespace fields.
  # Consume all input (no early awk exit/SIGPIPE under pipefail).
  helper_revision="$(go version -m "$app_path/Contents/Resources/chau7-remote" 2>/dev/null |
    awk '$1 == "build" && $2 ~ /^vcs.revision=/ { sub(/^vcs.revision=/, "", $2); print $2 }')" || {
    log_error "Cannot read bundled chau7-remote build metadata."
    return 1
  }
  if [[ -z "$helper_revision" || "$helper_revision" != "$expected_sha"* ]]; then
    log_error "chau7-remote SHA mismatch: expected $expected_sha, got ${helper_revision:-missing}"
    return 1
  fi

  if command -v codesign >/dev/null 2>&1; then
    log_step "Verifying code signature: $app_path"
    codesign --verify --deep --strict "$app_path" || return 1
  else
    log_error "Cannot verify bundle signature: codesign is unavailable."
    return 1
  fi
  log_ok "Verified bundle SHA $actual_sha and helper revision $helper_revision."
}

build_release_bundle() {
  local current_sha dev_output
  current_sha="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
  RELEASE_DIR="$ROOT_DIR/build/local-release-$(date -u '+%Y%m%d-%H%M%S')-$current_sha-$$"
  dev_output="$RELEASE_DIR/dev"
  mkdir -p "$RELEASE_DIR"

  LAST_STEP="compile and package"
  log_info "Building Chau7 ($BUILD_MODE) before quitting the running app."
  BUILD_MODE="$BUILD_MODE" \
    BUNDLE_IDENTIFIER="com.chau7.app.dev" \
    OPEN_AFTER_BUILD=0 \
    APP_OUTPUT_DIR="$dev_output" \
    CHAU7_LOG_FILE="$LOG_FILE" \
    CHAU7_LOG_SUMMARY=0 \
    CHAU7_LOG_SUPPRESS_HEADER=1 \
    "$ROOT_DIR/Scripts/build-and-run.sh"

  log_info "Packaging production bundle at $RELEASE_DIR/$APP_NAME.app"
  BUNDLE_IDENTIFIER="com.chau7.app" \
    CHAU7_BUILD_CHANNEL="release" \
    CHAU7_CODESIGN_PURPOSE="install" \
    CHAU7_LOG_FILE="$LOG_FILE" \
    CHAU7_LOG_SUMMARY=0 \
    CHAU7_LOG_SUPPRESS_HEADER=1 \
    "$ROOT_DIR/Scripts/build-app.sh" \
    "$ROOT_DIR/.build/$BUILD_MODE" \
    "$RELEASE_DIR"

  verify_bundle "$RELEASE_DIR/$APP_NAME.app" "$current_sha"
  log_ok "New bundle is complete; the running app has not been stopped yet."
}

install_bundle() {
  local source_app="$1"
  local timestamp backup_root previous_app install_parent
  LAST_STEP="atomic install"
  install_parent="$(dirname "$DST_APP")"
  backup_root="${CHAU7_RELEASE_BACKUP_DIR:-$HOME/Library/Application Support/Chau7/ReleaseBackups}"
  timestamp="$(date -u '+%Y%m%d-%H%M%S')-$$"
  BACKUP_PATH="$backup_root/$APP_NAME-$timestamp.app"
  previous_app="$DST_APP.previous.$$"

  mkdir -p "$install_parent" "$backup_root"
  if [[ -e "$BACKUP_PATH" ]]; then
    log_error "Rollback path already exists: $BACKUP_PATH"
    log_error "Refusing to merge into an existing backup. Remove it manually or retry later."
    return 1
  fi
  if [[ -L "$DST_APP" || -L "$BACKUP_PATH" ]]; then
    log_error "Refusing to replace a symlinked app or rollback path."
    return 1
  fi
  INSTALL_STAGING_DIR="$(mktemp -d "$install_parent/.chau7-install.XXXXXX")"
  log_info "Staging verified bundle before replacing $DST_APP"
  /usr/bin/ditto "$source_app" "$INSTALL_STAGING_DIR/$APP_NAME.app"
  verify_bundle "$INSTALL_STAGING_DIR/$APP_NAME.app" \
    "$(plist_value Chau7BuildGitSHA "$source_app/Contents/Info.plist")"

  if [[ -e "$DST_APP" ]]; then
    # Keep a copy outside /Applications for rollback, then use same-volume
    # renames for the actual replacement so ditto cannot leave stale files.
    log_info "Saving previous app bundle to $BACKUP_PATH"
    /usr/bin/ditto "$DST_APP" "$BACKUP_PATH"
    if ! mv "$DST_APP" "$previous_app"; then
      log_error "Unable to move the previous app aside for atomic replacement."
      return 1
    fi
    MOVED_OLD_APP=1
  fi

  if ! mv "$INSTALL_STAGING_DIR/$APP_NAME.app" "$DST_APP"; then
    log_error "Atomic app replacement failed."
    if [[ "$MOVED_OLD_APP" == "1" && -e "$previous_app" ]]; then
      mv "$previous_app" "$DST_APP" || true
      MOVED_OLD_APP=0
    fi
    return 1
  fi
  if [[ "$MOVED_OLD_APP" == "1" && -e "$previous_app" ]]; then
    # The rollback copy above is retained; remove only the temporary renamed
    # directory after the new destination is in place.
    rm -rf -- "$previous_app" || log_warn "Temporary previous app remains at $previous_app"
    MOVED_OLD_APP=0
  fi

  verify_bundle "$DST_APP" \
    "$(plist_value Chau7BuildGitSHA "$DST_APP/Contents/Info.plist")"
  if [[ -x "$ROOT_DIR/Scripts/check-signing.sh" ]]; then
    # Keep the existing TCC-specific diagnostics in the release path. This is
    # warn-only so a locally ad-hoc signed bundle remains usable for testing.
    "$ROOT_DIR/Scripts/check-signing.sh" "$DST_APP" ||
      log_warn "TCC signing diagnostics reported a problem; inspect the release log."
  fi
  if [[ -n "$BACKUP_PATH" ]]; then
    log_ok "Installed $DST_APP (rollback copy: $BACKUP_PATH)"
  else
    log_ok "Installed $DST_APP (no previous bundle was present)"
  fi
}

log_init "Rebuild and Relaunch Chau7"
log_info "Build mode: $BUILD_MODE"
log_info "Install destination: $DST_APP"
log_info "Open after install: $OPEN_AFTER_INSTALL"
log_info "Force quit enabled: $FORCE_QUIT"
log_info "Dry run: $DRY_RUN"

if [[ "$DRY_RUN" == "1" ]]; then
  check_source_state
  if [[ "$QUIT_ONLY" == "1" ]]; then
    log_info "Dry run: would request a graceful quit; no POSIX signal unless --force is supplied."
  else
    log_info "Dry run: would build/verify, quit Chau7, atomically install, and relaunch."
  fi
  LAST_STEP="dry-run complete"
  exit 0
fi

if [[ "$QUIT_ONLY" == "1" ]]; then
  quit_chau7
  LAST_STEP="quit-only complete"
  exit 0
fi

check_source_state
require_command swift
require_command git
require_command /usr/bin/ditto

if [[ "$NO_INSTALL" != "1" && "$OPEN_AFTER_INSTALL" == "1" ]]; then
  require_command open
fi
if [[ "$NO_INSTALL" != "1" ]]; then
  check_install_preflight
fi

build_release_bundle

if [[ "$NO_INSTALL" == "1" ]]; then
  LAST_STEP="build-only complete"
  log_ok "Build-only mode: leaving the running app untouched."
  exit 0
fi

quit_chau7
install_bundle "$RELEASE_DIR/$APP_NAME.app"

if [[ "$OPEN_AFTER_INSTALL" == "1" ]]; then
  LAST_STEP="launch"
  log_info "Launching the verified installed bundle."
  if [[ ${#CHAU7_OPEN_ENV[@]} -gt 0 ]]; then
    open "${CHAU7_OPEN_ENV[@]}" "$DST_APP"
  else
    open "$DST_APP"
  fi
else
  log_info "Skipping launch (--no-launch)."
fi

LAST_STEP="complete"
log_ok "Chau7 rebuild, install, and relaunch completed."
