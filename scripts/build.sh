#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
APP="$OUT/Tuck.app"
EXT="$APP/Contents/PlugIns/TuckFinder.appex"
TARGET="$(uname -m)-apple-macos14.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/PlugIns" "$EXT/Contents/MacOS"
cp "$ROOT/Resources/App-Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Extension-Info.plist" "$EXT/Contents/Info.plist"

xcrun swiftc -swift-version 6 -O -sdk "$SDK" -target "$TARGET" \
  -module-name TuckFinder -parse-as-library -application-extension \
  -framework AppKit -framework FinderSync -framework CryptoKit \
  -Xlinker -e -Xlinker _NSExtensionMain \
  "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/Extension/*.swift \
  -o "$EXT/Contents/MacOS/TuckFinder"

xcrun swiftc -swift-version 6 -O -sdk "$SDK" -target "$TARGET" \
  -module-name Tuck -parse-as-library -framework AppKit -framework SwiftUI -framework PDFKit \
  -framework CryptoKit -framework ImageIO -framework UniformTypeIdentifiers \
  "$ROOT"/Sources/Shared/*.swift "$ROOT"/Sources/App/*.swift \
  -o "$APP/Contents/MacOS/Tuck"

codesign --force -s - --entitlements "$ROOT/Resources/Extension.entitlements" "$EXT"
codesign --force -s - "$APP"
echo "Built: $APP"
