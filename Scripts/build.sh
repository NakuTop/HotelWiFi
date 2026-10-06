#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
if [[ -z "${HOTELWIFI_SIGNING_IDENTITY:-}" && "${HOTELWIFI_ADHOC:-0}" != "1" ]]; then
    exec /usr/bin/env python3 "$PROJECT_DIR/Scripts/build-local.py"
fi
SIGNING_IDENTITY="${HOTELWIFI_SIGNING_IDENTITY:--}"
read -r -a BUILD_ARCHS <<< "${HOTELWIFI_ARCHS:-arm64 x86_64}"
[[ ${#BUILD_ARCHS[@]} -ge 1 && ${#BUILD_ARCHS[@]} -le 2 ]] || { printf 'Expected arm64, x86_64, or both.\n' >&2; exit 1; }
BIN_DIRS=()
for BUILD_ARCH in "${BUILD_ARCHS[@]}"; do
    case "$BUILD_ARCH" in arm64|x86_64) ;; *) printf 'Unsupported architecture: %s\n' "$BUILD_ARCH" >&2; exit 1 ;; esac
    # Build each deployment-target slice explicitly; no Rosetta or host-arch
    # inference is required to create the Intel part on an Apple Silicon Mac.
    swift build -c release -j 4 --triple "$BUILD_ARCH-apple-macosx14.0" -debug-info-format none
    BIN_DIRS+=("$(swift build -c release --triple "$BUILD_ARCH-apple-macosx14.0" --show-bin-path)")
done
OUTPUT_DIR="$PROJECT_DIR/dist"
STAGE_DIR="$(mktemp -d "$PROJECT_DIR/.hotelwifi-build.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
APP_DIR="$STAGE_DIR/HotelWiFi.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Library/LaunchDaemons" "$APP_DIR/Contents/Frameworks" "$OUTPUT_DIR"
for BINARY in HotelWiFiApp hotelwifi HotelWiFiHelper; do
    INPUTS=()
    for BIN_DIR in "${BIN_DIRS[@]}"; do INPUTS+=("$BIN_DIR/$BINARY"); done
    if [[ ${#INPUTS[@]} -eq 1 ]]; then
        cp "${INPUTS[0]}" "$APP_DIR/Contents/MacOS/$BINARY"
    else
        xcrun lipo -create "${INPUTS[@]}" -output "$APP_DIR/Contents/MacOS/$BINARY"
    fi
done
cp HotelWiFi/Resources/Info.plist "$APP_DIR/Contents/Info.plist"
cp HotelWiFi/Resources/com.hotelwifi.RecoveryGuardian.plist "$APP_DIR/Contents/Library/LaunchDaemons/"
cp README.md "$APP_DIR/Contents/Resources/使用说明.md"
cp -R Docs "$APP_DIR/Contents/Resources/Docs"
swift Scripts/MakeIcon.swift "$STAGE_DIR/HotelWiFi.iconset"
iconutil -c icns "$STAGE_DIR/HotelWiFi.iconset" -o "$APP_DIR/Contents/Resources/HotelWiFi.icns"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string HotelWiFi' "$APP_DIR/Contents/Info.plist"
xcrun swift-stdlib-tool --copy --scan-executable "$APP_DIR/Contents/MacOS/HotelWiFiApp" --scan-executable "$APP_DIR/Contents/MacOS/hotelwifi" --scan-executable "$APP_DIR/Contents/MacOS/HotelWiFiHelper" --destination "$APP_DIR/Contents/Frameworks" --platform macosx
SIGN_ARGS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ -n "${HOTELWIFI_SIGNING_KEYCHAIN:-}" ]]; then SIGN_ARGS+=(--keychain "$HOTELWIFI_SIGNING_KEYCHAIN"); fi
if [[ "$SIGNING_IDENTITY" == "-" || "${HOTELWIFI_LOCAL_SIGNING:-0}" == "1" ]]; then SIGN_ARGS+=(--timestamp=none); else SIGN_ARGS+=(--timestamp); fi
for library in "$APP_DIR"/Contents/Frameworks/*.dylib; do
    [[ -f "$library" ]] || continue
    codesign "${SIGN_ARGS[@]}" "$library"
done
codesign "${SIGN_ARGS[@]}" --identifier com.hotelwifi.cli "$APP_DIR/Contents/MacOS/hotelwifi"
codesign "${SIGN_ARGS[@]}" --identifier com.hotelwifi.helper "$APP_DIR/Contents/MacOS/HotelWiFiHelper"
python3 "$PROJECT_DIR/Scripts/helper-constraint.py" write "$APP_DIR"
codesign "${SIGN_ARGS[@]}" --entitlements HotelWiFi/Resources/HotelWiFi.entitlements --identifier com.hotelwifi.app "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
plutil -lint "$APP_DIR/Contents/Info.plist" "$APP_DIR/Contents/Library/LaunchDaemons/com.hotelwifi.RecoveryGuardian.plist"
if [[ -e "$OUTPUT_DIR/HotelWiFi.app" ]]; then rm -rf "$OUTPUT_DIR/HotelWiFi.app"; fi
mv "$APP_DIR" "$OUTPUT_DIR/HotelWiFi.app"
ditto -c -k --sequesterRsrc --keepParent "$OUTPUT_DIR/HotelWiFi.app" "$OUTPUT_DIR/HotelWiFi-macOS.zip"
bash "$PROJECT_DIR/Scripts/verify-package.sh" "$OUTPUT_DIR/HotelWiFi.app"
printf 'Built %s\n' "$OUTPUT_DIR/HotelWiFi.app"
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    printf 'Local ad-hoc build: native diagnosis is available; privileged writes are disabled.\n'
fi
