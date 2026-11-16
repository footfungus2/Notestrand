#!/bin/sh
# Builds an unsigned Notestrand.tipa for TrollStore (fake-signed with ldid).
set -eu
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "xcodegen missing: brew install xcodegen"; exit 1; }
command -v ldid >/dev/null || { echo "ldid missing: brew install ldid"; exit 1; }

xcodegen generate --quiet
rm -rf build/Release-iphoneos build/Payload
xcodebuild -project Notestrand.xcodeproj -scheme Notestrand -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  SYMROOT="$PWD/build" -quiet build

mkdir -p build/Payload
cp -R build/Release-iphoneos/Notestrand.app build/Payload/
# Sign the share extension first, then the app around it. TrollStore needs application-identifier for the
# Keychain, and both need the App Group to share an inbox.
ldid -SShareExtension/NotestrandShare.entitlements build/Payload/Notestrand.app/PlugIns/NotestrandShare.appex/NotestrandShare
ldid -SNotestrand/Notestrand.entitlements build/Payload/Notestrand.app/Notestrand
(cd build && rm -f Notestrand.tipa && zip -qry Notestrand.tipa Payload)
echo "Built $(pwd)/build/Notestrand.tipa"
