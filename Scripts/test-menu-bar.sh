#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 6 -parse-as-library \
  Sources/LiteZipApp/StatusItemDropTarget.swift Tests/LiteZipAppTests/MenuBarDropChecks.swift \
  -o build/menu-bar-drop-checks
if ! build/menu-bar-drop-checks 2> build/menu-bar-drop-checks.stderr.log; then
  tail -40 build/menu-bar-drop-checks.stderr.log >&2
  exit 1
fi
