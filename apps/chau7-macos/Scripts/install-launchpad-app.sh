#!/usr/bin/env bash

# Compatibility entry point retained for existing local documentation and
# automation. The old installer used ditto directly on /Applications, which
# could leave files from an older bundle behind and refused to stop a running
# app without offering a safe next step. Keep one implementation of the
# guarded build/quit/atomic-install workflow instead.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${OPEN_AFTER_INSTALL:-0}" == "1" ]]; then
  exec "$ROOT_DIR/Scripts/rebuild-and-relaunch.sh" "$@"
fi
exec "$ROOT_DIR/Scripts/rebuild-and-relaunch.sh" --no-launch "$@"
