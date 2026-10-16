#!/bin/bash
set -euo pipefail
pluginkit -e ignore -i dev.raisecaterror.tuck.finder || true
rm -rf "$HOME/Applications/Tuck.app"
echo "Tuck was removed. Preferences remain in your user defaults."
