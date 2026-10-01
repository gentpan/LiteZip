#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
xcodebuild -project LiteZip.xcodeproj -scheme LiteZip -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
mkdir -p build
# Replace the previous staging bundle so removed resources cannot survive a build.
rm -rf build/LiteZip.app
/usr/bin/ditto build/DerivedData/Build/Products/Release/LiteZip.app build/LiteZip.app
test -s build/LiteZip.app/Contents/Resources/AppIcon.icns
test -s build/LiteZip.app/Contents/Resources/Assets.car
cp build/LiteZip.app/Contents/Resources/AppIcon.icns Resources/AppIcon.icns
test -f build/LiteZip.app/Contents/Resources/ThirdPartyNotices.txt
for engine in lzip lz4 brotli lrzip snzip; do
  test -x "build/LiteZip.app/Contents/Resources/Engine/$engine"
  archs="$(lipo "build/LiteZip.app/Contents/Resources/Engine/$engine" -archs)"
  [[ " $archs " == *' arm64 '* && " $archs " == *' x86_64 '* ]]
done
test -f build/LiteZip.app/Contents/Resources/Licenses/lrzip.txt
test -f build/LiteZip.app/Contents/Resources/SourcePackages/lrzip-0.7.3.tar.xz

test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' build/LiteZip.app/Contents/PlugIns/LiteZipFinder.appex/Contents/Info.plist)" = 'com.apple.FinderSync'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/LiteZip.app/Contents/Info.plist)" = '0.5.0'
test "$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' build/LiteZip.app/Contents/Info.plist)" = '001'
