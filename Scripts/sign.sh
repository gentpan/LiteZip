#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${LITEZIP_SIGN_IDENTITY:?Set LITEZIP_SIGN_IDENTITY to a Developer ID Application identity}"
app="${1:-build/LiteZip.app}"
codesign --force --options runtime --timestamp --sign "$LITEZIP_SIGN_IDENTITY" "$app/Contents/Resources/Engine/7zz"
codesign --force --options runtime --timestamp --sign "$LITEZIP_SIGN_IDENTITY" "$app/Contents/Resources/Engine/zstd"
codesign --force --options runtime --timestamp --entitlements FinderExtension/Finder.entitlements --sign "$LITEZIP_SIGN_IDENTITY" "$app/Contents/PlugIns/LiteZipFinder.appex"
codesign --force --options runtime --timestamp --sign "$LITEZIP_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent "$app" dist/LiteZip-0.2.0-macOS-universal.zip
(cd dist && shasum -a 256 LiteZip-0.2.0-macOS-universal.zip) > dist/SHA256SUMS
