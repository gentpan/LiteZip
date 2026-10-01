#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LITEZIP_NOTARY_PROFILE:?Set LITEZIP_NOTARY_PROFILE to your saved notarytool keychain profile}"
xcrun notarytool submit dist/LiteZip-0.1.0-macOS-universal.zip --keychain-profile "$LITEZIP_NOTARY_PROFILE" --wait
xcrun stapler staple build/LiteZip.app
xcrun stapler validate build/LiteZip.app
spctl --assess --type execute --verbose=2 build/LiteZip.app
ditto -c -k --sequesterRsrc --keepParent build/LiteZip.app dist/LiteZip-0.1.0-macOS-universal.zip
(cd dist && shasum -a 256 LiteZip-0.1.0-macOS-universal.zip) > dist/SHA256SUMS
