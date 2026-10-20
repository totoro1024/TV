#!/bin/bash
set -euo pipefail
python_root="$(cd "$(dirname "$0")/.." && pwd)"
export PROJECT_DIR="$python_root"
export CODESIGNING_FOLDER_PATH="$1"
export EFFECTIVE_PLATFORM_NAME="$2"
export ARCHS=arm64
export PLATFORM_FAMILY_NAME=iOS
export PRODUCT_BUNDLE_IDENTIFIER=com.totoro.tv.ios
export EXPANDED_CODE_SIGN_IDENTITY=-
export EXPANDED_CODE_SIGN_IDENTITY_NAME=AdHoc
source "$python_root/build/Vendor/PythonIOS/Python.xcframework/build/utils.sh"
install_python build/Vendor/PythonIOS/Python.xcframework
mkdir -p "$CODESIGNING_FOLDER_PATH/python/plugins" "$CODESIGNING_FOLDER_PATH/python/packages"
rsync -a "$python_root/PythonPlugins/" "$CODESIGNING_FOLDER_PATH/python/plugins/" --exclude __pycache__
rsync -a "$python_root/build/Vendor/PythonPackages/" "$CODESIGNING_FOLDER_PATH/python/packages/" --exclude __pycache__ --exclude bin
if [ "$EFFECTIVE_PLATFORM_NAME" = '-iphonesimulator' ]; then
  codesign --force --sign - "$CODESIGNING_FOLDER_PATH"
fi
