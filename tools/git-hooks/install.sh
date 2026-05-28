#!/bin/sh
# Legacy entry point kept for old docs/scripts.
set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
pnpm hooks:install
