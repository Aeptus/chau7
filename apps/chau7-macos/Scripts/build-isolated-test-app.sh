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
REAL_BINARY_REL="Contents/Resources/Chau7-real"
LAUNCHER_PATH="$TEST_APP_PATH/Contents/MacOS/Chau7"

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

ISOLATED_HOME="$TEST_APP_PATH/Contents/isolation-home"

mkdir -p \
  "$ISOLATED_HOME/Library/Application Support" \
  "$ISOLATED_HOME/Library/Logs" \
  "$ISOLATED_HOME/.chau7"

mv "$TEST_APP_PATH/Contents/MacOS/Chau7" "$TEST_APP_PATH/$REAL_BINARY_REL"

cat > "$LAUNCHER_PATH" <<EOF
#!/usr/bin/env bash
set -euo pipefail
APP_CONTENTS="\$(cd "\$(dirname "\$0")/.." && pwd)"
ISOLATED_HOME="\$APP_CONTENTS/isolation-home"
export HOME="\$ISOLATED_HOME"
export CHAU7_HOME_ROOT="\$ISOLATED_HOME"
export CHAU7_KEYCHAIN_SERVICE_PREFIX="$BUNDLE_IDENTIFIER"
export CHAU7_ISOLATED_TEST_MODE=1
exec "\$APP_CONTENTS/Resources/Chau7-real" "\$@"
EOF
chmod +x "$LAUNCHER_PATH"

cat > "$ISOLATED_HOME/README.txt" <<EOF
This directory is the isolated HOME for $TEST_APP_NAME.

The launcher sets:
- HOME=$ISOLATED_HOME
- CHAU7_HOME_ROOT=$ISOLATED_HOME
- CHAU7_KEYCHAIN_SERVICE_PREFIX=$BUNDLE_IDENTIFIER

This keeps the test app away from the main app's UserDefaults domain,
Application Support, logs, ~/.chau7 state, and Keychain service names.
EOF

# Re-sign every nested Mach-O ad-hoc WITHOUT hardened runtime, then seal the
# bundle. build-app.sh signs everything Developer-ID + hardened runtime; once we
# swap the main executable for the shell launcher and re-seal, the bundle is
# inconsistent and AMFI SIGKILLs it on launch (exit 137) — library validation
# under the runtime flag rejects the tampered/ad-hoc bundle. Dropping the runtime
# flag (plain ad-hoc) removes library validation so the LOCAL test app runs. The
# shell launcher itself is not Mach-O, so it is skipped and stays executable.
echo "Re-signing nested Mach-O ad-hoc (no hardened runtime) for local launch"
while IFS= read -r -d '' macho; do
  if file "$macho" | grep -q "Mach-O"; then
    codesign --remove-signature "$macho" 2>/dev/null || true
    codesign --force --sign - "$macho"
  fi
done < <(find "$TEST_APP_PATH/Contents" -type f -print0)
codesign --force --sign - "$TEST_APP_PATH"

echo "Isolated test app ready:"
echo "  $TEST_APP_PATH"

if [[ "$OPEN_AFTER_BUILD" == "1" ]]; then
  open "$TEST_APP_PATH"
fi
