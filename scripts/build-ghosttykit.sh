#!/bin/sh
# Builds GhosttyKit.xcframework from vendor/ghostty with our patches applied.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
zig=$(ls -d "$root"/.tools/zig-*/zig 2>/dev/null | head -1)
zig=${zig:-zig}
cd "$root/vendor/ghostty"
for p in "$root"/patches/*.patch; do
  git apply --check "$p" 2>/dev/null && git apply "$p" || echo "skip (already applied): $(basename "$p")"
done
"$zig" build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=native -Doptimize=ReleaseFast
rm -rf "$root/GhosttyKit.xcframework"
cp -R macos/GhosttyKit.xcframework "$root/"
echo "ok: $root/GhosttyKit.xcframework"
