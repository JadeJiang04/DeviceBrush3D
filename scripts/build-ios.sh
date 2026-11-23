#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -version
mkdir -p build
xcrun swiftc Sources/DrawingGeometry.swift Tests/main.swift -o build/geometry-checks
./build/geometry-checks
xcodegen generate
xcodebuild -project SpatialPen.xcodeproj -scheme SpatialPen \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build | tee build.log

mkdir -p output/Payload
# Replace only this script's app bundle, so stale files cannot enter a rebuilt IPA.
if [ -d output/Payload/SpatialPen.app ]; then
  rm -rf output/Payload/SpatialPen.app
fi
cp -R build/Build/Products/Release-iphoneos/SpatialPen.app output/Payload/
test -f output/Payload/SpatialPen.app/SpatialPen
plutil -lint output/Payload/SpatialPen.app/Info.plist
cd output
rm -f SpatialPen-unsigned.ipa
zip -qry SpatialPen-unsigned.ipa Payload
shasum -a 256 SpatialPen-unsigned.ipa > SHA256SUMS.txt
