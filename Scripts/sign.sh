#!/bin/bash
set -euo pipefail
# Signing a distribution build always includes notarization and stapling.
source "$(dirname "$0")/release-common.sh"
release_init "$@"

if [ -z "${LITEZIP_SIGN_IDENTITY:-}" ]; then
  identities=()
  while IFS= read -r identity; do
    identities+=("$identity")
  done < <(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p')
  if [ "${#identities[@]}" -ne 1 ]; then
    echo 'Set LITEZIP_SIGN_IDENTITY to the Developer ID Application identity to use.' >&2
    exit 1
  fi
  LITEZIP_SIGN_IDENTITY="${identities[0]}"
fi
# Fail before altering signatures if the saved account cannot authenticate.
xcrun notarytool history --keychain-profile "$notary_profile" --output-format json >/dev/null

codesign --force --options runtime --timestamp --sign "$LITEZIP_SIGN_IDENTITY" "$app/Contents/Resources/Engine/7zz"
codesign --force --options runtime --timestamp --sign "$LITEZIP_SIGN_IDENTITY" "$app/Contents/Resources/Engine/zstd"
codesign --force --options runtime --timestamp --entitlements FinderExtension/Finder.entitlements --sign "$LITEZIP_SIGN_IDENTITY" "$app/Contents/PlugIns/LiteZipFinder.appex"
codesign --force --options runtime --timestamp --sign "$LITEZIP_SIGN_IDENTITY" "$app"
verify_developer_id "$app"
exec "$release_root/Scripts/notarize.sh" "$app"
