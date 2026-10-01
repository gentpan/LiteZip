#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo 'Install XcodeGen: brew install xcodegen' >&2; exit 1; }
xcodegen generate
xcodebuild -project LiteZip.xcodeproj -scheme LiteZip -configuration Release \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
mkdir -p build
/usr/bin/ditto build/DerivedData/Build/Products/Release/LiteZip.app build/LiteZip.app

test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' build/LiteZip.app/Contents/PlugIns/LiteZipFinder.appex/Contents/Info.plist)" = 'com.apple.FinderSync'
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/LiteZip.app/Contents/Info.plist)" = '0.4.0'
test "$(/usr/libexec/PlistBuddy -c 'Print :UTExportedTypeDeclarations:0:UTTypeTagSpecification:public.filename-extension:0' build/LiteZip.app/Contents/Info.plist)" = '001'
