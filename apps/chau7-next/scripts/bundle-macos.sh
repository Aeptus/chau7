#!/usr/bin/env bash
# Build "Chau7 Next.app" (bundle id com.chau7.next) next to the Swift app's
# bundle, without touching it. Usage:
#   ./scripts/bundle-macos.sh            # fast optimized build for this Mac's arch
#   BUILD_MODE=diagnostic ./scripts/bundle-macos.sh # explicit symbol-rich rebuild
#   CARGO_BUILD_VERBOSE=1 BUILD_LOG=target/logs/fast.log ./scripts/bundle-macos.sh
#   OUT_DIR=~/Applications ./scripts/bundle-macos.sh
#   TARGET=x86_64-apple-darwin ./scripts/bundle-macos.sh   # another Mac arch
set -euo pipefail

# Every binary in the bundle is built for the same target and the same
# minimum macOS as LSMinimumSystemVersion below.
MIN_MACOS="13.0"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
case "${TARGET:-$(uname -m)}" in
  aarch64-apple-darwin | arm64) TARGET="aarch64-apple-darwin"; GOARCH="arm64" ;;
  x86_64-apple-darwin | x86_64) TARGET="x86_64-apple-darwin"; GOARCH="amd64" ;;
  *) echo "error: unsupported target ${TARGET:-$(uname -m)}" >&2; exit 1 ;;
esac
export GOOS="darwin" GOARCH

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT/target/bundle}"
APP="$OUT_DIR/Chau7 Next.app"
VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed -E 's/.*"(.*)"/\1/')"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
if [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]; then
  SOURCE_DIRTY_BEFORE_JSON=false
else
  SOURCE_DIRTY_BEFORE_JSON=true
fi

