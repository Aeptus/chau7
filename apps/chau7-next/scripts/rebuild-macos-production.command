#!/bin/bash
# Rebuild the installed Rust production Chau7 app through its guarded updater.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
exec python3 "$SCRIPT_DIR/rebuild-macos-production.py" "$@"
