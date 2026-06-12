#!/usr/bin/env bash

# Shared code-signing helpers for local, installed, and distribution builds.
# This file is sourced by other scripts; do not enable set -e here.

chau7_signing_info() {
  if declare -F log_info >/dev/null 2>&1; then
    log_info "$*"
  elif declare -F info >/dev/null 2>&1; then
    info "$*"
  else
    printf '[SIGN] %s\n' "$*"
  fi
}

chau7_signing_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$*"
  elif declare -F warn >/dev/null 2>&1; then
    warn "$*"
  else
    printf '[SIGN][WARN] %s\n' "$*" >&2
  fi
}

chau7_signing_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$*"
  elif declare -F error >/dev/null 2>&1; then
    error "$*"
  else
    printf '[SIGN][ERROR] %s\n' "$*" >&2
  fi
}

chau7_signing_ok() {
  if declare -F log_ok >/dev/null 2>&1; then
    log_ok "$*"
  elif declare -F info >/dev/null 2>&1; then
    info "$*"
  else
    printf '[SIGN][OK] %s\n' "$*"
  fi
}

chau7_signing_run() {
  if declare -F run_cmd >/dev/null 2>&1; then
    run_cmd "$@"
  else
    "$@"
  fi
}

chau7_available_codesign_identities() {
  security find-identity -v -p codesigning 2>/dev/null |
    awk -F '"' '/^[[:space:]]*[0-9]+\)/ && NF >= 2 { print $2 }'
}

chau7_find_codesign_identity() {
  local prefix="$1"
  chau7_available_codesign_identities |
    awk -v prefix="$prefix" 'index($0, prefix) == 1 { print; exit }'
}

chau7_resolve_codesign_identity() {
  local purpose="${1:-${CHAU7_CODESIGN_PURPOSE:-dev}}"
  local requested="${CHAU7_CODESIGN_IDENTITY:-auto}"
  local identity=""

  case "$requested" in
    ""|auto|AUTO)
      case "$purpose" in
        release|dist|install)
          identity="$(chau7_find_codesign_identity "Developer ID Application:")"
          if [[ -z "$identity" ]]; then
            identity="$(chau7_find_codesign_identity "Apple Distribution:")"
          fi
          if [[ -z "$identity" ]]; then
            identity="$(chau7_find_codesign_identity "Apple Development:")"
          fi
          ;;
        *)
          identity="$(chau7_find_codesign_identity "Apple Development:")"
          if [[ -z "$identity" ]]; then
            identity="$(chau7_find_codesign_identity "Developer ID Application:")"
          fi
          if [[ -z "$identity" ]]; then
            identity="$(chau7_find_codesign_identity "Apple Distribution:")"
          fi
          ;;
      esac
      ;;
    -|adhoc|ad-hoc|ADHOC)
      identity="-"
      ;;
    *)
      identity="$requested"
      ;;
  esac

  if [[ -z "$identity" ]]; then
    identity="-"
  fi
  printf '%s\n' "$identity"
}

chau7_codesign_identity_kind() {
  local identity="$1"
  case "$identity" in
    -) printf 'adhoc\n' ;;
    "Developer ID Application:"*) printf 'developer-id\n' ;;
    "Apple Distribution:"*) printf 'apple-distribution\n' ;;
    "Apple Development:"*|"Mac Developer:"*) printf 'development\n' ;;
    *) printf 'other\n' ;;
  esac
}

chau7_codesign_runtime_enabled() {
  local identity="$1"
  local purpose="${2:-dev}"
  local setting="${CHAU7_CODESIGN_RUNTIME:-auto}"
  local kind
  kind="$(chau7_codesign_identity_kind "$identity")"

  case "$setting" in
    1|true|TRUE|yes|YES) return 0 ;;
    0|false|FALSE|no|NO) return 1 ;;
  esac

  case "$kind:$purpose" in
    developer-id:*|apple-distribution:*|*:release|*:dist|*:install) return 0 ;;
    *) return 1 ;;
  esac
}

chau7_codesign_timestamp_enabled() {
  local identity="$1"
  local setting="${CHAU7_CODESIGN_TIMESTAMP:-auto}"
  local kind
  kind="$(chau7_codesign_identity_kind "$identity")"

  case "$setting" in
    1|true|TRUE|yes|YES) return 0 ;;
    0|false|FALSE|no|NO) return 1 ;;
  esac

  case "$kind" in
    developer-id|apple-distribution) return 0 ;;
    *) return 1 ;;
  esac
}

chau7_codesign_adhoc_app() {
  local app_path="$1"
  local bundle_id="$2"
  local req_file

  if [[ "${USE_STABLE_ADHOC_REQUIREMENT:-1}" == "1" ]] && command -v csreq >/dev/null 2>&1; then
    req_file="$(mktemp "${TMPDIR:-/tmp}/chau7-codesign-requirement.XXXXXX")"
    chau7_signing_run csreq -r "=designated => identifier \"$bundle_id\"" -b "$req_file"
    chau7_signing_run codesign --force --deep --sign - -i "$bundle_id" -r "$req_file" "$app_path"
    chau7_signing_run rm -f "$req_file"
    chau7_signing_ok "Applied stable ad-hoc designated requirement for $bundle_id"
    return
  fi

  if [[ "${USE_STABLE_ADHOC_REQUIREMENT:-1}" == "1" ]]; then
    chau7_signing_warn "csreq not found; falling back to default ad-hoc signing."
  fi
  chau7_signing_run codesign --force --deep --sign - -i "$bundle_id" "$app_path"
  chau7_signing_ok "Ad-hoc signed app bundle"
}

