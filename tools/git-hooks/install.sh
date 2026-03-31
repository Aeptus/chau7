#!/bin/zsh
# Install repo-managed git hooks into tools/git-hooks/ via Lefthook.
# Run once after cloning: ./tools/git-hooks/install.sh

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/tools/git-hooks"

if ! command -v lefthook >/dev/null 2>&1; then
    echo "ERROR: lefthook is required. Install it first, for example: brew install lefthook" >&2
    exit 1
fi

git config core.hooksPath tools/git-hooks
lefthook install -f

echo "✓ Git hooks installed (core.hooksPath → tools/git-hooks/)"
echo "  Active hooks:"
for hook in "$HOOKS_DIR"/pre-*; do
    [ -x "$hook" ] && echo "    • $(basename "$hook")"
done
