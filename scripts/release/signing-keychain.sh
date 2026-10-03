#!/usr/bin/env bash
# CI-only signing lifecycle. Never call this to inspect a user's keychains.
set -euo pipefail
: "${RUNNER_TEMP:?CI runner temporary directory required}"
SIGNING_DIR="$RUNNER_TEMP/chau7-signing"
KEYCHAIN="$SIGNING_DIR/release.keychain-db"
cleanup() {
  if [[ -f "$SIGNING_DIR/search-list" ]]; then
    previous=()
    while IFS= read -r item; do
      item="${item#*\"}"; item="${item%\"*}"
      [[ -z "$item" ]] || previous+=("$item")
    done < "$SIGNING_DIR/search-list"
    security list-keychains -d user -s "${previous[@]}" || true
  fi
  if [[ -e "$KEYCHAIN" ]]; then security delete-keychain "$KEYCHAIN" || true; fi
  rm -rf "$SIGNING_DIR"
}
case "${1:-}" in
  cleanup) cleanup ;;
  setup)
    : "${APPLE_CERTIFICATE_P12:?Missing certificate}"
    : "${APPLE_CERTIFICATE_PASSWORD:?Missing certificate password}"
    : "${APPLE_ID:?Missing Apple account}"
    : "${APPLE_ID_PASSWORD:?Missing notarization password}"
    : "${APPLE_TEAM_ID:?Missing Apple team}"
    umask 077
    mkdir -p "$SIGNING_DIR"
    security list-keychains -d user > "$SIGNING_DIR/search-list"
    cleanup_on_error() {
      local status=$?
      if [[ "$status" != 0 ]]; then cleanup; fi
      exit "$status"
    }
    trap cleanup_on_error EXIT
    openssl rand -hex 32 > "$SIGNING_DIR/password"
    password="$(cat "$SIGNING_DIR/password")"
    echo "::add-mask::$password"
    printf '%s' "$APPLE_CERTIFICATE_P12" | base64 --decode > "$SIGNING_DIR/certificate.p12"
    security create-keychain -p "$password" "$KEYCHAIN"
    security set-keychain-settings -lut 1800 "$KEYCHAIN"
    security unlock-keychain -p "$password" "$KEYCHAIN"
    security import "$SIGNING_DIR/certificate.p12" -P "$APPLE_CERTIFICATE_PASSWORD" \
      -t cert -f pkcs12 -k "$KEYCHAIN" -T /usr/bin/codesign -T /usr/bin/pkgbuild -T /usr/bin/productbuild
    rm "$SIGNING_DIR/certificate.p12"
    security set-key-partition-list -S apple-tool:,apple: -s -k "$password" "$KEYCHAIN"
    security list-keychains -d user -s "$KEYCHAIN"
    xcrun notarytool store-credentials chau7-release --keychain "$KEYCHAIN" \
      --apple-id "$APPLE_ID" --password "$APPLE_ID_PASSWORD" --team-id "$APPLE_TEAM_ID"
    ;;
  *) echo "Usage: $0 setup|cleanup (CI only)" >&2; exit 2 ;;
esac
