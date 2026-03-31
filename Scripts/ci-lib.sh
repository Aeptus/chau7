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
  local hint="${2:-Install '$cmd' and try again.}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    ci_fail "$cmd is required. $hint"
  fi
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
  local files=()
  while IFS= read -r f; do files+=("$f"); done < <(find "$CI_REPO_ROOT/$dir" -type f -name '*.go' | sort)
  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi

  ci_section "$label"
  local output
  output="$(gofmt -l "${files[@]}")"
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

ci_success() {
  printf '\n✅ %s\n' "$1"
}
