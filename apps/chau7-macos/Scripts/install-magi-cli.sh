#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_MODE="${BUILD_MODE:-debug}"
INSTALL_DIR="${MAGI_INSTALL_DIR:-$HOME/.local/bin}"
PRODUCT_BIN="$ROOT_DIR/.build/$BUILD_MODE/magi"

if ! command -v swift >/dev/null 2>&1; then
  echo "swift not found in PATH. Install Xcode or the Swift toolchain." >&2
  exit 1
fi

echo "Building MAGI CLI ($BUILD_MODE)..."
swift build -c "$BUILD_MODE" --product magi --package-path "$ROOT_DIR"

if [[ ! -f "$PRODUCT_BIN" ]]; then
  echo "Built MAGI binary not found at $PRODUCT_BIN" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

rm -f "$INSTALL_DIR/magi"
install -m 0755 "$PRODUCT_BIN" "$INSTALL_DIR/magi"

CASE_PROBE_LOWER="$INSTALL_DIR/.magi-case-probe-$$"
CASE_PROBE_UPPER="$INSTALL_DIR/.MAGI-CASE-PROBE-$$"
touch "$CASE_PROBE_LOWER"
CASE_INSENSITIVE=0
if [[ -e "$CASE_PROBE_UPPER" ]]; then
  CASE_INSENSITIVE=1
fi
rm -f "$CASE_PROBE_LOWER" "$CASE_PROBE_UPPER"

if [[ "$CASE_INSENSITIVE" == "0" ]]; then
  rm -f "$INSTALL_DIR/MAGI"
  ln -sf "magi" "$INSTALL_DIR/MAGI"
fi

echo "Installed:"
echo "  $INSTALL_DIR/magi"
if [[ "$CASE_INSENSITIVE" == "1" ]]; then
  echo "  MAGI resolves through the case-insensitive filesystem"
else
  echo "  $INSTALL_DIR/MAGI"
fi

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    "$INSTALL_DIR/magi" --version
    ;;
  *)
    echo
    echo "Warning: $INSTALL_DIR is not on PATH for this shell."
    echo "Add this to your shell rc file:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac
