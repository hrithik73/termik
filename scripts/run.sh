#!/bin/sh
# Rebuild HTerm and restart it.
set -e
cd "$(dirname "$0")/.."
pkill -x HTerm || true
xcodegen generate >/dev/null
xcodebuild -project Ghostline.xcodeproj -scheme Ghostline -configuration Debug -derivedDataPath build build -quiet
open build/Build/Products/Debug/HTerm.app
