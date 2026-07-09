#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_MODE="${BUILD_MODE:-debug}"
INSTALL_DIR="${CHAU7_CLI_INSTALL_DIR:-$HOME/.local/bin}"
PRODUCT_BIN="${CHAU7_CLI_PRODUCT_BIN:-$ROOT_DIR/.build/$BUILD_MODE/chau7-cli}"
SKIP_BUILD="${CHAU7_CLI_SKIP_BUILD:-0}"

if [[ "$SKIP_BUILD" != "1" ]]; then
  if ! command -v swift >/dev/null 2>&1; then
    echo "swift not found in PATH. Install Xcode or the Swift toolchain." >&2
    exit 1
  fi

  echo "Building Chau7 CLI ($BUILD_MODE)..."
  swift build -c "$BUILD_MODE" --product chau7-cli --package-path "$ROOT_DIR"
fi

if [[ ! -f "$PRODUCT_BIN" ]]; then
  echo "Built Chau7 CLI binary not found at $PRODUCT_BIN" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"

rm -f "$INSTALL_DIR/chau7-cli"
install -m 0755 "$PRODUCT_BIN" "$INSTALL_DIR/chau7-cli"

rm -f "$INSTALL_DIR/chau7"
cat > "$INSTALL_DIR/chau7" <<WRAPPER
#!/usr/bin/env bash
set -euo pipefail
exec "\${CHAU7_CLI_BIN:-$INSTALL_DIR/chau7-cli}" "\$@"
WRAPPER
chmod 0755 "$INSTALL_DIR/chau7"

echo "Installed:"
echo "  $INSTALL_DIR/chau7-cli"
echo "  $INSTALL_DIR/chau7"

case ":$PATH:" in
  *":$INSTALL_DIR:"*)
    "$INSTALL_DIR/chau7" --version
    ;;
  *)
    echo
    echo "Warning: $INSTALL_DIR is not on PATH for this shell."
    echo "Add this to your shell rc file:"
    echo "  export PATH=\"$INSTALL_DIR:\$PATH\""
    ;;
esac
