#!/bin/bash
# Creates downloadable artifacts from an already built, sealed universal app.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$PROJECT_DIR/dist/HotelWiFi.app"
bash "$PROJECT_DIR/Scripts/verify-package.sh" "$APP_DIR"
for BINARY in HotelWiFiApp hotelwifi HotelWiFiHelper; do
    xcrun lipo "$APP_DIR/Contents/MacOS/$BINARY" -verify_arch arm64 x86_64
done
STAGE_DIR="$(mktemp -d "$PROJECT_DIR/.hotelwifi-build.release.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
mkdir -p "$STAGE_DIR/volume"
ditto "$APP_DIR" "$STAGE_DIR/volume/HotelWiFi.app"
ln -s /Applications "$STAGE_DIR/volume/Applications"
cp "$PROJECT_DIR/Docs/INSTALL.txt" "$STAGE_DIR/volume/安装说明.txt"
hdiutil create -volname HotelWiFi -srcfolder "$STAGE_DIR/volume" -fs HFS+ -format UDZO "$STAGE_DIR/HotelWiFi-macOS.dmg"
hdiutil verify "$STAGE_DIR/HotelWiFi-macOS.dmg"
mv -f "$STAGE_DIR/HotelWiFi-macOS.dmg" "$PROJECT_DIR/dist/HotelWiFi-macOS.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$PROJECT_DIR/dist/HotelWiFi-macOS.zip"
cd "$PROJECT_DIR/dist"
shasum -a 256 HotelWiFi-macOS.dmg HotelWiFi-macOS.zip > SHA256SUMS.txt
printf 'Universal release artifacts: dist/HotelWiFi-macOS.dmg, dist/HotelWiFi-macOS.zip, dist/SHA256SUMS.txt\n'
