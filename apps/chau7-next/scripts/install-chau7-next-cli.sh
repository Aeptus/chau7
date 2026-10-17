#!/usr/bin/env bash
# Install standalone Next commands and skills without replacing Swift helpers.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE_MODE=0
ROOT=""
BUNDLE_PRODUCT=""
BUNDLE_SKILLS=""
if [ "$(basename "$SCRIPT_DIR")" = "Resources" ] \
  && [ "$(basename "$(dirname "$SCRIPT_DIR")")" = "Contents" ]; then
  # A shipped Resources copy is self-contained: use the app's sibling CLI and
  # bundled skills, and never try to build from the app bundle.
  BUNDLE_MODE=1
  BUNDLE_PRODUCT="$(dirname "$SCRIPT_DIR")/MacOS/chau7-next-cli"
  BUNDLE_SKILLS="$SCRIPT_DIR/Skills"
  if [ "${CHAU7_NEXT_CLI_SKIP_BUILD:-1}" != "1" ]; then
    echo "error: the app-bundle installer cannot build; use the checkout installer to build" >&2
    exit 1
  fi
  CHAU7_NEXT_CLI_SKIP_BUILD=1
  PRODUCT_BIN="${CHAU7_NEXT_CLI_PRODUCT_BIN:-$BUNDLE_PRODUCT}"
  SKILLS_SOURCE="${CHAU7_NEXT_CLI_SKILLS_SOURCE:-$BUNDLE_SKILLS}"
else
  ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  if [ -n "${CARGO_TARGET_DIR:-}" ]; then
    case "$CARGO_TARGET_DIR" in
      /*) ;;
      *) CARGO_TARGET_DIR="$ROOT/$CARGO_TARGET_DIR" ;;
    esac
    export CARGO_TARGET_DIR
  fi
  PRODUCT_BIN="${CHAU7_NEXT_CLI_PRODUCT_BIN:-}"
  SKILLS_SOURCE="${CHAU7_NEXT_CLI_SKILLS_SOURCE:-$ROOT/resources/skills}"
fi
INSTALL_DIR="${CHAU7_NEXT_CLI_INSTALL_DIR:-$HOME/.local/bin}"
CARGO_OUTPUT=""
binary_tmp=""
wrapper_tmp=""

cleanup() {
  [ -z "$CARGO_OUTPUT" ] || rm -f "$CARGO_OUTPUT"
  [ -z "$binary_tmp" ] || rm -f "$binary_tmp"
  [ -z "$wrapper_tmp" ] || rm -f "$wrapper_tmp"
}
trap cleanup EXIT

if [ "${CHAU7_NEXT_CLI_SKIP_BUILD:-0}" = "1" ]; then
  if [ "$BUNDLE_MODE" = "1" ]; then
    PRODUCT_BIN="${CHAU7_NEXT_CLI_PRODUCT_BIN:-$BUNDLE_PRODUCT}"
  else
    # Keep the existing checkout skip-build location behavior. Set
    # CHAU7_NEXT_CLI_PRODUCT_BIN to select a non-default/configured target.
    PRODUCT_BIN="${CHAU7_NEXT_CLI_PRODUCT_BIN:-${CARGO_TARGET_DIR:-$ROOT/target}/release/chau7-next-cli}"
  fi
else
  if [ -z "$PRODUCT_BIN" ] && ! command -v python3 >/dev/null 2>&1; then
    echo "error: python3 is required to read Cargo's executable artifact message" >&2
    exit 1
  fi
  CARGO_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/chau7-next-cli-cargo.XXXXXX")"
  (
    cd "$ROOT"
    # shellcheck source=apps/chau7-next/scripts/build-mode.sh
    source "$ROOT/scripts/build-mode.sh"
    run_cargo cargo build "${CARGO_BUILD_ARGS[@]}" --message-format=json-render-diagnostics \
      -p chau7_next_core --bin chau7-next-cli > "$CARGO_OUTPUT"
  )
  if [ -z "$PRODUCT_BIN" ]; then
    PRODUCT_BIN="$(python3 - "$CARGO_OUTPUT" "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import sys

artifact_stream = Path(sys.argv[1])
workspace_root = Path(sys.argv[2])
executables = set()
for line_number, line in enumerate(artifact_stream.read_text(errors="replace").splitlines(), 1):
    try:
        message = json.loads(line)
    except json.JSONDecodeError:
        # Cargo verbose mode or a wrapper may add human-readable lines to
        # stderr, which run_cargo merges into this stream when logging.
        continue
    if not isinstance(message, dict):
        continue
    if message.get("reason") != "compiler-artifact":
        continue
    target = message.get("target") or {}
    if target.get("name") != "chau7-next-cli" or "bin" not in target.get("kind", []):
        continue
    executable = message.get("executable")
    if executable:
        path = Path(executable)
        if not path.is_absolute():
            path = workspace_root / path
        executables.add(path.resolve())

if len(executables) != 1:
    raise SystemExit(
        f"error: Cargo reported {len(executables)} executable artifacts for chau7-next-cli; "
        "cannot safely choose an install binary"
    )
product = executables.pop()
if not product.is_file() or not os.access(product, os.X_OK):
    raise SystemExit(f"error: Cargo artifact is missing or not executable: {product}")
print(product)
PY
    )"
  fi
  rm -f "$CARGO_OUTPUT"
  CARGO_OUTPUT=""
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
echo "Installing CLI binary from: $PRODUCT_BIN"
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
