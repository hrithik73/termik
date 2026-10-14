#!/bin/sh
# Vendors Monaco (VS Code's editor) for the diff review window. Bundled so review works offline.
set -eu
v=0.52.2
dst="$(dirname "$0")/../vendor/monaco"
[ -f "$dst/.v$v" ] && exit 0
rm -rf "$dst" && mkdir -p "$dst"
curl -fsSL "https://registry.npmjs.org/monaco-editor/-/monaco-editor-$v.tgz" | tar xz -C "$dst" --strip-components 2 package/min/vs
touch "$dst/.v$v"
