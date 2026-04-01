#!/usr/bin/env bash
set -euo pipefail

# build-dist.sh — Build a shareable pre-release Chau7.dmg for testing.
#
# This script:
#   1. Rebuilds Go proxy with -trimpath (strips build-machine paths)
#   2. Rebuilds Rust libs/binaries in release mode
#   3. Rebuilds Swift in release mode
#   4. Assembles app bundle
#   5. Strips debug symbols from all binaries
#   6. Ad-hoc codesigns
#   7. Creates a DMG with install instructions and legal notices
#
# Usage:
#   ./Scripts/build-dist.sh                   # arm64 only (fast)
#   ./Scripts/build-dist.sh --universal       # arm64 + x86_64 (slow)

APP_NAME="Chau7"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
UNIVERSAL=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --universal) UNIVERSAL=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

info()  { echo -e "\033[0;32m[DIST]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[DIST]\033[0m $1"; }
error() { echo -e "\033[0;31m[DIST]\033[0m $1"; exit 1; }

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# ── 1. Go proxy (with -trimpath to remove /Users/... paths) ──
info "Building Go proxy..."
cd "$ROOT_DIR/chau7-proxy"
if $UNIVERSAL; then
    mkdir -p build/darwin
    GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o build/darwin/chau7-proxy-arm64 .
    GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o build/darwin/chau7-proxy-amd64 .
    lipo -create -output build/darwin/chau7-proxy build/darwin/chau7-proxy-arm64 build/darwin/chau7-proxy-amd64
else
    mkdir -p build/darwin
    go build -trimpath -ldflags "-s -w" -o build/darwin/chau7-proxy .
fi
cd "$ROOT_DIR"
info "Go proxy built (trimpath + stripped)"

# ── 1b. Go remote agent (bundled into app resources) ──
info "Building remote agent..."
REMOTE_AGENT_OUT="$ROOT_DIR/build/remote-agent/chau7-remote"
REMOTE_AGENT_ARGS=(--output "$REMOTE_AGENT_OUT" --trimpath --strip)
if $UNIVERSAL; then
    REMOTE_AGENT_ARGS+=(--universal)
fi
bash "$ROOT_DIR/Scripts/build-remote-agent.sh" "${REMOTE_AGENT_ARGS[@]}"
info "Remote agent built"

# ── 2. Rust libraries and helper binaries ──
# --remap-path-prefix replaces the home dir in panic/file!() strings
# that survive strip (they live in .rodata, not debug sections).
info "Building Rust components..."
export RUSTFLAGS="--remap-path-prefix=$HOME=~ ${RUSTFLAGS:-}"
RUST_FLAGS="--release"
if $UNIVERSAL; then
    RUST_FLAGS="--release --universal"
fi
"$ROOT_DIR/Scripts/build-rust.sh" $RUST_FLAGS
unset RUSTFLAGS
info "Rust components built"

# ── 3. Swift main binary ──
info "Building Swift ($APP_NAME)..."
# -file-prefix-map remaps both DWARF and #filePath literals (Swift 5.8+)
swift build -c release --package-path "$ROOT_DIR" \
    -Xswiftc -file-prefix-map -Xswiftc "$HOME"=~
info "Swift build complete"

# ── 4. Assemble app bundle ──
info "Assembling app bundle..."
CHAU7_LOG_SUPPRESS_HEADER=1 BUNDLE_IDENTIFIER="com.chau7.app" \
    "$ROOT_DIR/Scripts/build-app.sh" "$BUILD_DIR" "$DIST_DIR"

if [[ -f "$REMOTE_AGENT_OUT" ]]; then
    cp "$REMOTE_AGENT_OUT" "$APP_DIR/Contents/Resources/chau7-remote"
    chmod 755 "$APP_DIR/Contents/Resources/chau7-remote"
    info "Bundled remote agent"
else
    error "Remote agent missing at $REMOTE_AGENT_OUT"
fi

