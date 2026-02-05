#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Chau7"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${1:-$ROOT_DIR/.build/release}"
OUT_DIR="${2:-$ROOT_DIR/build}"
SHOW_DOCK_ICON="${SHOW_DOCK_ICON:-1}"

export CHAU7_LOG_ROOT="$ROOT_DIR"
CHAU7_LOG_NAME="build-app"
export CHAU7_LOG_NAME

source "$ROOT_DIR/Scripts/logging.sh"

BIN="$BUILD_DIR/$APP_NAME"
APP_DIR="$OUT_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

if [[ "${CHAU7_LOG_SUPPRESS_HEADER:-0}" != "1" ]]; then
  log_init "Build App Bundle"
  log_info "Build dir: $BUILD_DIR"
  log_info "Output dir: $OUT_DIR"
  log_info "Show dock icon: $SHOW_DOCK_ICON"
fi

finish() {
  local code=$?
  log_finish "$code"
}

trap finish EXIT

if [[ ! -f "$BIN" ]]; then
  log_error "Binary not found at $BIN"
  log_error "Run: swift build -c release --package-path \"$ROOT_DIR\""
  exit 1
fi

run_cmd mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

LSUI_ELEMENT_VALUE="<true/>"
if [[ "$SHOW_DOCK_ICON" == "1" ]]; then
  LSUI_ELEMENT_VALUE="<false/>"
fi

cat <<PLIST > "$CONTENTS/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Chau7</string>
  <key>CFBundleIdentifier</key>
  <string>com.chau7.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Chau7</string>
  <key>CFBundleIconFile</key>
  <string>AppDockIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSUIElement</key>
  $LSUI_ELEMENT_VALUE
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Local build</string>
</dict>
</plist>
PLIST

run_cmd cp "$BIN" "$CONTENTS/MacOS/$APP_NAME"

if [[ -f "$ROOT_DIR/Resources/AppDockIcon.png" ]]; then
  run_cmd cp "$ROOT_DIR/Resources/AppDockIcon.png" "$CONTENTS/Resources/AppDockIcon.png"
fi

RESOURCE_BUNDLE=""
if [[ -d "$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle" ]]; then
  RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
elif [[ -d "$BUILD_DIR/${APP_NAME}.bundle" ]]; then
  RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}.bundle"
else
  RESOURCE_BUNDLE="$(find "$BUILD_DIR" -maxdepth 1 -type d -name "${APP_NAME}_*.bundle" -print -quit || true)"
fi

if [[ -n "$RESOURCE_BUNDLE" ]]; then
  run_cmd cp -R "$RESOURCE_BUNDLE" "$CONTENTS/Resources/"
  log_ok "Copied resource bundle: $(basename "$RESOURCE_BUNDLE")"
else
  log_warn "Resource bundle not found in $BUILD_DIR (falling back to raw Resources/ copy)."
  if [[ -d "$ROOT_DIR/Resources" ]]; then
    run_cmd cp -R "$ROOT_DIR/Resources/"* "$CONTENTS/Resources/"
    log_ok "Copied raw resources from Resources/ into app bundle."
  else
    log_warn "Resources directory not found at $ROOT_DIR/Resources."
  fi
fi

RUST_LIB_PATH="${CHAU7_RUST_LIB_PATH:-$ROOT_DIR/rust/chau7_parse/target/release/libchau7_parse.dylib}"
if [[ -f "$RUST_LIB_PATH" ]]; then
  run_cmd cp "$RUST_LIB_PATH" "$CONTENTS/Resources/libchau7_parse.dylib"
  log_ok "Copied Rust parser library: $(basename "$RUST_LIB_PATH")"
else
  log_warn "Rust parser library not found at $RUST_LIB_PATH (optional)."
fi

log_ok "Built app bundle at $APP_DIR"
