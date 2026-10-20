#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -d "$ROOT/build/Vendor/MobileVLCKit-binary/MobileVLCKit.xcframework" && -f "$ROOT/build/Vendor/.tv-vlc-version" ]] && [[ "$(cat "$ROOT/build/Vendor/.tv-vlc-version")" == "3.7.4" ]]; then exit 0; fi
mkdir -p "$ROOT/build/Vendor"
archive="$ROOT/build/Vendor/MobileVLCKit-3.7.4.tar.xz"
curl -fL --retry 2 'https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz' -o "$archive"
printf '%s  %s\n' 'c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52' "$archive" | shasum -a 256 -c -
tar -xJf "$archive" -C "$ROOT/build/Vendor"
printf '3.7.4\n' > "$ROOT/build/Vendor/.tv-vlc-version"
