#!/bin/sh
# Type-check the macOS code from Linux (no Mac, no Apple SDK needed):
# `cargo clippy --target aarch64-apple-darwin` with a fake C compiler, since
# check builds never link. Catches compile errors and warnings in platform/,
# not runtime behavior. Usage: scripts/dev/mac-typecheck.sh [extra clippy args]
set -e
here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../.."
rustup target add aarch64-apple-darwin >/dev/null
export CC_aarch64_apple_darwin="$here/fake-cc.sh" CXX_aarch64_apple_darwin="$here/fake-cc.sh" AR_aarch64_apple_darwin=ar
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$HOME/chau7-next-targets/maccheck}"
# gpui-pre-apple includes a stitched shader file that its build script only
# writes on macOS; an empty one is enough to type-check.
cargo clippy --target aarch64-apple-darwin -p gpui-pre-apple >/dev/null 2>&1 || true
for d in "$CARGO_TARGET_DIR"/aarch64-apple-darwin/debug/build/gpui-pre-apple-*/; do
  mkdir -p "$d/out" && touch "$d/out/stitched_shaders.metal"
done
cargo clippy --target aarch64-apple-darwin --workspace --all-targets "$@" -- -D warnings
