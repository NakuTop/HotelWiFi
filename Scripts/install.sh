#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SOURCE="$PROJECT_DIR/dist/HotelWiFi.app"
DESTINATION="${1:-/Applications/HotelWiFi.app}"
[[ -d "$APP_SOURCE" ]] || { printf 'Run Scripts/build.sh first.\n' >&2; exit 1; }
[[ ! -e "$DESTINATION" ]] || { printf 'Destination already exists. For build 9 or newer, use bash Scripts/update.sh. Older versions require 停止并恢复 and 注销服务 before replacement.\n' >&2; exit 1; }
[[ -w "$(dirname "$DESTINATION")" ]] || { printf '请在 Finder 将应用安装到系统 Applications，并完成 macOS 安装认证。\n' >&2; exit 1; }
mkdir -p "$(dirname "$DESTINATION")"
ditto "$APP_SOURCE" "$DESTINATION"
codesign --verify --deep --strict "$DESTINATION"
printf 'Installed %s\n' "$DESTINATION"
printf 'CLI: %s/Contents/MacOS/hotelwifi\n' "$DESTINATION"
open "$DESTINATION"
