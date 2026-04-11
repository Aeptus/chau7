#!/usr/bin/env bash
set -euo pipefail

CI_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ci_repo_root() {
  printf '%s\n' "$CI_REPO_ROOT"
}

ci_note() {
  printf '%s\n' "$*"
}

ci_section() {
  printf '\n==> %s\n' "$1"
}

ci_fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ci_require_cmd() {
  local cmd="$1"
  # shellcheck disable=SC2016 # $cmd inside ${...:-...} default expands in outer double-quote context
  local hint="${2:-Install '$cmd' and try again.}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ci_fail "$cmd is required. $hint"
  fi
}

ci_swift_bin() {
  local swift_bin="/usr/bin/swift"
  if [[ ! -x "$swift_bin" ]]; then
    ci_fail "Expected Swift at $swift_bin. Install Xcode and try again."
  fi
  printf '%s\n' "$swift_bin"
}

ci_run_in() {
  local label="$1"
  local dir="$2"
  shift 2
  ci_section "$label"
  (
    cd "$CI_REPO_ROOT/$dir"
    "$@"
  )
}

ci_collect_staged_files() {
  if git -C "$CI_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$CI_REPO_ROOT" diff --cached --name-only --diff-filter=ACMR
  fi
}

ci_should_run_for_paths() {
  if [[ "${CI_FAST_ALL:-0}" == "1" ]]; then
    return 0
  fi

  if [[ -z "${CI_STAGED_FILES:-}" ]]; then
    return 0
  fi

  local path
  for path in "$@"; do
    if grep -Eq "^${path}" <<<"$CI_STAGED_FILES"; then
      return 0
    fi
  done

  return 1
}

ci_gofmt_check_dir() {
  local dir="$1"
  local label="$2"
  local find_bin="/usr/bin/find"
  local sort_bin="/usr/bin/sort"
  local gofmt_bin
  gofmt_bin="$(command -v gofmt)"

  if ! "$find_bin" "$CI_REPO_ROOT/$dir" -type f -name '*.go' -print -quit | grep -q .; then
    return 0
  fi

  ci_section "$label"
  local output
  output="$("$find_bin" "$CI_REPO_ROOT/$dir" -type f -name '*.go' -exec "$gofmt_bin" -l '{}' + | "$sort_bin")"
  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" >&2
    ci_fail "gofmt reported unformatted Go files in $dir"
  fi
}

ci_go_test_dir() {
  local dir="$1"
  local label="$2"
  ci_run_in "$label" "$dir" go test ./...
}

ci_go_vet_dir() {
  local dir="$1"
  local label="$2"
  ci_run_in "$label" "$dir" go vet ./...
}

ci_relay_ensure_deps() {
  local relay_dir="$CI_REPO_ROOT/services/chau7-relay"
  if [[ ! -d "$relay_dir/node_modules" || "$relay_dir/package-lock.json" -nt "$relay_dir/node_modules" ]]; then
    ci_run_in "Relay dependencies" "services/chau7-relay" npm ci --no-audit --no-fund
  fi
}

ci_golangci_lint_dir() {
  local dir="$1"
  local label="$2"
  if ! command -v golangci-lint >/dev/null 2>&1; then
    ci_fail "golangci-lint is required. Install with 'brew install golangci-lint'."
  fi
  ci_run_in "$label" "$dir" golangci-lint run ./...
}

ci_shellcheck_tracked() {
  local label="${1:-Shellcheck (full)}"
  if ! command -v shellcheck >/dev/null 2>&1; then
    ci_fail "shellcheck is required. Install with 'brew install shellcheck'."
  fi
  ci_section "$label"
  local files
  files="$(git -C "$CI_REPO_ROOT" ls-files '*.sh' '**/*.sh')"
  if [[ -z "$files" ]]; then
    return 0
  fi
  local list=()
  while IFS= read -r f; do
    list+=("$CI_REPO_ROOT/$f")
  done <<<"$files"
  shellcheck -x "${list[@]}"
}

ci_shellcheck_staged() {
  local label="${1:-Shellcheck (staged)}"
  if ! command -v shellcheck >/dev/null 2>&1; then
    ci_fail "shellcheck is required. Install with 'brew install shellcheck'."
  fi
  local files
  files="$(git -C "$CI_REPO_ROOT" diff --cached --name-only --diff-filter=ACMR -- '*.sh' '**/*.sh' 2>/dev/null || true)"
  [[ -z "$files" ]] && return 0
  ci_section "$label"
  local list=()
  while IFS= read -r f; do
    [[ -f "$CI_REPO_ROOT/$f" ]] && list+=("$CI_REPO_ROOT/$f")
  done <<<"$files"
  [[ ${#list[@]} -gt 0 ]] || return 0
  shellcheck -x "${list[@]}"
}

ci_ruff_check_dir() {
  local dir="$1"
  local label="${2:-Ruff check}"
  if ! command -v ruff >/dev/null 2>&1; then
    ci_fail "ruff is required. Install with 'brew install ruff'."
  fi
  local config="$CI_REPO_ROOT/Scripts/ruff.toml"
  ci_run_in "$label" "$dir" ruff check --config "$config" .
  ci_run_in "$label format" "$dir" ruff format --config "$config" --check .
}

ci_ruff_staged() {
  local label="${1:-Ruff (staged)}"
  if ! command -v ruff >/dev/null 2>&1; then
    ci_fail "ruff is required. Install with 'brew install ruff'."
  fi
  local files
  files="$(git -C "$CI_REPO_ROOT" diff --cached --name-only --diff-filter=ACMR -- 'Scripts/*.py' 2>/dev/null || true)"
  [[ -z "$files" ]] && return 0
  ci_section "$label"
  local config="$CI_REPO_ROOT/Scripts/ruff.toml"
  local list=()
  while IFS= read -r f; do
    [[ -f "$CI_REPO_ROOT/$f" ]] && list+=("$CI_REPO_ROOT/$f")
  done <<<"$files"
  [[ ${#list[@]} -gt 0 ]] || return 0
  ruff check --config "$config" "${list[@]}"
  ruff format --config "$config" --check "${list[@]}"
}

ci_require_cmd_strict() {
  local cmd="$1"
  # shellcheck disable=SC2016 # $cmd inside ${...:-...} default expands in outer double-quote context
  local hint="${2:-Install '$cmd' and try again.}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ci_fail "$cmd is required. $hint"
  fi
}

ci_success() {
  printf '\n✅ %s\n' "$1"
}
