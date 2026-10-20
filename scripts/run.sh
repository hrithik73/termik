#!/bin/sh
# Rebuild Termik and restart it.
set -e
cd "$(dirname "$0")/.."
pkill -x Termik || true
xcodegen generate >/dev/null
xcodebuild -project Termik.xcodeproj -scheme Termik -configuration Debug -derivedDataPath build build -quiet
open build/Build/Products/Debug/Termik.app
