#!/bin/sh

wrapper_dir=$(CDPATH='' cd -- "$(dirname -- "$0")" 2>/dev/null && pwd -P)
set -f
original_path=$PATH
clean_path=
real_codex=
old_ifs=$IFS
IFS=:
for path_entry in $original_path; do
  [ -n "$path_entry" ] || path_entry=.
  canonical_entry=$(CDPATH='' cd -- "$path_entry" 2>/dev/null && pwd -P)
  [ "$canonical_entry" = "$wrapper_dir" ] && continue
  if [ -z "$clean_path" ]; then
    clean_path=$path_entry
  else
    clean_path=$clean_path:$path_entry
  fi
  if [ -z "$real_codex" ] && [ -x "$path_entry/codex" ]; then
    real_codex=$path_entry/codex
  fi
done
IFS=$old_ifs

if [ -z "$real_codex" ]; then
  echo "chau7-next: could not find the real Codex executable" >&2
  exit 127
fi
export PATH="$clean_path"

# Optional owned hook installation applies even when API analytics is disabled.
run_codex() {
  if [ "${TERM_PROGRAM:-}" = Chau7Next ] && [ -n "${CHAU7_NEXT_TAB_ID:-}" ] && [ -f "$wrapper_dir/chau7-next-codex-notify" ] && command -v python3 >/dev/null 2>&1; then
    export CHAU7_TAB_ID=
    exec python3 "$wrapper_dir/chau7-next-codex-notify" --wrap "$real_codex" "$@"
  fi
  exec "$real_codex" "$@"
}

if [ -z "$CHAU7_NEXT_OPENAI_PROXY_BASE_URL" ]; then
  run_codex "$@"
fi

# Accept only the owned TLS loopback launch endpoint.
case "$CHAU7_NEXT_OPENAI_PROXY_BASE_URL" in
 https://127.0.0.1:*) proxy_port=${CHAU7_NEXT_OPENAI_PROXY_BASE_URL#https://127.0.0.1:} ;;
 *) echo "chau7-next: invalid analytics endpoint; starting without analytics" >&2; run_codex "$@" ;;
esac
case "$proxy_port" in
 ""|*[!0-9]*) echo "chau7-next: invalid analytics port; starting without analytics" >&2; run_codex "$@" ;;
esac
if [ "${#proxy_port}" -gt 5 ] || [ "$proxy_port" -lt 1024 ] || [ "$proxy_port" -gt 65535 ]; then
 echo "chau7-next: invalid analytics port; starting without analytics" >&2
 run_codex "$@"
fi
local_ca=$CHAU7_NEXT_CODEX_CA_CERTIFICATE
if [ -z "$local_ca" ] || [ ! -r "$local_ca" ]; then
  echo "chau7-next: proxy certificate unavailable; starting Codex without analytics" >&2
  run_codex "$@"
fi

existing_ca=${CODEX_CA_CERTIFICATE:-${SSL_CERT_FILE:-}}
if [ -n "$existing_ca" ] && [ "$existing_ca" != "$local_ca" ] && [ -r "$existing_ca" ]; then
  ca_dir=${wrapper_dir%/bin}/codex-ca
  safe_tab=$(printf '%s' "${CHAU7_NEXT_TAB_ID:-session}" | tr -cd 'A-Za-z0-9._-')
  [ -n "$safe_tab" ] || safe_tab=session
  combined_ca=$ca_dir/$safe_tab.pem
  combined_ca_tmp=$combined_ca.$$
  umask 077
  if mkdir -p "$ca_dir" && cat "$existing_ca" "$local_ca" > "$combined_ca_tmp" && mv "$combined_ca_tmp" "$combined_ca"; then
    export CODEX_CA_CERTIFICATE="$combined_ca"
  else
    rm -f "$combined_ca_tmp"
    echo "chau7-next: could not prepare Codex CA bundle; starting without analytics" >&2
    run_codex "$@"
  fi
else
  export CODEX_CA_CERTIFICATE="$local_ca"
fi

project_dir=$PWD
if command -v git >/dev/null 2>&1; then
  git_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$git_root" ] && project_dir=$git_root
fi
project_token=$(printf '%s' "$project_dir" | base64 | tr '+/' '-_' | tr -d '=\n')
proxy_base=$CHAU7_NEXT_OPENAI_PROXY_BASE_URL/_chau7/project/$project_token/v1

run_codex -c "openai_base_url=\"$proxy_base\"" "$@"
