#!/bin/bash
# Builds and runs the compression engine against fixtures.
# Usage: scripts/compress-probe.sh <targetMB> <file> [file...]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TUCK_SCRATCH:-$HOME/Library/Caches/Tuck}/build"
mkdir -p "$OUT"
BIN="$OUT/compress-probe"
swiftc -swift-version 6 -parse-as-library -O \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework ImageIO \
  -framework UniformTypeIdentifiers -framework CryptoKit \
  "$ROOT"/Sources/Shared/*.swift \
  "$ROOT"/Sources/App/FileWork.swift "$ROOT"/Sources/App/SettingsView.swift \
  "$ROOT"/Sources/App/Compression/*.swift \
  "$ROOT/scripts/CompressProbe.swift" -o "$BIN"
exec "$BIN" "$@"