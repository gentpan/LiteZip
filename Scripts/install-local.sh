#!/bin/bash
set -euo pipefail
# Build the working tree and make it the only LiteZip on this Mac, for local testing.
# Signs like a release (engines, Finder extension with its entitlements, app) with the
# Developer ID identity, but never notarizes or packages; Scripts/sign.sh does that.
# Without a single Developer ID identity (or LITEZIP_SIGN_IDENTITY) the project's ad hoc
# signature is kept; it still carries the Finder extension's sandbox entitlement.
# The version number is left exactly as the project has it.
# Build products and the signing copy live in .noindex folders, which Spotlight skips, so
# the only LiteZip the system lists (Spotlight, Open With, Launchpad) is the installed one.
# Set LITEZIP_NO_LAUNCH=1 to install without opening the app.
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }

app=/Applications/LiteZip.app
lsregister=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
built=build/DerivedData.noindex/Build/Products/Release/LiteZip.app
stage=build/Install.noindex/LiteZip.app

# Build first, so a failed build never touches the installed copy.
xcodegen generate
mkdir -p build
xcodebuild -project LiteZip.xcodeproj -scheme LiteZip -configuration Release \
  -derivedDataPath build/DerivedData.noindex build > build/install-local.log 2>&1 \
  || { tail -30 build/install-local.log >&2; echo "Build failed; installed copy left unchanged. Log: build/install-local.log" >&2; exit 1; }
test -d "$built"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSUIElement' "$built/Contents/Info.plist")" = 'true'
codesign --verify --deep --strict "$built"
rm -rf "$(dirname "$stage")"
mkdir -p "$(dirname "$stage")"
/usr/bin/ditto "$built" "$stage"

identity="${LITEZIP_SIGN_IDENTITY:-}"
if [ -z "$identity" ]; then
  identities=()
  while IFS= read -r line; do
    identities+=("$line")
  done < <(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)".*/\1/p')
  [ "${#identities[@]}" -eq 1 ] && identity="${identities[0]}"
fi
if [ -n "$identity" ]; then
  # No secure timestamp: it is only needed for notarization and would require the network.
  for engine in "$stage"/Contents/Resources/Engine/*; do
    codesign --force --options runtime --timestamp=none --sign "$identity" "$engine"
  done
  codesign --force --options runtime --timestamp=none --entitlements FinderExtension/Finder.entitlements \
    --sign "$identity" "$stage/Contents/PlugIns/LiteZipFinder.appex"
  codesign --force --options runtime --timestamp=none --sign "$identity" "$stage"
  signature="$identity, not notarized"
else
  signature="ad hoc"
fi
codesign --verify --deep --strict "$stage"

# Stop a running copy so it can be replaced. This is SIGTERM, not a polite quit (an Apple
# Event would trigger a system Automation prompt), so unfinished jobs are interrupted.
if pgrep -f "$app/Contents/MacOS/LiteZip" >/dev/null; then
  pkill -TERM -f "$app/Contents/MacOS/LiteZip" || true
  for _ in 1 2 3 4 5 6; do
    pgrep -f "$app/Contents/MacOS/LiteZip" >/dev/null || break
    sleep 0.5
  done
  pkill -KILL -f "$app/Contents/MacOS/LiteZip" 2>/dev/null || true
fi

# Swap in the new copy next to the old one, then replace it.
staging="/Applications/.LiteZip.install.$$"
rm -rf "$staging"
/usr/bin/ditto "$stage" "$staging"
rm -rf "$app"
mv "$staging" "$app"

# Leave exactly one registered copy: build outputs and older bundles stay on disk
# but are removed from LaunchServices and the Finder-extension registry.
"$lsregister" -dump 2>/dev/null | sed -n -E 's/^ *path: +(.*LiteZip\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u \
  | while IFS= read -r path; do
      [ "$path" = "$app" ] && continue
      pluginkit -r "$path/Contents/PlugIns/LiteZipFinder.appex" 2>/dev/null || true
      "$lsregister" -u "$path" 2>/dev/null || true
    done
"$lsregister" -f "$app"
rm -rf "$(dirname "$stage")"

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
git diff --quiet HEAD -- 2>/dev/null || commit="$commit+uncommitted"
echo "Installed LiteZip $version (build $build, $commit) -> $app"
echo "Signature: $signature"
echo "If Finder's right-click menu looks outdated, run: killall Finder"
[ "${LITEZIP_NO_LAUNCH:-}" = 1 ] || open "$app"
