#!/usr/bin/env bash
set -euo pipefail

# Install an idempotent zsh startup block that keeps Codex's npm-managed Volta
# image bin ahead of the generic ~/.volta/bin shim. Without this, Terminal.app
# can keep launching an older Volta package image even after Codex's own update
# prompt updates the npm global package under the active Node image.

BEGIN_MARKER="# >>> Chau7 Codex Volta PATH fix >>>"
END_MARKER="# <<< Chau7 Codex Volta PATH fix <<<"
TARGET_RC="${1:-${CHAU7_CODEX_PATH_FIX_RC:-$HOME/.zshrc}}"

BLOCK=$(cat <<'BLOCK_EOF'
# >>> Chau7 Codex Volta PATH fix >>>
# Keep Codex's npm-managed Volta image bin ahead of ~/.volta/bin. The Volta
# shim can point at a stale package image, while Codex's update prompt updates
# the npm global package under the active Node image.
if [[ -n "${ZSH_VERSION:-}" && -d "$HOME/.volta/tools/image/node" ]]; then
  setopt local_options null_glob
  path=("${(s/:/)PATH}")

  for _chau7_codex_bin in "$HOME/.volta/tools/image/node/"*"/bin"(N); do
    [[ -x "$_chau7_codex_bin/codex" ]] && path=("$_chau7_codex_bin" $path)
  done

  if command -v volta >/dev/null 2>&1; then
    _chau7_node_path="$(volta which node 2>/dev/null || true)"
    _chau7_node_bin="${_chau7_node_path%/*}"
    if [[ -n "$_chau7_node_bin" && -x "$_chau7_node_bin/codex" ]]; then
      path=("$_chau7_node_bin" $path)
    fi
  fi

  typeset -U path
  export PATH="${(j/:/)path}"
  unset _chau7_codex_bin _chau7_node_path _chau7_node_bin
fi
# <<< Chau7 Codex Volta PATH fix <<<
BLOCK_EOF
)

mkdir -p "$(dirname "$TARGET_RC")"
touch "$TARGET_RC"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/chau7-codex-path.XXXXXX")"
trap 'rm -f "$tmp_file"' EXIT

awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
  $0 == begin { in_block = 1; next }
  $0 == end { in_block = 0; next }
  !in_block { print }
' "$TARGET_RC" > "$tmp_file"

{
  cat "$tmp_file"
  if [[ -s "$tmp_file" ]]; then
    printf '\n'
  fi
  printf '%s\n' "$BLOCK"
} > "$TARGET_RC"

printf 'Installed Chau7 Codex Volta PATH fix in %s\n' "$TARGET_RC"
