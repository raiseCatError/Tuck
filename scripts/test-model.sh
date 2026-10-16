#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED=("$ROOT"/Sources/Shared/*.swift)
for TEST in "$ROOT"/Tests/*.swift; do
  NAME="$(basename "$TEST" .swift)"
  BIN="$(mktemp -t "tuck-$NAME.XXXXXX")"
  trap 'rm -f "$BIN"' EXIT
  swiftc -swift-version 6 -parse-as-library -framework CryptoKit \
    "${SHARED[@]}" "$TEST" -o "$BIN"
  "$BIN"
  rm -f "$BIN"
done