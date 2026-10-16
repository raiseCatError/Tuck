#!/bin/bash
# Read-only diagnostic for physical Finder QA; doesn't change OS settings.
set -euo pipefail

APP="${1:-$HOME/Applications/Tuck.app}"
EXT="$APP/Contents/PlugIns/TuckFinder.appex"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Tuck Finder verification requires macOS." >&2
  exit 2
fi
if [[ ! -d "$APP" || ! -d "$EXT" ]]; then
  echo "Installed Tuck app or Finder extension missing: $APP" >&2
  exit 1
fi

echo "macOS: $(sw_vers -productVersion)"
echo "Application: $APP"
echo "App bundle ID: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")"
echo "Extension bundle ID: $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$EXT/Contents/Info.plist")"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$EXT"
echo "Code signatures verified."

echo
echo "Finder Sync registration (inspect enablement in System Settings):"
/usr/bin/pluginkit -m -A -D -i dev.raisecaterror.tuck.finder || true

echo
echo "This script cannot inspect a live Finder right-click menu."
echo "Complete docs/finder-qa.md manually before closing issue #3."