# ── 5. Strip debug symbols from all binaries ──
info "Stripping debug symbols..."
BINARIES=(
    "$APP_DIR/Contents/MacOS/$APP_NAME"
    "$APP_DIR/Contents/Resources/chau7-remote"
    "$APP_DIR/Contents/Resources/chau7-proxy"
    "$APP_DIR/Contents/Resources/libchau7_terminal.dylib"
    "$APP_DIR/Contents/Resources/libchau7_parse.dylib"
    "$APP_DIR/Contents/Resources/chau7-optim"
    "$APP_DIR/Contents/Resources/chau7-md"
    "$APP_DIR/Contents/Resources/chau7-mcp-bridge"
)

# Also strip the stale proxy copy inside the SPM bundle if it exists
SPM_PROXY="$APP_DIR/Contents/Resources/Chau7_Chau7.bundle/chau7-proxy"
if [[ -f "$SPM_PROXY" ]]; then
    BINARIES+=("$SPM_PROXY")
fi

for bin in "${BINARIES[@]}"; do
    if [[ -f "$bin" ]]; then
        strip -x "$bin" 2>/dev/null || strip "$bin" 2>/dev/null || warn "Could not strip $bin"
    fi
done
info "All binaries stripped"

# ── 6. Verify no personal paths remain ──
info "Checking for personal data leaks..."
LEAKS=$(strings "$APP_DIR/Contents/MacOS/$APP_NAME" \
             "$APP_DIR/Contents/Resources/chau7-proxy" \
             "$APP_DIR/Contents/Resources/chau7-remote" \
             "$APP_DIR/Contents/Resources/chau7-optim" \
             "$APP_DIR/Contents/Resources/chau7-md" \
             "$APP_DIR/Contents/Resources/libchau7_terminal.dylib" \
             "$APP_DIR/Contents/Resources/libchau7_parse.dylib" \
       2>/dev/null | grep -ci "/Users/" || true)

if [[ "$LEAKS" -gt 0 ]]; then
    warn "$LEAKS strings still reference /Users/ (mostly harmless Swift reflection metadata)"
else
    info "No personal path leaks detected"
fi

# ── 7. Ad-hoc codesign ──
info "Code signing..."
codesign --force --sign - --deep "$APP_DIR"
info "Ad-hoc signed"

# ── 8. Create DMG with drag-to-install layout ──
info "Preparing DMG contents..."
DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy the app
cp -R "$APP_DIR" "$DMG_STAGING/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

# Add a simple install/readme file for pre-notarization builds.
cat > "$DMG_STAGING/README - Install Chau7.txt" << 'README'
Chau7 Pre-Release

Install:
1. Drag Chau7.app to Applications.
2. Open Chau7 from Applications.

Because this build is not notarized yet, macOS may warn that the app is from an unidentified developer.
If that happens:
1. In Finder, open Applications.
2. Control-click Chau7.app.
3. Choose Open.
4. Confirm Open in the dialog.

Notes:
- This is a pre-release package for testing before Apple Developer signing/notarization is configured.
- Third-party notices are bundled inside Chau7.app at:
  Contents/Resources/Legal/
README

# Surface legal notices next to the app as well.
DMG_LEGAL_DIR="$DMG_STAGING/Legal Notices"
mkdir -p "$DMG_LEGAL_DIR"
if [[ -d "$APP_DIR/Contents/Resources/Legal" ]]; then
    cp -R "$APP_DIR/Contents/Resources/Legal/." "$DMG_LEGAL_DIR/"
fi

info "Creating DMG..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDBZ \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
info "Distribution ready: $DMG_PATH ($DMG_SIZE)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  $APP_NAME.dmg is ready to share!"
echo ""
echo "  This is a pre-release DMG for testing."
echo "  Install by dragging Chau7.app to Applications."
echo "  If Gatekeeper blocks first launch, use Finder: Control-click -> Open."
echo ""
if ! $UNIVERSAL; then
    echo "  ⚠ arm64 only (Apple Silicon)."
    echo "    Run with --universal for Intel+ARM support."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
