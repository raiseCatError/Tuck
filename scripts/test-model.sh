#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$(mktemp -t tuck-model.XXXXXX)"
trap 'rm -f "$BIN"' EXIT
swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/Shared/Preferences.swift" \
  "$ROOT/Sources/Shared/Actions.swift" \
  "$ROOT/Tests/MenuModelTests.swift" -o "$BIN"
"$BIN"
