#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/../../services/chau7-remote"
OUTPUT_PATH="$ROOT_DIR/build/remote-agent/chau7-remote"
UNIVERSAL=0
TRIMPATH=0
STRIP_DEBUG=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --universal)
      UNIVERSAL=1
      shift
      ;;
    --trimpath)
      TRIMPATH=1
      shift
      ;;
    --strip)
      STRIP_DEBUG=1
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$SOURCE_DIR/go.mod" ]]; then
  echo "Go module not found at $SOURCE_DIR" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUTPUT_PATH")"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/chau7-remote-build.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_OUTPUT="$TMP_DIR/chau7-remote"

GO_BUILD_ARGS=(build -o "$TMP_OUTPUT")
if [[ "$TRIMPATH" == "1" ]]; then
  GO_BUILD_ARGS+=( -trimpath )
fi
if [[ "$STRIP_DEBUG" == "1" ]]; then
  GO_BUILD_ARGS+=( -ldflags "-s -w" )
fi
GO_BUILD_ARGS+=( ./cmd/chau7-remote )

if [[ "$UNIVERSAL" == "1" ]]; then
  ARM64_OUT="$TMP_DIR/chau7-remote-arm64"
  AMD64_OUT="$TMP_DIR/chau7-remote-amd64"

  GOOS=darwin GOARCH=arm64 go -C "$SOURCE_DIR" "${GO_BUILD_ARGS[@]/$TMP_OUTPUT/$ARM64_OUT}"
  GOOS=darwin GOARCH=amd64 go -C "$SOURCE_DIR" "${GO_BUILD_ARGS[@]/$TMP_OUTPUT/$AMD64_OUT}"
  lipo -create -output "$TMP_OUTPUT" "$ARM64_OUT" "$AMD64_OUT"
else
  go -C "$SOURCE_DIR" "${GO_BUILD_ARGS[@]}"
fi

cp "$TMP_OUTPUT" "$OUTPUT_PATH"
chmod +x "$OUTPUT_PATH"
echo "Built chau7-remote -> $OUTPUT_PATH"
