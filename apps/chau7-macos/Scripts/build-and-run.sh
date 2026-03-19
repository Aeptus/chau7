#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Chau7"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_MODE="${BUILD_MODE:-release}"
OPEN_AFTER_BUILD="${OPEN_AFTER_BUILD:-1}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.chau7.app.dev}"
CODESIGN_IDENTITY="${CHAU7_CODESIGN_IDENTITY:--}"
USE_STABLE_ADHOC_REQUIREMENT="${USE_STABLE_ADHOC_REQUIREMENT:-1}"
BIN_PATH="(not built)"
APP_PATH="(not built)"

export CHAU7_LOG_ROOT="$ROOT_DIR"
CHAU7_LOG_NAME="build-and-run"
export CHAU7_LOG_NAME

source "$ROOT_DIR/Scripts/logging.sh"

start_ts=$(date +%s)
STATUS="success"
LAST_STEP="init"

summary() {
  end_ts=$(date +%s)
  elapsed=$((end_ts - start_ts))

  log_divider
  log_info "Build Summary"
  log_info "Status: $STATUS"
  log_info "Last step: $LAST_STEP"
  log_info "Build mode: $BUILD_MODE"
  log_info "Binary: $BIN_PATH"
  log_info "App bundle: $APP_PATH"
  log_info "Bundle identifier: $BUNDLE_IDENTIFIER"
  log_info "Codesign identity: $CODESIGN_IDENTITY"
  log_info "Stable ad-hoc requirement: $USE_STABLE_ADHOC_REQUIREMENT"
  log_info "Dock icon: enabled (set SHOW_DOCK_ICON=0 to hide)"
  log_info "Duration: $(log_duration_human)"
  if [[ "$STATUS" == "success" ]]; then
    log_info "Next: run 'CHAU7_VERBOSE=1 $APP_PATH/Contents/MacOS/$APP_NAME' for verbose logs."
  else
    log_warn "Next: fix build errors, then rerun ./Scripts/build-and-run.sh"
  fi
}

on_exit() {
  local code=$?
  if [[ $code -ne 0 ]]; then
    STATUS="failed"
  fi
  summary
}

trap on_exit EXIT

log_init "Build and Run"
log_info "Build mode: $BUILD_MODE"
log_info "Open after build: $OPEN_AFTER_BUILD"
log_info "Bundle identifier: $BUNDLE_IDENTIFIER"
log_info "Codesign identity: $CODESIGN_IDENTITY"
log_info "Stable ad-hoc requirement: $USE_STABLE_ADHOC_REQUIREMENT"

if [[ "$BUNDLE_IDENTIFIER" == "com.chau7.app" ]]; then
  RUNNING_CHAU7="$(
    ps -axo pid=,args= 2>/dev/null \
      | awk 'match($0, /^[[:space:]]*[0-9]+[[:space:]]+.+\/Chau7\.app\/Contents\/MacOS\/Chau7([[:space:]]|$)/) { print $0 }' \
      | sed 's/^[[:space:]]*//'
  )"

  if [[ -n "$RUNNING_CHAU7" ]]; then
    log_error "Refusing to build with production bundle identifier while Chau7 is running."
    log_error "Running instance(s):"
    while IFS= read -r proc; do
      [[ -n "$proc" ]] || continue
      log_error "  $proc"
    done <<< "$RUNNING_CHAU7"
    log_error "This causes TCC code-requirement mismatches and repeated permission prompts."
    log_info "Use default com.chau7.app.dev for local runs, or quit Chau7 and run ./Scripts/install-launchpad-app.sh"
    exit 1
  fi
fi

if ! command -v swift >/dev/null 2>&1; then
  log_error "Swift not found in PATH. Install Xcode or Swift toolchain."
  exit 1
fi

if [[ ! -f "$ROOT_DIR/Package.swift" ]]; then
  log_error "Package.swift not found at $ROOT_DIR."
  exit 1
fi

# Build Rust libraries (optional but recommended for Rust terminal backend)
LAST_STEP="Rust Libraries"
if command -v cargo >/dev/null 2>&1; then
  RUST_BUILD_FLAG="--release"
  if [[ "$BUILD_MODE" == "debug" ]]; then
    RUST_BUILD_FLAG="--debug"
  fi
  log_info "Building Rust libraries ($BUILD_MODE mode)..."
  if "$ROOT_DIR/Scripts/build-rust.sh" $RUST_BUILD_FLAG; then
    log_ok "Rust libraries built successfully"
  else
    log_warn "Rust library build failed (Rust terminal backend will be unavailable)"
  fi
else
  log_warn "cargo not found; skipping Rust library build (Rust terminal backend will be unavailable)"
fi

LAST_STEP="Remote Agent"
if command -v go >/dev/null 2>&1; then
  log_info "Building remote agent..."
  run_cmd bash "$ROOT_DIR/Scripts/build-remote-agent.sh" --output "$ROOT_DIR/build/remote-agent/chau7-remote"
else
  log_warn "go not found; runtime will use an existing installed remote agent if present"
fi

LAST_STEP="Swift Build"
run_cmd swift build -c "$BUILD_MODE" --package-path "$ROOT_DIR"

BIN_PATH="$ROOT_DIR/.build/$BUILD_MODE/$APP_NAME"
if [[ ! -f "$BIN_PATH" ]]; then
  log_error "Binary not found at $BIN_PATH"
  exit 1
fi

LAST_STEP="Bundle"
CHAU7_LOG_FILE="$LOG_FILE" CHAU7_LOG_SUMMARY=0 CHAU7_LOG_SUPPRESS_HEADER=1 BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" "$ROOT_DIR/Scripts/build-app.sh" "$ROOT_DIR/.build/$BUILD_MODE" "$ROOT_DIR/build"

APP_PATH="$ROOT_DIR/build/$APP_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
  log_warn "App bundle not found at $APP_PATH"
else
  log_info "App bundle created at $APP_PATH"
fi

codesign_app() {
  if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    run_cmd codesign --force --deep --sign "$CODESIGN_IDENTITY" -i "$BUNDLE_IDENTIFIER" "$APP_PATH"
    return
  fi

  if [[ "$USE_STABLE_ADHOC_REQUIREMENT" == "1" ]] && command -v csreq >/dev/null 2>&1; then
    local req_file req_option
    req_file="$(mktemp "${TMPDIR:-/tmp}/chau7-codesign-requirement.XXXXXX")"
    req_option="-r=designated => identifier \"$BUNDLE_IDENTIFIER\""
    run_cmd csreq "$req_option" -b "$req_file"
    run_cmd codesign --force --deep --sign - -i "$BUNDLE_IDENTIFIER" -r "$req_file" "$APP_PATH"
    run_cmd rm -f "$req_file"
    log_ok "Applied stable ad-hoc designated requirement for $BUNDLE_IDENTIFIER"
    return
  fi

  if [[ "$USE_STABLE_ADHOC_REQUIREMENT" == "1" ]]; then
    log_warn "csreq not found; falling back to default ad-hoc signing (may trigger repeated TCC prompts on updates)."
  fi
  run_cmd codesign --force --deep --sign - -i "$BUNDLE_IDENTIFIER" "$APP_PATH"
}

if command -v codesign >/dev/null 2>&1; then
  LAST_STEP="Codesign"
  codesign_app
else
  log_warn "codesign not found; skipping ad-hoc signing."
fi

if [[ "$OPEN_AFTER_BUILD" == "1" ]]; then
  LAST_STEP="Launch"
  run_cmd open "$APP_PATH"
else
  log_info "Skipping app launch (OPEN_AFTER_BUILD=$OPEN_AFTER_BUILD)"
fi
