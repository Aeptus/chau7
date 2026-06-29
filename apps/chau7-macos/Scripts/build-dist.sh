#!/usr/bin/env bash
set -euo pipefail

# build-dist.sh — Build a shareable pre-release Chau7 DMG for testing.
#
# This script:
#   1. Rebuilds Go proxy with -trimpath (strips build-machine paths)
#   2. Rebuilds Rust libs/binaries in release mode
#   3. Rebuilds Swift in release mode
#   4. Assembles app bundle
#   5. Strips debug symbols from all binaries
#   6. Signs with Developer ID when available (ad-hoc fallback)
#   7. Creates a styled drag-to-install DMG
#   8. Optionally notarizes/staples the DMG
#
# Usage:
#   ./Scripts/build-dist.sh                   # Apple Silicon only (default)
#   ./Scripts/build-dist.sh --universal       # arm64 + x86_64 helpers (larger)

APP_NAME="Chau7"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Distribution builds must carry a real version: derive from the latest tag
# when CHAU7_VERSION isn't set, and fail loudly when neither is available —
# a hardcoded "1.0" default silently shipped before.
if [[ -z "${CHAU7_VERSION:-}" ]]; then
    DERIVED_VERSION="$(git -C "$ROOT_DIR" describe --tags --abbrev=0 2>/dev/null | sed -E 's/^v//' || true)"
    if [[ -z "$DERIVED_VERSION" ]]; then
        echo "ERROR: CHAU7_VERSION is not set and no git tag is reachable to derive it from." >&2
        echo "       Set CHAU7_VERSION=x.y.z or create a vx.y.z tag before building a distribution." >&2
        exit 1
    fi
    export CHAU7_VERSION="$DERIVED_VERSION"
    echo "==> Version derived from latest tag: $CHAU7_VERSION"
fi

DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/.build/release"
APP_DIR="$DIST_DIR/$APP_NAME.app"
UNIVERSAL=false
BUILD_PKG=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --universal) UNIVERSAL=true; shift ;;
        --pkg) BUILD_PKG=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if $UNIVERSAL; then
    DMG_BASENAME="$APP_NAME-Universal"
else
    DMG_BASENAME="$APP_NAME-AppleSilicon"
fi

DMG_PATH="$DIST_DIR/$DMG_BASENAME.dmg"
TEMP_DMG_PATH="$DIST_DIR/$DMG_BASENAME-temp.dmg"
PKG_PATH="$DIST_DIR/$DMG_BASENAME.pkg"

info()  { echo -e "\033[0;32m[DIST]\033[0m $1"; }
warn()  { echo -e "\033[1;33m[DIST]\033[0m $1"; }
error() { echo -e "\033[0;31m[DIST]\033[0m $1"; exit 1; }

# shellcheck source=apps/chau7-macos/Scripts/signing.sh
source "$ROOT_DIR/Scripts/signing.sh"

DIST_CODESIGN_IDENTITY="$(chau7_resolve_codesign_identity release)"
DIST_CODESIGN_KIND="$(chau7_codesign_identity_kind "$DIST_CODESIGN_IDENTITY")"
info "Codesign identity: $DIST_CODESIGN_IDENTITY ($DIST_CODESIGN_KIND)"

if [[ "${CHAU7_NOTARIZE:-0}" == "1" && "$DIST_CODESIGN_KIND" != "developer-id" ]]; then
    error "CHAU7_NOTARIZE=1 requires a Developer ID Application identity."
fi

cleanup_dmg_mount() {
    local mount_point="${1:-}"
    if [[ -n "$mount_point" ]] && mount | grep -Fq "on $mount_point "; then
        hdiutil detach "$mount_point" >/dev/null 2>&1 || true
    fi
}

apply_dmg_layout() {
    local mount_point="$1"
    local background_path="$mount_point/.background/background.jpg"

    mkdir -p "$mount_point/.background"
    swift "$ROOT_DIR/Scripts/make-dmg-background.swift" \
        "$background_path" \
        "$ROOT_DIR/Resources/AppDockIcon.png"

    chflags hidden "$mount_point/.background" >/dev/null 2>&1 || true

    if ! command -v osascript >/dev/null 2>&1; then
        warn "osascript not available; skipping custom Finder window layout"
        return 0
    fi

    osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "$APP_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {120, 120, 840, 580}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 128
        set text size of opts to 14
        set background picture of opts to file ".background:background.jpg"

        set position of item "$APP_NAME.app" of container window to {178, 232}
        set position of item "Applications" of container window to {542, 232}

        close
        open
        update without registering applications
        delay 2
    end tell
end tell
APPLESCRIPT
}

mkdir -p "$DIST_DIR"
# Clean only this variant's artifacts (not other variants' DMGs/ZIPs)
rm -f "$DMG_PATH" "$DIST_DIR/$DMG_BASENAME.zip"
rm -rf "$DIST_DIR/dmg-staging"

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
    GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o build/darwin/chau7-proxy-arm64 .
    cp build/darwin/chau7-proxy-arm64 build/darwin/chau7-proxy
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
RUST_FLAGS=(--release)
if $UNIVERSAL; then
    RUST_FLAGS=(--release --universal)
fi
"$ROOT_DIR/Scripts/build-rust.sh" "${RUST_FLAGS[@]}"
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
    CHAU7_CODESIGN_PURPOSE="release" CHAU7_SKIP_CODESIGN=1 \
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

# ── 7. Code sign ──
info "Code signing app bundle..."
chau7_codesign_app "$APP_DIR" "com.chau7.app" "release"

