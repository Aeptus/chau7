#!/usr/bin/env bash
# Sign and notarize an already-built Rust production bundle. This script
# never invokes Cargo and never publishes a tag or GitHub Release.
# RELEASE_STAGE=rc names versioned candidate artifacts for Actions retention;
# RELEASE_STAGE=stable names the Chau7-AppleSilicon release assets that the
# release workflow publishes and the Homebrew cask downloads.
set -euo pipefail

RELEASE_STAGE="${RELEASE_STAGE:-rc}"
case "$RELEASE_STAGE" in
  rc|stable) ;;
  *) echo "error: RELEASE_STAGE must be 'rc' or 'stable' (got '$RELEASE_STAGE')" >&2; exit 1 ;;
esac

: "${RUNNER_TEMP:?CI runner temporary directory required}"
: "${APP_PATH:?Path to the already-built Chau7.app is required}"
: "${MANIFEST_PATH:?Path to the build manifest is required}"
: "${DIST_DIR:?Candidate output directory is required}"
: "${IDENTITY:?Developer ID Application identity required}"
: "${APPLE_TEAM_ID:?Apple team identifier required}"

if [[ "$IDENTITY" != "Developer ID Application:"* ]]; then
  echo 'error: production signing requires a Developer ID Application identity' >&2
  exit 1
fi
if [[ ! "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo 'error: Apple team identifier must contain ten uppercase letters or digits' >&2
  exit 1
fi
if [[ "$IDENTITY" != *" ($APPLE_TEAM_ID)" ]]; then
  echo 'error: signing identity team does not match APPLE_TEAM_ID' >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KEYCHAIN="$RUNNER_TEMP/chau7-signing/release.keychain-db"
APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd -P)/$(basename "$APP_PATH")"
MANIFEST_PATH="$(cd "$(dirname "$MANIFEST_PATH")" && pwd -P)/$(basename "$MANIFEST_PATH")"
DIST_DIR="$(mkdir -p "$DIST_DIR" && cd "$DIST_DIR" && pwd -P)"
APP_ID='com.chau7.app'
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-local}}"

[[ -d "$APP_PATH" && "$(basename "$APP_PATH")" == 'Chau7.app' ]] || {
  echo 'error: expected an already-built Chau7.app bundle' >&2
  exit 1
}
[[ -f "$MANIFEST_PATH" ]] || {
  echo 'error: production build manifest is missing' >&2
  exit 1
}
[[ "$MANIFEST_PATH" != "$APP_PATH" && "$MANIFEST_PATH" != "$APP_PATH/"* ]] || {
  echo 'error: build manifest must remain outside the app bundle' >&2
  exit 1
}
[[ -f "$KEYCHAIN" ]] || {
  echo 'error: isolated release keychain is missing; run signing-keychain.sh setup first' >&2
  exit 1
}

INFO_PLIST="$APP_PATH/Contents/Info.plist"
[[ -f "$INFO_PLIST" ]] || {
  echo 'error: app Info.plist is missing' >&2
  exit 1
}
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" | grep -Fxq "$APP_ID" || {
  echo 'error: app bundle identity is not the production identity' >&2
  exit 1
}
/usr/libexec/PlistBuddy -c 'Print :Chau7BuildChannel' "$INFO_PLIST" | grep -Fxq production || {
  echo 'error: app bundle is not marked as production' >&2
  exit 1
}

MACOS_DIR="$APP_PATH/Contents/MacOS"
EXPECTED_EXECUTABLES=(
  Chau7
  chau7-next-mcp-bridge
  chau7-next-cli
  chau7-optim
  chau7-md
  chau7-remote
  chau7-proxy
)
for executable in "${EXPECTED_EXECUTABLES[@]}"; do
  path="$MACOS_DIR/$executable"
  [[ -f "$path" && -x "$path" ]] || {
    echo "error: required production executable is missing: $executable" >&2
    exit 1
  }
done

verify_team() {
  local path="$1"
  local expected_identifier="$2"
  local details
  if ! details="$(codesign --display --verbose=4 "$path" 2>&1)"; then
    printf '%s\n' "$details" >&2
    echo "error: unable to inspect signature: $path" >&2
    return 1
  fi
  if ! grep -Fxq "TeamIdentifier=$APPLE_TEAM_ID" <<<"$details"; then
    echo "error: signature team does not match for $path" >&2
    return 1
  fi
  if ! grep -Fxq "Identifier=$expected_identifier" <<<"$details"; then
    echo "error: code signature identifier does not match for $path" >&2
    return 1
  fi
}

# Sign every executable directly because the old nested-code helper only
# discovers executables under Contents/Resources. Assign distinct identifiers
# to helpers, then seal the root app bundle with its production identifier.
for executable in "${EXPECTED_EXECUTABLES[@]}"; do
  path="$MACOS_DIR/$executable"
  if [[ "$executable" == Chau7 ]]; then
    identifier="$APP_ID"
  else
    identifier="$APP_ID.helper.$executable"
  fi
  codesign --force --sign "$IDENTITY" --options runtime --timestamp \
    --identifier "$identifier" "$path"
  codesign --verify --strict --verbose=2 "$path"
  verify_team "$path" "$identifier"
done
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --identifier "$APP_ID" "$APP_PATH"
codesign --verify --strict --deep --verbose=2 "$APP_PATH"
verify_team "$APP_PATH" "$APP_ID"

NOTARY_ZIP="$RUNNER_TEMP/chau7-signing/Chau7-Rust-Production-notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile chau7-release \
  --keychain "$KEYCHAIN" --wait --timeout 600
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

python3 "$ROOT_DIR/scripts/release/refresh-rust-manifest.py" \
  --app "$APP_PATH" \
  --manifest "$MANIFEST_PATH" \
  --identity "$IDENTITY" \
  --team-id "$APPLE_TEAM_ID" \
  --stage "$RELEASE_STAGE"

RELEASE_VERSION="$(python3 - "$MANIFEST_PATH" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    print(json.load(stream)["releaseVersion"])
PY
)"
if [[ "$RELEASE_STAGE" == stable ]]; then
  ARTIFACT_STEM="Chau7-AppleSilicon"
else
  ARTIFACT_STEM="Chau7-Rust-Production-RC-${RELEASE_VERSION}-${BUILD_NUMBER}-arm64"
fi
STAGING="$RUNNER_TEMP/chau7-signing/dmg-staging"
DMG="$DIST_DIR/$ARTIFACT_STEM.dmg"
ZIP="$DIST_DIR/$ARTIFACT_STEM.zip"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -fs APFS -volname Chau7 -srcfolder "$STAGING" \
  -ov -format UDBZ "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile chau7-release \
  --keychain "$KEYCHAIN" --wait --timeout 600
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP"
cp "$MANIFEST_PATH" "$DIST_DIR/$ARTIFACT_STEM-build-manifest.json"

(
  cd "$DIST_DIR"
  shasum -a 256 "$ARTIFACT_STEM.dmg" "$ARTIFACT_STEM.zip" \
    "$ARTIFACT_STEM-build-manifest.json" > SHA256SUMS.txt
)
printf 'Signed and notarized Rust production %s artifacts: %s\n' "$RELEASE_STAGE" "$DIST_DIR"
