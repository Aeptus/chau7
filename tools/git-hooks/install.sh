#!/bin/zsh
# shellcheck shell=bash
# Install repo-managed git hooks into tools/git-hooks/ via Lefthook.
# Run once after cloning: ./tools/git-hooks/install.sh

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/tools/git-hooks"

if ! command -v lefthook >/dev/null 2>&1; then
    echo "ERROR: lefthook is required. Install it first, for example: brew install lefthook" >&2
    exit 1
fi

# Drop any stale, non-lefthook pre-push hook left behind by earlier setups.
stale_hook="$REPO_ROOT/.git/hooks/pre-push"
if [[ -f "$stale_hook" ]] && ! grep -q 'call_lefthook' "$stale_hook"; then
    echo "Removing stale non-lefthook pre-push hook at $stale_hook"
    rm -f "$stale_hook"
fi

git config core.hooksPath tools/git-hooks
lefthook install -f

echo "✓ Git hooks installed (core.hooksPath → tools/git-hooks/)"
echo "  Active hooks:"
for hook in "$HOOKS_DIR"/pre-*; do
    [ -x "$hook" ] && echo "    • $(basename "$hook")"
done
