#!/usr/bin/env bash
# Build "Chau7 Next.app" (bundle id com.chau7.next) next to the Swift app's
# bundle, without touching it. Usage:
#   ./scripts/bundle-macos.sh            # release build for this Mac's arch
#   OUT_DIR=~/Applications ./scripts/bundle-macos.sh
#   TARGET=x86_64-apple-darwin ./scripts/bundle-macos.sh   # another Mac arch
set -euo pipefail

# Every binary in the bundle is built for the same target and the same
# minimum macOS as LSMinimumSystemVersion below.
MIN_MACOS="13.0"
export MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS"
# Also protect the shared helper workspace's compile-time proc macros on macOS 27.
export CARGO_PROFILE_RELEASE_BUILD_OVERRIDE_STRIP="none"
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

cd "$ROOT"
cargo build --locked --release --target "$TARGET" --bin chau7-next --bin chau7-next-mcp-bridge --bin chau7-next-cli
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
for audit_file in README.md gpui-provenance.json gpui-modifications.json; do
  cp "$ROOT/vendor/$audit_file" "$GPUI_LICENSES/$audit_file"
done
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
if [ -d "$OPTIM_DIR" ]; then
  (cd "$OPTIM_DIR" && { rustup target add "$TARGET" >/dev/null 2>&1 || true; } \
    && cargo build --locked --release --target "$TARGET" -p chau7_optim -p chau7_md)
  OPTIM_OUT="${OPTIM_TARGET_DIR:-${CARGO_TARGET_DIR:-$OPTIM_DIR/target}}/$TARGET/release"
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
  (cd "$REMOTE_SRC" && CGO_ENABLED=0 go build -trimpath -o "$APP/Contents/MacOS/chau7-remote" ./cmd/chau7-remote)
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
  (cd "$PROXY_SRC" && CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o "$APP/Contents/MacOS/chau7-proxy" .)
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
done
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built: $APP"