# ── 8 (alt). Build a signed/notarized .pkg installer instead of a DMG ──
if $BUILD_PKG; then
    info "Building installer package..."
    rm -f "$PKG_PATH"

    # .pkg requires a "Developer ID Installer" identity (distinct from the
    # "Developer ID Application" identity used for the app/DMG).
    INSTALLER_IDENTITY="${CHAU7_INSTALLER_IDENTITY:-$(security find-identity -v 2>/dev/null | grep -m1 'Developer ID Installer' | sed -E 's/.*"(.*)"/\1/')}"

    if [[ -n "$INSTALLER_IDENTITY" ]]; then
        info "Signing installer with: $INSTALLER_IDENTITY"
        productbuild --component "$APP_DIR" /Applications --sign "$INSTALLER_IDENTITY" "$PKG_PATH"
    else
        warn "No 'Developer ID Installer' identity found — building UNSIGNED pkg (won't notarize)."
        productbuild --component "$APP_DIR" /Applications "$PKG_PATH"
    fi

    if [[ "${CHAU7_NOTARIZE:-0}" == "1" ]]; then
        info "Notarizing pkg..."
        chau7_notarize_artifact "$PKG_PATH"
    fi

    PKG_SIZE=$(du -sh "$PKG_PATH" | cut -f1)
    info "Installer package ready: $PKG_PATH ($PKG_SIZE)"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  $DMG_BASENAME.pkg ($PKG_SIZE) ready."
    if [[ -n "$INSTALLER_IDENTITY" && "${CHAU7_NOTARIZE:-0}" == "1" ]]; then
        echo "  Signed with Developer ID Installer and notarized."
    elif [[ -n "$INSTALLER_IDENTITY" ]]; then
        echo "  Signed with $INSTALLER_IDENTITY. Not notarized (set CHAU7_NOTARIZE=1 + CHAU7_NOTARY_PROFILE)."
    else
        echo "  UNSIGNED. Gatekeeper will block install."
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

# ── 8. Create DMG with drag-to-install layout ──
info "Preparing DMG contents..."
DMG_STAGING="$DIST_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"

# Copy the app
cp -R "$APP_DIR" "$DMG_STAGING/"

# Create Applications symlink for drag-to-install
ln -s /Applications "$DMG_STAGING/Applications"

info "Creating styled DMG..."
rm -f "$DMG_PATH"
rm -f "$TEMP_DMG_PATH"

DMG_SIZE_MB=$(( $(du -sm "$DMG_STAGING" | awk '{print $1}') + 80 ))
hdiutil create \
    -fs APFS \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDRW \
    -size "${DMG_SIZE_MB}m" \
    "$TEMP_DMG_PATH"

MOUNT_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG_PATH")"
MOUNT_POINT="$(echo "$MOUNT_OUTPUT" | awk '/\/Volumes\// { sub(/^.*\/Volumes\//, "/Volumes/"); print; exit }')"

if [[ -z "$MOUNT_POINT" ]]; then
    rm -rf "$DMG_STAGING"
    error "Could not determine DMG mount point"
fi

trap 'cleanup_dmg_mount "$MOUNT_POINT"' EXIT

if ! apply_dmg_layout "$MOUNT_POINT"; then
    warn "Could not apply custom Finder layout; continuing with default layout"
fi

bless --folder "$MOUNT_POINT" --openfolder "$MOUNT_POINT" >/dev/null 2>&1 || true
sync
sleep 2
hdiutil detach "$MOUNT_POINT"
trap - EXIT

hdiutil convert "$TEMP_DMG_PATH" \
    -ov \
    -format UDBZ \
    -o "$DMG_PATH" >/dev/null

rm -f "$TEMP_DMG_PATH"

rm -rf "$DMG_STAGING"

if [[ "$DIST_CODESIGN_KIND" != "adhoc" ]]; then
    info "Code signing DMG..."
    chau7_codesign_artifact "$DMG_PATH" "release"
fi

if [[ "${CHAU7_NOTARIZE:-0}" == "1" ]]; then
    info "Notarizing DMG..."
    chau7_notarize_artifact "$DMG_PATH"
fi

DMG_SIZE=$(du -sh "$DMG_PATH" | cut -f1)
info "Distribution ready: $DMG_PATH ($DMG_SIZE)"

# ── 9. Create ZIP archive ──
# Uses ditto (not zip) to preserve macOS extended attributes and code signatures
ZIP_PATH="$DIST_DIR/$DMG_BASENAME.zip"
info "Creating ZIP archive..."
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
ZIP_SIZE=$(du -sh "$ZIP_PATH" | cut -f1)
info "ZIP archive ready: $ZIP_PATH ($ZIP_SIZE)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  $DMG_BASENAME.dmg ($DMG_SIZE) + .zip ($ZIP_SIZE) ready to share!"
echo ""
echo "  DMG: Drag Chau7.app to Applications."
echo "  ZIP: Extract and move to Applications."
if [[ "$DIST_CODESIGN_KIND" == "developer-id" && "${CHAU7_NOTARIZE:-0}" == "1" ]]; then
    echo "  Signed with Developer ID and notarized."
elif [[ "$DIST_CODESIGN_KIND" == "adhoc" ]]; then
    echo "  Ad-hoc signed fallback. Gatekeeper may require Finder: Control-click -> Open."
else
    echo "  Signed with $DIST_CODESIGN_IDENTITY. Not notarized."
fi
echo ""
if ! $UNIVERSAL; then
    echo "  Apple Silicon only (arm64)."
else
    echo "  Universal helper payload enabled."
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
