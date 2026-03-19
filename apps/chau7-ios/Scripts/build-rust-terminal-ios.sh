#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_APP_DIR="$(cd "$IOS_APP_DIR/../chau7-macos" && pwd)"
CRATE_MANIFEST="$MACOS_APP_DIR/rust/chau7_terminal/Cargo.toml"
RUST_TARGET_DIR="$IOS_APP_DIR/BuildArtifacts/rust/target"
PLATFORM_LIB_DIR="$IOS_APP_DIR/BuildArtifacts/rust/lib/${PLATFORM_NAME:-iphonesimulator}"

platform="${PLATFORM_NAME:-iphonesimulator}"
export PATH="$HOME/.cargo/bin:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}"

find_tool() {
    local tool_name="$1"
    local direct_path="${2:-}"
    if [[ -n "$direct_path" && -x "$direct_path" ]]; then
        printf '%s\n' "$direct_path"
        return 0
    fi
    if command -v "$tool_name" >/dev/null 2>&1; then
        command -v "$tool_name"
        return 0
    fi
    return 1
}

CARGO_BIN="$(find_tool cargo "$HOME/.cargo/bin/cargo")" || {
    echo "cargo not found. Install Rust and ensure cargo is available to Xcode build scripts." >&2
    echo "Expected locations checked: \$HOME/.cargo/bin/cargo, PATH=$PATH" >&2
    exit 1
}

RUSTUP_BIN="$(find_tool rustup "$HOME/.cargo/bin/rustup")" || {
    echo "rustup not found. Install Rustup so the build script can verify iOS targets." >&2
    echo "Expected locations checked: \$HOME/.cargo/bin/rustup, PATH=$PATH" >&2
    exit 1
}

mkdir -p "$PLATFORM_LIB_DIR"

build_mode="debug"
cargo_flags=()
if [[ "${CONFIGURATION:-Debug}" == "Release" ]]; then
    build_mode="release"
    cargo_flags+=(--release)
fi

export CARGO_TARGET_DIR="$RUST_TARGET_DIR"

require_target() {
    local target="$1"
    if ! "$RUSTUP_BIN" target list --installed | grep -qx "$target"; then
        echo "Missing Rust target $target. Install it with: rustup target add $target" >&2
        exit 1
    fi
}

build_target() {
    local target="$1"
    if [[ "${#cargo_flags[@]}" -gt 0 ]]; then
        "$CARGO_BIN" build \
            "${cargo_flags[@]}" \
            --manifest-path "$CRATE_MANIFEST" \
            --target "$target" \
            --lib
    else
        "$CARGO_BIN" build \
            --manifest-path "$CRATE_MANIFEST" \
            --target "$target" \
            --lib
    fi
}

case "$platform" in
    iphoneos)
        require_target "aarch64-apple-ios"
        build_target "aarch64-apple-ios"
        cp "$RUST_TARGET_DIR/aarch64-apple-ios/$build_mode/libchau7_terminal.a" \
           "$PLATFORM_LIB_DIR/libchau7_terminal.a"
        ;;
    iphonesimulator)
        simulator_targets=(
            "aarch64-apple-ios-sim"
            "x86_64-apple-ios"
        )
        for target in "${simulator_targets[@]}"; do
            require_target "$target"
            build_target "$target"
        done
        lipo -create \
            "$RUST_TARGET_DIR/aarch64-apple-ios-sim/$build_mode/libchau7_terminal.a" \
            "$RUST_TARGET_DIR/x86_64-apple-ios/$build_mode/libchau7_terminal.a" \
            -output "$PLATFORM_LIB_DIR/libchau7_terminal.a"
        ;;
    *)
        echo "Unsupported PLATFORM_NAME for Rust terminal build: $platform" >&2
        exit 1
        ;;
esac
