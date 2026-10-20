#!/bin/bash
set -euo pipefail
python_root="$(cd "$(dirname "$0")/.." && pwd)"
python_vendor="$python_root/build/Vendor/PythonIOS"
if [ ! -f "$python_vendor/Python.xcframework/Info.plist" ]; then
  mkdir -p "$python_vendor"
  python_archive="$python_root/build/Vendor/python-3.15.0-iOS-XCframework.tar.gz"
  curl --fail --location --retry 2 --silent --show-error 'https://www.python.org/ftp/python/3.15.0/python-3.15.0-iOS-XCframework.tar.gz' -o "$python_archive"
  printf '68e98ab35cc0643ba3a227a8c7768da45c2a5e67dbe1bc26598537e96680fd19  %s\n' "$python_archive" | shasum -a 256 -c -
  tar -xzf "$python_archive" -C "$python_vendor"
fi
python_packages="$python_root/build/Vendor/PythonPackages"
if [ ! -f "$python_packages/requests/__init__.py" ]; then
  mkdir -p "$python_packages"
  python3 -m venv "$python_root/build/Vendor/PythonBuildEnv"
  "$python_root/build/Vendor/PythonBuildEnv/bin/pip" install --disable-pip-version-check --only-binary=:all: --platform any --python-version 3.15 --target "$python_packages" 'requests==2.32.5' 'urllib3==2.6.3' 'certifi==2026.10.18' 'charset-normalizer==3.5.2' 'idna==3.20'
fi
