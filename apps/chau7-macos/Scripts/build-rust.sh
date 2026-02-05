#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT_DIR/rust/chau7_parse"
TARGET_DIR="$CRATE_DIR/target/release"
OUT_LIB="libchau7_parse.dylib"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found in PATH" >&2
  exit 1
fi

cargo build --release --manifest-path "$CRATE_DIR/Cargo.toml"

if [[ ! -f "$TARGET_DIR/$OUT_LIB" ]]; then
  echo "Rust build succeeded but $OUT_LIB not found" >&2
  exit 1
fi

echo "$TARGET_DIR/$OUT_LIB"
