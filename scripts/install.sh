#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build.sh" "$ROOT/build"
mkdir -p "$HOME/Applications"
ditto "$ROOT/build/Tuck.app" "$HOME/Applications/Tuck.app"
pluginkit -a "$HOME/Applications/Tuck.app/Contents/PlugIns/TuckFinder.appex"
pluginkit -e use -i dev.raisecaterror.tuck.finder
open -a "$HOME/Applications/Tuck.app"
echo "Installed. Enable Tuck under System Settings → General → Login Items & Extensions → Finder extensions if needed."
