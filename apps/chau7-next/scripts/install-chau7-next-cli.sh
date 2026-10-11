#!/usr/bin/env bash
# Install standalone Next commands and skills without replacing Swift helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${CHAU7_NEXT_CLI_INSTALL_DIR:-$HOME/.local/bin}"
PRODUCT_BIN="${CHAU7_NEXT_CLI_PRODUCT_BIN:-${CARGO_TARGET_DIR:-$ROOT/target}/release/chau7-next-cli}"
SKILLS_SOURCE="${CHAU7_NEXT_CLI_SKILLS_SOURCE:-$ROOT/resources/skills}"
if [ "${CHAU7_NEXT_CLI_SKIP_BUILD:-0}" != "1" ]; then
  (cd "$ROOT" && cargo build --locked --release -p chau7_next_core --bin chau7-next-cli)
fi
if [ ! -x "$PRODUCT_BIN" ]; then
  echo "error: Next CLI executable missing: $PRODUCT_BIN" >&2
  exit 1
fi
if [ ! -d "$SKILLS_SOURCE" ]; then
  echo "error: Next skills source missing: $SKILLS_SOURCE" >&2
  exit 1
fi
mkdir -p "$INSTALL_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd)"
SKILLS_DEST="$INSTALL_DIR/../share/chau7-next/skills"
mkdir -p "$SKILLS_DEST"
for source in "$SKILLS_SOURCE"/*; do
  [ -d "$source" ] || continue
  name="$(basename "$source")"
  case "$name" in chau7-next-*) ;; *) echo "error: unexpected built-in skill: $name" >&2; exit 1 ;; esac
  # Only copy bundled Next sources; provider installations use the managed CLI.
  mkdir -p "$SKILLS_DEST/$name"
  cp -R "$source/." "$SKILLS_DEST/$name/"
done
binary_tmp="$(mktemp "$INSTALL_DIR/.chau7-next-cli.XXXXXX")"
wrapper_tmp="$(mktemp "$INSTALL_DIR/.chau7-next.XXXXXX")"
trap 'rm -f "$binary_tmp" "$wrapper_tmp"' EXIT
cp "$PRODUCT_BIN" "$binary_tmp"
chmod 755 "$binary_tmp"
cat > "$wrapper_tmp" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${CHAU7_NEXT_CLI_BIN:-$script_dir/chau7-next-cli}" "$@"
WRAPPER
chmod 755 "$wrapper_tmp"
mv -f "$binary_tmp" "$INSTALL_DIR/chau7-next-cli"
mv -f "$wrapper_tmp" "$INSTALL_DIR/chau7-next"
echo "Installed: $INSTALL_DIR/chau7-next"
case ":${PATH:-}:" in
  *":$INSTALL_DIR:"*) ;;
  *) echo "Add $INSTALL_DIR to PATH to use chau7-next." ;;
esac
