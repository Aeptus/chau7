#!/usr/bin/env bash
set -euo pipefail
: "${RUNNER_TEMP:?}"
: "${IDENTITY:?Developer ID Application required}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP_ROOT="$ROOT_DIR/apps/chau7-macos"
KEYCHAIN="$RUNNER_TEMP/chau7-signing/release.keychain-db"
APP="$APP_ROOT/dist/Chau7.app"
# shellcheck source=apps/chau7-macos/Scripts/signing.sh
source "$APP_ROOT/Scripts/signing.sh"
export CHAU7_CODESIGN_IDENTITY="$IDENTITY"
chau7_codesign_app "$APP" com.chau7.app release
codesign --verify --strict --deep "$APP"
NOTARY_ZIP="$RUNNER_TEMP/chau7-signing/notarize.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile chau7-release --keychain "$KEYCHAIN" --wait --timeout 600
xcrun stapler staple "$APP"
STAGING="$RUNNER_TEMP/chau7-signing/dmg-staging"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -fs APFS -volname Chau7 -srcfolder "$STAGING" -ov -format UDBZ "$APP_ROOT/dist/Chau7-AppleSilicon.dmg"
chau7_codesign_artifact "$APP_ROOT/dist/Chau7-AppleSilicon.dmg" release
xcrun notarytool submit "$APP_ROOT/dist/Chau7-AppleSilicon.dmg" --keychain-profile chau7-release --keychain "$KEYCHAIN" --wait --timeout 600
xcrun stapler staple "$APP_ROOT/dist/Chau7-AppleSilicon.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ROOT/dist/Chau7-AppleSilicon.zip"
if [[ -n "${INSTALLER_IDENTITY:-}" ]]; then
  pkgbuild --component "$APP" --install-location /Applications --identifier com.chau7.app.pkg \
    --version "$VERSION" --sign "$INSTALLER_IDENTITY" "$APP_ROOT/dist/Chau7-AppleSilicon.pkg"
  xcrun notarytool submit "$APP_ROOT/dist/Chau7-AppleSilicon.pkg" --keychain-profile chau7-release --keychain "$KEYCHAIN" --wait --timeout 600
  xcrun stapler staple "$APP_ROOT/dist/Chau7-AppleSilicon.pkg"
fi