cd "$ROOT"
# Resolve a caller-selected relative target directory from the app workspace so
# both workspaces use the same explicit target path after changing directories.
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
  case "$CARGO_TARGET_DIR" in
    /*) ;;
    *) CARGO_TARGET_DIR="$ROOT/$CARGO_TARGET_DIR" ;;
  esac
  export CARGO_TARGET_DIR
fi
# shellcheck source=apps/chau7-next/scripts/build-mode.sh
source "$ROOT/scripts/build-mode.sh"
APP_CARGO_COMMAND=(cargo build "${CARGO_BUILD_ARGS[@]}" --target "$TARGET" \
  --bin chau7-next --bin chau7-next-mcp-bridge --bin chau7-next-cli)
run_cargo "${APP_CARGO_COMMAND[@]}"
RELEASE_DIR="${CARGO_TARGET_DIR:-$ROOT/target}/$TARGET/release"
BIN="$RELEASE_DIR/chau7-next"
# MCP bridge: the app copies it to ~/.chau7-next/bin on launch.
BRIDGE="$RELEASE_DIR/chau7-next-mcp-bridge"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Chau7 Next"
cp "$BRIDGE" "$APP/Contents/MacOS/chau7-next-mcp-bridge"
cp "$RELEASE_DIR/chau7-next-cli" "$APP/Contents/MacOS/chau7-next-cli"
cp -R "$ROOT/resources/skills" "$APP/Contents/Resources/Skills"
cp "$ROOT/../chau7-macos/Resources/AppDockIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ship attribution and the source audit trail for the three modified, locked
# Apache-2.0 GPUI packages. Missing required notices fail packaging before signing.
GPUI_LICENSES="$APP/Contents/Resources/licenses/gpui"
mkdir -p "$GPUI_LICENSES"
for audit_file in README.md gpui-provenance.json gpui-modifications.json gpui-rebase-0.3.8-to-0.3.9.json; do
  cp "$ROOT/vendor/$audit_file" "$GPUI_LICENSES/$audit_file"
done
mkdir -p "$GPUI_LICENSES/history"
cp -R "$ROOT/vendor/history/0.3.8" "$GPUI_LICENSES/history/0.3.8"
for package in gpui-pre gpui-pre-macos gpui-pre-apple; do
  mkdir -p "$GPUI_LICENSES/$package"
  cp "$ROOT/vendor/$package/LICENSE-APACHE" "$GPUI_LICENSES/$package/LICENSE-APACHE"
done

# Token optimizer and markdown renderer (the apps/chau7-macos/rust
# workspace), next to the app binary. The app installs them into
# ~/.chau7-next/bin; the wrappers pass CHAU7_CTO_BIN_DIR so chau7-optim also
# strips Chau7 Next's wrapper folder from PATH. That workspace pins its own
# toolchain (rust-toolchain.toml), which may lack the target's standard library.
OPTIM_DIR="$ROOT/../chau7-macos/rust"
HELPER_CARGO_COMMAND=()
if [ -d "$OPTIM_DIR" ]; then
  # Reuse the app's private per-worktree target cache by default. Explicit
  # helper-cache selection wins; otherwise CARGO_TARGET_DIR applies to both.
  OPTIM_TARGET_DIR="${OPTIM_TARGET_DIR:-${CARGO_TARGET_DIR:-$ROOT/target}}"
  case "$OPTIM_TARGET_DIR" in
    /*) ;;
    *) OPTIM_TARGET_DIR="$ROOT/$OPTIM_TARGET_DIR" ;;
  esac
  HELPER_CARGO_COMMAND=(cargo build "${CARGO_BUILD_ARGS[@]}" --target "$TARGET" \
    -p chau7_optim -p chau7_md)
  (cd "$OPTIM_DIR" && { rustup target add "$TARGET" >/dev/null 2>&1 || true; } \
    && CARGO_TARGET_DIR="$OPTIM_TARGET_DIR" run_cargo "${HELPER_CARGO_COMMAND[@]}")
  OPTIM_OUT="$OPTIM_TARGET_DIR/$TARGET/release"
  for tool in chau7-optim chau7-md; do
    if [ ! -f "$OPTIM_OUT/$tool" ]; then
      echo "error: $tool was not built at $OPTIM_OUT" >&2
      exit 1
    fi
    cp "$OPTIM_OUT/$tool" "$APP/Contents/MacOS/$tool"
  done
fi

# Remote control agent (services/chau7-remote), next to the app binary. The
# app copies it into its own state folder and starts it when Remote Control
# is enabled. Needs Go; set REQUIRE_REMOTE_AGENT=1 to fail without it (CI).
REMOTE_SRC="$ROOT/../../services/chau7-remote"
if command -v go >/dev/null 2>&1; then
  if [ "$BUILD_MODE" = "fast" ]; then
    (cd "$REMOTE_SRC" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
      -o "$APP/Contents/MacOS/chau7-remote" ./cmd/chau7-remote)
  else
    (cd "$REMOTE_SRC" && CGO_ENABLED=0 go build -trimpath \
      -o "$APP/Contents/MacOS/chau7-remote" ./cmd/chau7-remote)
  fi
elif [ "${REQUIRE_REMOTE_AGENT:-0}" = "1" ]; then
  echo "error: Go is required to build the remote control agent" >&2
  exit 1
else
  echo "warning: Go not found, the app is built without the remote control agent" >&2
fi

# API analytics proxy (apps/chau7-macos/chau7-proxy), next to the app binary.
# Chau7 Next starts it with its own ports, database and socket when "Enable
# API Analytics" is on. Needs Go; set REQUIRE_PROXY=1 to fail without it (CI).
PROXY_SRC="$ROOT/../chau7-macos/chau7-proxy"
if command -v go >/dev/null 2>&1; then
  if [ "$BUILD_MODE" = "fast" ]; then
    (cd "$PROXY_SRC" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" \
      -o "$APP/Contents/MacOS/chau7-proxy" .)
  else
    (cd "$PROXY_SRC" && CGO_ENABLED=0 go build -trimpath \
      -o "$APP/Contents/MacOS/chau7-proxy" .)
  fi
elif [ "${REQUIRE_PROXY:-0}" = "1" ]; then
  echo "error: Go is required to build the API analytics proxy" >&2
  exit 1
else
  echo "warning: Go not found, the app is built without the API analytics proxy" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Chau7 Next</string>
  <key>CFBundleIdentifier</key><string>com.chau7.next</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Chau7 Next</string>
  <key>CFBundleDisplayName</key><string>Chau7 Next</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>Chau7NextSourceRevision</key><string>${SOURCE_REVISION}</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>LSMultipleInstancesProhibited</key><true/>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.chau7.next</string>
      <key>CFBundleURLSchemes</key>
      <array><string>chau7-next</string></array>
    </dict>
  </array>
  <key>NSUserNotificationUsageDescription</key><string>Chau7 Next notifies you when a command finishes or an AI agent needs your attention.</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so macOS runs it locally. Downloaded builds still carry the
# quarantine flag: see apps/chau7-next/README.md. The helpers next to the app
# binary are signed one by one first (--deep does not cover Contents/MacOS),
# then the app, which seals them.
for helper in "$APP/Contents/MacOS/"*; do
  [ "$(basename "$helper")" = "Chau7 Next" ] && continue
  codesign --force --sign - --timestamp=none "$helper"
  codesign --verify --strict --verbose=2 "$helper"
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"

# Keep evidence beside the per-worktree build cache, outside the signed app.
# The hashes cover final post-sign bytes, so the bundle signature remains valid.
BUILD_METADATA_DIR="${BUILD_METADATA_DIR:-$OUT_DIR}"
case "$BUILD_METADATA_DIR" in
  /*) ;;
  *) BUILD_METADATA_DIR="$ROOT/$BUILD_METADATA_DIR" ;;
esac
mkdir -p "$BUILD_METADATA_DIR"
BUILD_METADATA_DIR="$(cd "$BUILD_METADATA_DIR" && pwd -P)"
APP_REAL_PATH="$(cd "$APP" && pwd -P)"
case "$BUILD_METADATA_DIR" in
  "$APP_REAL_PATH"|"$APP_REAL_PATH"/*)
    echo "error: build metadata must be outside the signed app bundle" >&2
    exit 1
    ;;
esac
BUILD_METADATA="$BUILD_METADATA_DIR/Chau7-Next-$TARGET-$BUILD_MODE.json"
MANIFEST_TMP="$(mktemp "$BUILD_METADATA_DIR/.Chau7-Next-$TARGET-$BUILD_MODE.XXXXXX")"
trap 'rm -f "$MANIFEST_TMP"' EXIT

json_string() {
  local value="$1"
  local code control
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\b'/\\b}
  value=${value//$'\f'/\\f}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  # JSON has no literal representation for the other C0 control bytes. Reject
  # these rare compiler/version output bytes instead of writing invalid JSON.
  for code in 1 2 3 4 5 6 7 11 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31; do
    printf -v control '%b' "\\$(printf '%03o' "$code")"
    if [[ "$value" == *"$control"* ]]; then
      echo "error: compiler/build metadata contains an unsupported control character" >&2
      exit 1
    fi
  done
  printf '"%s"' "$value"
}

json_array() {
  local separator=""
  local argument
  printf '['
  for argument in "$@"; do
    printf '%s' "$separator"
    json_string "$argument"
    separator=', '
  done
  printf ']'
}

artifact_sha256() {
  local artifact="$1"
  local digest
  if [ -x "$artifact" ]; then
    digest="$(shasum -a 256 "$artifact" | awk '{print $1}')"
    case "$digest" in
      *[!0123456789abcdefABCDEF]*|'')
        echo "error: invalid SHA-256 output for $artifact" >&2
        exit 1
        ;;
    esac
    if [ "${#digest}" -ne 64 ]; then
      echo "error: incomplete SHA-256 output for $artifact" >&2
      exit 1
    fi
    printf '"%s"' "$digest"
  elif [ -e "$artifact" ]; then
    echo "error: packaged artifact is not executable: $artifact" >&2
    exit 1
  else
    printf 'null'
  fi
}

APP_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/Chau7 Next")"
BRIDGE_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/chau7-next-mcp-bridge")"
CLI_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/chau7-next-cli")"
OPTIM_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/chau7-optim")"
MARKDOWN_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/chau7-md")"
REMOTE_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/chau7-remote")"
PROXY_SHA256="$(artifact_sha256 "$APP/Contents/MacOS/chau7-proxy")"
RUSTC_VERSION="$(rustc --version)"
CARGO_VERSION="$(cargo --version)"
if [ -d "$OPTIM_DIR" ]; then
  HELPER_RUSTC_VERSION="$(cd "$OPTIM_DIR" && rustc --version)"
  HELPER_CARGO_VERSION="$(cd "$OPTIM_DIR" && cargo --version)"
else
  HELPER_RUSTC_VERSION="unavailable"
  HELPER_CARGO_VERSION="unavailable"
fi
FINAL_SOURCE_REVISION="$(git -C "$ROOT" rev-parse HEAD)"
if [ "$FINAL_SOURCE_REVISION" != "$SOURCE_REVISION" ]; then
  echo "error: source revision changed during the package build" >&2
  exit 1
fi
if [ "$SOURCE_DIRTY_BEFORE_JSON" = false ] \
  && [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=all)" ]; then
  SOURCE_DIRTY_JSON=false
else
  SOURCE_DIRTY_JSON=true
fi
if command -v go >/dev/null 2>&1; then
  GO_VERSION="$(go version)"
  if [ "$BUILD_MODE" = "fast" ]; then
    GO_LDFLAGS_JSON='["-s", "-w"]'
  else
    GO_LDFLAGS_JSON='[]'
  fi
else
  GO_VERSION="unavailable"
  GO_LDFLAGS_JSON='[]'
fi
CLANG_VERSION="$(clang --version | sed -n '1p')"
case "${CARGO_INCREMENTAL:-$CARGO_PROFILE_RELEASE_INCREMENTAL}" in
  1|true) INCREMENTAL_JSON=true ;;
  0|false) INCREMENTAL_JSON=false ;;
  *) echo "error: invalid effective CARGO_INCREMENTAL value" >&2; exit 1 ;;
esac
cat > "$MANIFEST_TMP" <<JSON
{
  "schemaVersion": 1,
  "buildMode": $(json_string "$BUILD_MODE"),
  "target": $(json_string "$TARGET"),
  "minimumMacOS": $(json_string "$MIN_MACOS"),
  "version": $(json_string "$VERSION"),
  "buildNumber": $(json_string "$BUILD_NUMBER"),
  "sourceRevision": $(json_string "$SOURCE_REVISION"),
  "sourceDirty": $SOURCE_DIRTY_JSON,
  "bundleIdentifier": "com.chau7.next",
  "bundlePath": "Chau7 Next.app",
  "appSignatureVerified": true,
  "cargoCommands": {
    "app": $(json_array "${APP_CARGO_COMMAND[@]}"),
    "sharedHelpers": $(if [ "${#HELPER_CARGO_COMMAND[@]}" -gt 0 ]; then json_array "${HELPER_CARGO_COMMAND[@]}"; else printf 'null'; fi)
  },
  "cargoBuildJobsEnv": $(json_string "${CARGO_BUILD_JOBS:-unset}"),
  "goBuild": {
    "trimPath": true,
    "ldflags": $GO_LDFLAGS_JSON
  },
  "profile": {
    "optLevel": 3,
    "codegenUnits": 64,
    "lto": "off",
    "incremental": $INCREMENTAL_JSON,
    "debugLevel": $CARGO_PROFILE_RELEASE_DEBUG,
    "strip": $(json_string "$CARGO_PROFILE_RELEASE_STRIP"),
    "buildOverrideDebug": $(json_string "${CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_DEBUG:-default}"),
    "buildOverrideStrip": $(json_string "$CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP"),
    "cargoVerbose": $(json_string "${CARGO_BUILD_VERBOSE:-0}")
  },
  "compilers": {
    "rustc": $(json_string "$RUSTC_VERSION"),
    "cargo": $(json_string "$CARGO_VERSION"),
    "helperRustc": $(json_string "$HELPER_RUSTC_VERSION"),
    "helperCargo": $(json_string "$HELPER_CARGO_VERSION"),
    "go": $(json_string "$GO_VERSION"),
    "clang": $(json_string "$CLANG_VERSION")
  },
  "artifacts": {
    "Chau7 Next": {"path": "Contents/MacOS/Chau7 Next", "sha256": $APP_SHA256},
    "chau7-next-mcp-bridge": {"path": "Contents/MacOS/chau7-next-mcp-bridge", "sha256": $BRIDGE_SHA256},
    "chau7-next-cli": {"path": "Contents/MacOS/chau7-next-cli", "sha256": $CLI_SHA256},
    "chau7-optim": {"path": "Contents/MacOS/chau7-optim", "sha256": $OPTIM_SHA256},
    "chau7-md": {"path": "Contents/MacOS/chau7-md", "sha256": $MARKDOWN_SHA256},
    "chau7-remote": {"path": "Contents/MacOS/chau7-remote", "sha256": $REMOTE_SHA256},
    "chau7-proxy": {"path": "Contents/MacOS/chau7-proxy", "sha256": $PROXY_SHA256}
  }
}
JSON
mv -f "$MANIFEST_TMP" "$BUILD_METADATA"
echo "Build evidence: $BUILD_METADATA"
echo "Built: $APP"
