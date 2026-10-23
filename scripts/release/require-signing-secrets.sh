#!/usr/bin/env bash
# Fail before any release artifact is presented as signed when the Developer ID
# signing and notarization configuration is incomplete or inconsistent.
set -euo pipefail

for name in IDENTITY CERTIFICATE CERTIFICATE_PASSWORD APPLE_ID APPLE_ID_PASSWORD APPLE_TEAM_ID; do
  if [ -z "${!name:-}" ]; then
    echo "::error::Release signing requires the $name GitHub secret."
    exit 1
  fi
done
case "$IDENTITY" in
  'Developer ID Application:'*) ;;
  *) echo '::error::Release signing requires a Developer ID Application identity.'; exit 1 ;;
esac
if [[ "$IDENTITY" != *" ($APPLE_TEAM_ID)" ]]; then
  echo '::error::Signing identity team does not match APPLE_TEAM_ID.'
  exit 1
fi
