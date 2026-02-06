#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUST_DIR="$ROOT_DIR/rust"
LIBS_DIR="$ROOT_DIR/Libraries"

# Crate configurations
CRATES=("chau7_parse" "chau7_terminal")
DYLIBS=("libchau7_parse.dylib" "libchau7_terminal.dylib")

# Parse arguments
BUILD_MODE="release"
UNIVERSAL_BUILD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            BUILD_MODE="debug"
            shift
            ;;
        --release)
            BUILD_MODE="release"
            shift
            ;;
        --universal)
            UNIVERSAL_BUILD=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--debug|--release] [--universal]" >&2
            exit 1
            ;;
    esac
done

# Set cargo build flags
CARGO_FLAGS=""
if [[ "$BUILD_MODE" == "release" ]]; then
    CARGO_FLAGS="--release"
fi

# Check for cargo
if ! command -v cargo >/dev/null 2>&1; then
    echo "cargo not found in PATH" >&2
    exit 1
fi

# Ensure Libraries directory exists
mkdir -p "$LIBS_DIR"

# Function to build for a specific target
build_for_target() {
    local target="$1"
    echo "Building for target: $target"

    if [[ -n "$target" ]]; then
        cargo build $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml" --target "$target"
    else
        cargo build $CARGO_FLAGS --manifest-path "$RUST_DIR/Cargo.toml"
    fi
}

# Function to get target directory based on build mode and target
get_target_dir() {
    local target="$1"
    if [[ -n "$target" ]]; then
        echo "$RUST_DIR/target/$target/$BUILD_MODE"
    else
        echo "$RUST_DIR/target/$BUILD_MODE"
    fi
}

# Build the workspace
if [[ "$UNIVERSAL_BUILD" == true ]]; then
    echo "Building universal binary (arm64 + x86_64)..."

    # Ensure targets are installed
    rustup target add aarch64-apple-darwin x86_64-apple-darwin 2>/dev/null || true

    # Build for both architectures
    build_for_target "aarch64-apple-darwin"
    build_for_target "x86_64-apple-darwin"

    ARM64_DIR=$(get_target_dir "aarch64-apple-darwin")
    X86_64_DIR=$(get_target_dir "x86_64-apple-darwin")

    # Create universal binaries using lipo
    for i in "${!CRATES[@]}"; do
        dylib="${DYLIBS[$i]}"
        crate="${CRATES[$i]}"

        ARM64_LIB="$ARM64_DIR/$dylib"
        X86_64_LIB="$X86_64_DIR/$dylib"
        UNIVERSAL_LIB="$LIBS_DIR/$dylib"

        if [[ -f "$ARM64_LIB" && -f "$X86_64_LIB" ]]; then
            echo "Creating universal binary for $crate..."
            lipo -create "$ARM64_LIB" "$X86_64_LIB" -output "$UNIVERSAL_LIB"
            echo "Created: $UNIVERSAL_LIB"
        else
            echo "Warning: Could not create universal binary for $crate" >&2
            echo "  ARM64: $ARM64_LIB (exists: $(test -f "$ARM64_LIB" && echo yes || echo no))" >&2
            echo "  x86_64: $X86_64_LIB (exists: $(test -f "$X86_64_LIB" && echo yes || echo no))" >&2
        fi
    done
else
    echo "Building for native architecture..."
    build_for_target ""

    TARGET_DIR=$(get_target_dir "")

    # Copy dylibs to Libraries directory
    for i in "${!CRATES[@]}"; do
        dylib="${DYLIBS[$i]}"
        crate="${CRATES[$i]}"

        SRC_LIB="$TARGET_DIR/$dylib"
        DEST_LIB="$LIBS_DIR/$dylib"

        if [[ -f "$SRC_LIB" ]]; then
            cp "$SRC_LIB" "$DEST_LIB"
            echo "Copied: $DEST_LIB"
        else
            echo "Warning: $dylib not found for $crate at $SRC_LIB" >&2
        fi
    done
fi

# Verify all expected libraries exist
echo ""
echo "Build complete. Libraries in $LIBS_DIR:"
for dylib in "${DYLIBS[@]}"; do
    lib_path="$LIBS_DIR/$dylib"
    if [[ -f "$lib_path" ]]; then
        echo "  [OK] $dylib"
        if [[ "$UNIVERSAL_BUILD" == true ]]; then
            lipo -info "$lib_path" 2>/dev/null || true
        fi
    else
        echo "  [MISSING] $dylib"
    fi
done
