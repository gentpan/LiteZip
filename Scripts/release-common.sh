#!/bin/bash
# Shared setup for Developer ID distribution. Credentials stay in Keychain.
release_init() {
  if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [path/to/LiteZip.app]" >&2
    exit 2
  fi
  release_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  cd "$release_root"
  app="${1:-build/LiteZip.app}"
  if [ ! -d "$app/Contents" ]; then
    echo "App bundle not found: $app. Run Scripts/build.sh first." >&2
    exit 1
  fi
  app="$(cd "$(dirname "$app")" && pwd -P)/$(basename "$app")"
  version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
  if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 1
  fi
  archive_name="LiteZip-${version}-macOS-universal.zip"
  dist_dir="${LITEZIP_DIST_DIR:-$release_root/dist}"
  mkdir -p "$dist_dir"
  dist_dir="$(cd "$dist_dir" && pwd -P)"
  notary_profile="${LITEZIP_NOTARY_PROFILE:-GiantAccel}"
}

verify_developer_id() {
  codesign --verify --deep --strict --verbose=2 "$1"
  # Read the complete output: an early-closing pipe can make codesign fail.
  local signature_details
  signature_details="$(codesign --display --verbose=2 "$1" 2>&1)"
  if [[ "$signature_details" != *$'\nAuthority=Developer ID Application:'* ]]; then
    echo "A Developer ID Application signature is required: $1" >&2
    exit 1
  fi
}