chau7_codesign_with_identity() {
  local path="$1"
  local bundle_id="$2"
  local purpose="$3"
  local identity="$4"
  local args=(codesign --force --sign "$identity")

  # No --deep here: chau7_codesign_nested_code signs every nested Mach-O
  # inside-out before the bundle itself is signed, which is the
  # Apple-recommended flow. --deep re-signed all nested code with the
  # top-level flags, overwriting the careful per-binary identifiers (and
  # Apple deprecates --deep for distribution signing).
  if [[ -n "$bundle_id" ]]; then
    args+=(-i "$bundle_id")
  fi
  if chau7_codesign_runtime_enabled "$identity" "$purpose"; then
    args+=(--options runtime)
  fi

  if chau7_codesign_timestamp_enabled "$identity"; then
    if chau7_signing_run "${args[@]}" --timestamp "$path"; then
      return
    fi
    chau7_signing_warn "Timestamped signing failed; retrying without timestamp. Notarization will require a timestamped signature."
  fi

  chau7_signing_run "${args[@]}" "$path"
}

chau7_is_macho_file() {
  local path="$1"
  [[ -f "$path" && ! -L "$path" ]] || return 1
  file -b "$path" 2>/dev/null | grep -q 'Mach-O'
}

chau7_codesign_nested_code() {
  local app_path="$1"
  local purpose="$2"
  local identity="$3"
  local resources_dir="$app_path/Contents/Resources"
  local nested_path
  local signed_count=0

  [[ -d "$resources_dir" ]] || return 0

  while IFS= read -r -d '' nested_path; do
    if ! chau7_is_macho_file "$nested_path"; then
      continue
    fi
    chau7_signing_info "Code signing nested Mach-O: ${nested_path#"$app_path"/}"
    chau7_codesign_with_identity "$nested_path" "" "$purpose" "$identity"
    signed_count=$((signed_count + 1))
  done < <(find "$resources_dir" -type f \( -name '*.dylib' -o -perm -111 \) -print0)

  if [[ "$signed_count" -gt 0 ]]; then
    chau7_signing_ok "Signed $signed_count nested Mach-O resource(s)"
  fi
}

chau7_codesign_app() {
  local app_path="$1"
  local bundle_id="$2"
  local purpose="${3:-${CHAU7_CODESIGN_PURPOSE:-dev}}"
  local identity
  local kind

  if ! command -v codesign >/dev/null 2>&1; then
    chau7_signing_warn "codesign not found; skipping code signing."
    return 0
  fi

  identity="$(chau7_resolve_codesign_identity "$purpose")"
  kind="$(chau7_codesign_identity_kind "$identity")"
  chau7_signing_info "Code signing app: purpose=$purpose identity=$identity kind=$kind"

  if [[ "$kind" == "adhoc" ]]; then
    chau7_codesign_nested_code "$app_path" "$purpose" "$identity"
    chau7_codesign_adhoc_app "$app_path" "$bundle_id"
    return
  fi

  chau7_codesign_nested_code "$app_path" "$purpose" "$identity"
  chau7_codesign_with_identity "$app_path" "$bundle_id" "$purpose" "$identity"
  chau7_signing_ok "Signed app bundle with $identity"
}

chau7_codesign_artifact() {
  local artifact_path="$1"
  local purpose="${2:-release}"
  local identity
  local kind

  if ! command -v codesign >/dev/null 2>&1; then
    chau7_signing_warn "codesign not found; skipping artifact signing."
    return 0
  fi

  identity="$(chau7_resolve_codesign_identity "$purpose")"
  kind="$(chau7_codesign_identity_kind "$identity")"
  if [[ "$kind" == "adhoc" ]]; then
    chau7_signing_warn "No Apple signing identity available; leaving artifact unsigned: $artifact_path"
    return 0
  fi

  chau7_signing_info "Code signing artifact: purpose=$purpose identity=$identity kind=$kind"
  chau7_codesign_with_identity "$artifact_path" "" "$purpose" "$identity"
  chau7_signing_ok "Signed artifact with $identity"
}

chau7_notarize_artifact() {
  local artifact_path="$1"
  local profile="${CHAU7_NOTARY_PROFILE:-}"

  case "${CHAU7_NOTARIZE:-0}" in
    1|true|TRUE|yes|YES) ;;
    *) return 0 ;;
  esac

  if [[ -z "$profile" ]]; then
    chau7_signing_error "CHAU7_NOTARY_PROFILE is required when CHAU7_NOTARIZE=1."
    return 1
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    chau7_signing_error "xcrun not found; cannot notarize."
    return 1
  fi

  chau7_signing_info "Submitting for notarization with keychain profile '$profile': $artifact_path"
  chau7_signing_run xcrun notarytool submit "$artifact_path" --keychain-profile "$profile" --wait
  chau7_signing_run xcrun stapler staple "$artifact_path"
  chau7_signing_ok "Notarized and stapled $artifact_path"
}
