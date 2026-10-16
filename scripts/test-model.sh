#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHARED=("$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/App/FileWork.swift "$ROOT"/Sources/App/*/*.swift)
for TEST in "$ROOT"/Tests/*.swift; do
  NAME="$(basename "$TEST" .swift)"
  BIN="$(mktemp -t "tuck-$NAME.XXXXXX")"
  trap 'rm -f "$BIN"' EXIT
  swiftc -swift-version 6 -parse-as-library \
    -framework AppKit -framework PDFKit -framework ImageIO -framework UniformTypeIdentifiers -framework Vision -framework CryptoKit \
    "${SHARED[@]}" "$TEST" -o "$BIN"
  "$BIN"
  rm -f "$BIN"
done