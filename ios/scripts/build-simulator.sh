#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
bash "$ROOT/scripts/prepare-vlc.sh"
bash "$ROOT/scripts/prepare-python.sh"
python3 "$ROOT/scripts/generate-project.py"
xcodebuild -project "$ROOT/TVWebDAV.xcodeproj" -scheme TVWebDAV -configuration Debug \
 -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
 -derivedDataPath "$ROOT/build/SimulatorDerivedData" CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
bash "$ROOT/scripts/bundle-python.sh" "$ROOT/build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/TVWebDAV.app" -iphonesimulator
codesign --verify --deep --strict "$ROOT/build/SimulatorDerivedData/Build/Products/Debug-iphonesimulator/TVWebDAV.app"
