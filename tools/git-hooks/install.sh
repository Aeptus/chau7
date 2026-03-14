#!/bin/zsh
# Install git hooks from tools/git-hooks/ into the repo.
# Run once after cloning: ./tools/git-hooks/install.sh
#
# This sets core.hooksPath so git looks in tools/git-hooks/ directly —
# no symlinks needed, and new hooks are picked up automatically.

set -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/tools/git-hooks"

chmod +x "$HOOKS_DIR"/pre-commit "$HOOKS_DIR"/pre-push

git config core.hooksPath tools/git-hooks

echo "✓ Git hooks installed (core.hooksPath → tools/git-hooks/)"
echo "  Active hooks:"
for hook in "$HOOKS_DIR"/pre-*; do
    [ -x "$hook" ] && echo "    • $(basename "$hook")"
done
