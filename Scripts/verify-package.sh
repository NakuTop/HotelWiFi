#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${1:-$PROJECT_DIR/dist/HotelWiFi.app}"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
# Hardened Runtime silently suppresses the Location prompt without this signed entitlement.
LOCATION_ENTITLEMENTS="$(codesign -d --entitlements :- "$APP_DIR" 2>/dev/null)"
printf '%s' "$LOCATION_ENTITLEMENTS" | python3 -c 'import sys,plistlib; assert plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.personal-information.location") is True'
[[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP_DIR/Contents/Info.plist")" == 'HotelWiFiApp' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print LSMinimumSystemVersion' "$APP_DIR/Contents/Info.plist")" == '14.0' ]]
[[ "$(/usr/libexec/PlistBuddy -c 'Print BundleProgram' "$APP_DIR/Contents/Library/LaunchDaemons/com.hotelwifi.RecoveryGuardian.plist")" == 'Contents/MacOS/HotelWiFiHelper' ]]
python3 "$PROJECT_DIR/Scripts/helper-constraint.py" verify "$APP_DIR"
[[ "$(stat -f '%i' "$APP_DIR/Contents/MacOS/HotelWiFiApp")" != "$(stat -f '%i' "$APP_DIR/Contents/MacOS/hotelwifi")" ]]
for binary in HotelWiFiApp hotelwifi HotelWiFiHelper; do
    [[ -x "$APP_DIR/Contents/MacOS/$binary" ]]
done
python3 "$PROJECT_DIR/Scripts/verify-binaries.py" "$APP_DIR"
"$APP_DIR/Contents/MacOS/hotelwifi" help > /dev/null
printf 'Package structure, separate executables, deployment target, CLI entry and code seals verified.\n'
