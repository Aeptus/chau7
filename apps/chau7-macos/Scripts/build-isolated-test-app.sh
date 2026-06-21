#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_MODE="${BUILD_MODE:-debug}"
OPEN_AFTER_BUILD="${OPEN_AFTER_BUILD:-0}"
TEST_APP_NAME="${TEST_APP_NAME:-Chau7 Test}"
BUNDLE_IDENTIFIER="${BUNDLE_IDENTIFIER:-com.chau7.app.isolated}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/build/isolation}"
ISOLATED_HOME="${ISOLATED_HOME:-$OUT_DIR/embedded-home}"
MODULE_CACHE_ROOT="${MODULE_CACHE_ROOT:-$OUT_DIR/module-cache}"
BASE_APP_PATH="$OUT_DIR/Chau7.app"
TEST_APP_PATH="$OUT_DIR/$TEST_APP_NAME.app"

export PATH="/Applications/Xcode.app/Contents/Developer/usr/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$MODULE_CACHE_ROOT/clang}"
export SWIFT_MODULE_CACHE_PATH="${SWIFT_MODULE_CACHE_PATH:-$MODULE_CACHE_ROOT/swift}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFT_MODULE_CACHE_PATH"

echo "Building isolated test app"
echo "  build mode: $BUILD_MODE"
echo "  bundle id:  $BUNDLE_IDENTIFIER"
echo "  app path:   $TEST_APP_PATH"
echo "  home root:  $ISOLATED_HOME"

swift build -c "$BUILD_MODE" --package-path "$ROOT_DIR"

# Kill any running instance of this test app first. Its terminal shell CWDs into
# the isolation home under $OUT_DIR, so a live instance makes `rm -rf "$OUT_DIR"`
# fail with "Directory not empty" (files reappear mid-delete). Stable app untouched.
pkill -f "$TEST_APP_PATH/Contents/MacOS/Chau7" 2>/dev/null || true
sleep 1

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" \
OPEN_AFTER_BUILD=0 \
SHOW_DOCK_ICON=1 \
"$ROOT_DIR/Scripts/build-app.sh" "$ROOT_DIR/.build/$BUILD_MODE" "$OUT_DIR"

mv "$BASE_APP_PATH" "$TEST_APP_PATH"

# Label the bundle so the Dock / menu bar clearly distinguish the isolated
# test app from the stable one (segregation has to be visible, not just on disk).
PLIST="$TEST_APP_PATH/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $TEST_APP_NAME" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $TEST_APP_NAME" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $TEST_APP_NAME" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $TEST_APP_NAME" "$PLIST"

# The isolation home lives OUTSIDE the .app bundle (sibling of it). It must NOT
# be inside Contents/: at startup the app installs helper executables
# (chau7-mcp-bridge etc.) into ~/.chau7/bin via FileManager.copyItem, and cloning
# an executable INTO the running, code-signed app bundle deadlocks in the kernel's
# clonefileat/code-signing validation — the main thread hangs in
# MCPServerManager.installExecutableIfNeeded and the terminal never opens. Writing
# to an external dir (like the stable app's real ~/.chau7) avoids that entirely and
# also keeps the signed bundle's contents clean.
ISOLATED_HOME="$OUT_DIR/home"

mkdir -p \
  "$ISOLATED_HOME/Library/Application Support" \
  "$ISOLATED_HOME/Library/Logs" \
  "$ISOLATED_HOME/.chau7"

# Inject the isolation environment via Info.plist LSEnvironment rather than a
# shell-script launcher. A wrapper that exec'd a binary in Contents/Resources
# made Bundle.main resolve to Resources (bundleIdentifier == nil), which disabled
# notifications and pushed UserDefaults into a "Chau7-real" fallback domain. With
# LSEnvironment the real Mach-O stays at Contents/MacOS/Chau7, so bundle identity
# (com.chau7.app.isolated) is intact AND every child process LaunchServices spawns
# inherits the isolation vars. CHAU7_HOME_ROOT does the heavy lifting (RuntimeIsolation
# routes app-support/logs/.chau7/telemetry through it); HOME covers the few direct
# NSHomeDirectory() callers. Paths are absolute (baked at build time) — fine while
# the bundle stays in build/isolation; rebuild if you move it.
/usr/libexec/PlistBuddy -c "Delete :LSEnvironment" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:HOME string $ISOLATED_HOME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHAU7_HOME_ROOT string $ISOLATED_HOME" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHAU7_KEYCHAIN_SERVICE_PREFIX string $BUNDLE_IDENTIFIER" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :LSEnvironment:CHAU7_ISOLATED_TEST_MODE string 1" "$PLIST"

cat > "$ISOLATED_HOME/README.txt" <<EOF
This directory is the isolated HOME for $TEST_APP_NAME.

Injected via Info.plist LSEnvironment:
- HOME=$ISOLATED_HOME
- CHAU7_HOME_ROOT=$ISOLATED_HOME
- CHAU7_KEYCHAIN_SERVICE_PREFIX=$BUNDLE_IDENTIFIER
- CHAU7_ISOLATED_TEST_MODE=1

This keeps the test app away from the main app's UserDefaults domain,
Application Support, logs, ~/.chau7 state, and Keychain service names.
EOF

# Re-sign every nested Mach-O ad-hoc WITHOUT hardened runtime, then seal the
# bundle. build-app.sh signs everything Developer-ID + hardened runtime; editing
# Info.plist (label + LSEnvironment) invalidates that seal, and the runtime flag's
# library validation then makes AMFI SIGKILL the app on launch (exit 137). Dropping
# the runtime flag (plain ad-hoc) removes library validation so the LOCAL test app
# runs. Sign nested Mach-O first, then the bundle.
echo "Re-signing nested Mach-O ad-hoc (no hardened runtime) for local launch"
while IFS= read -r -d '' macho; do
  if file "$macho" | grep -q "Mach-O"; then
    codesign --remove-signature "$macho" 2>/dev/null || true
    codesign --force --sign - "$macho"
  fi
done < <(find "$TEST_APP_PATH/Contents" -type f -print0)
codesign --force --sign - "$TEST_APP_PATH"

# Force LaunchServices to re-read the bundle's LSEnvironment. It caches env per
# bundle path, so a rebuild at the same path can otherwise launch with a stale
# isolation home.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$TEST_APP_PATH" 2>/dev/null || true

echo "Isolated test app ready:"
echo "  $TEST_APP_PATH"

if [[ "$OPEN_AFTER_BUILD" == "1" ]]; then
  open "$TEST_APP_PATH"
fi
