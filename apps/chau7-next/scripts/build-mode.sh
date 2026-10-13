#!/usr/bin/env bash
# Shared release settings for Chau7 Next packaging and the standalone CLI.
# Source from a Bash script after changing to apps/chau7-next.

BUILD_MODE="${BUILD_MODE:-fast}"
case "$BUILD_MODE" in
  fast)
    export CARGO_PROFILE_RELEASE_DEBUG=0
    export CARGO_PROFILE_RELEASE_STRIP=symbols
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=0
    ;;
  diagnostic)
    # Bypass CTO output filtering so compiler diagnostics reach the normal build log.
    export CHAU7_CTO_OPTIM_ACTIVE=1
    export CARGO_PROFILE_RELEASE_DEBUG=2
    export CARGO_PROFILE_RELEASE_STRIP=none
    export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG=2
    ;;
  *)
    echo "error: BUILD_MODE must be 'fast' or 'diagnostic' (got '$BUILD_MODE')" >&2
    return 2
    ;;
esac

# Keep symbol-rich artifacts separate from the default fast cache. Packaging
# sources this file from the app workspace after resolving explicit overrides.
if [[ "$BUILD_MODE" == diagnostic && -z "${CARGO_TARGET_DIR:-}" ]]; then
  export CARGO_TARGET_DIR="$PWD/target/diagnostic"
fi

# Keep optimized runtime code and avoid the expensive whole-program LTO pass.
# More codegen units and incremental state favor short local rebuilds; Cargo's
# global CARGO_INCREMENTAL setting still takes precedence (CI sets it to 0).
export CARGO_PROFILE_RELEASE_OPT_LEVEL=3
export CARGO_PROFILE_RELEASE_CODEGEN_UNITS=64
export CARGO_PROFILE_RELEASE_LTO=off
export CARGO_PROFILE_RELEASE_INCREMENTAL=true
# macOS 27 rejects some stripped proc-macro dylibs at compile time.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP=none

CARGO_BUILD_ARGS=(--locked --release)
case "${CARGO_BUILD_VERBOSE:-0}" in
  0) ;;
  1) CARGO_BUILD_ARGS+=(-vv) ;;
  *)
    echo "error: CARGO_BUILD_VERBOSE must be 0 or 1" >&2
    return 2
    ;;
esac

BUILD_LOG="${BUILD_LOG:-}"
if [[ -n "$BUILD_LOG" ]]; then
  case "$BUILD_LOG" in
    /*) ;;
    *) BUILD_LOG="$PWD/$BUILD_LOG" ;;
  esac
  mkdir -p "$(dirname "$BUILD_LOG")"
  : > "$BUILD_LOG"
fi

run_cargo() {
  if [[ -n "${BUILD_LOG:-}" ]]; then
    "$@" 2>&1 | tee -a "$BUILD_LOG"
  else
    "$@"
  fi
}

printf 'Build mode: %s (opt-level=%s, codegen-units=%s, LTO=%s, incremental=%s, debug=%s, strip=%s)\n' \
  "$BUILD_MODE" \
  "$CARGO_PROFILE_RELEASE_OPT_LEVEL" \
  "$CARGO_PROFILE_RELEASE_CODEGEN_UNITS" \
  "$CARGO_PROFILE_RELEASE_LTO" \
  "${CARGO_INCREMENTAL:-$CARGO_PROFILE_RELEASE_INCREMENTAL}" \
  "$CARGO_PROFILE_RELEASE_DEBUG" \
  "$CARGO_PROFILE_RELEASE_STRIP"
