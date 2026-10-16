#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/scripts/dev-scratch.sh"
MODULE_ARGS=()
if [[ -n "${TUCK_SWIFT_MODULE_CACHE:-}" ]]; then
  MODULE_ARGS=(-module-cache-path "$TUCK_SWIFT_MODULE_CACHE")
fi
SHARED=("$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/App/FileWork.swift "$ROOT"/Sources/App/*/*.swift)
for TEST in "$ROOT"/Tests/*.swift; do
  NAME="$(basename "$TEST" .swift)"
  BIN="$(mktemp -t "tuck-$NAME.XXXXXX")"
  trap 'rm -f "$BIN"' EXIT
  swiftc "${MODULE_ARGS[@]}" -swift-version 6 -parse-as-library \
    -framework AppKit -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework Vision -framework CryptoKit \
    "${SHARED[@]}" "$TEST" -o "$BIN"
  "$BIN"
  rm -f "$BIN"
done