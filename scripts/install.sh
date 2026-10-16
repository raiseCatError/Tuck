#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$ROOT/scripts/build.sh" "$ROOT/build"
mkdir -p "$HOME/Applications"
# The build output can register itself and then compete for the tuck: scheme.
"$LSREGISTER" -u "$ROOT/build/Tuck.app" >/dev/null 2>&1 || true
ditto "$ROOT/build/Tuck.app" "$HOME/Applications/Tuck.app"
"$LSREGISTER" -u "$HOME/Applications/Tuck.app" >/dev/null 2>&1 || true
pluginkit -a "$HOME/Applications/Tuck.app/Contents/PlugIns/TuckFinder.appex"
pluginkit -e use -i dev.raisecaterror.tuck.finder
open -a "$HOME/Applications/Tuck.app"
echo "Installed. Enable Tuck under System Settings → General → Login Items & Extensions → Finder extensions if needed."
echo "Watch the action lifecycle with:"
echo "  log stream --level info --predicate 'subsystem == \"dev.raisecaterror.tuck\"'"