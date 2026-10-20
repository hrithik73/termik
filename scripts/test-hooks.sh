#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
out=$(mktemp -d)
swiftc -parse-as-library -o "$out/t" Sources/ClaudeHooks.swift scripts/test-hooks.swift && "$out/t"
