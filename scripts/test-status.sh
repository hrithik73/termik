#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d)
cp scripts/test-status.swift "$out/main.swift"
swiftc -o "$out/t" Sources/ProgramStatus.swift "$out/main.swift" && "$out/t"
