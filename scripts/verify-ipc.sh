#!/bin/bash
# Sends one authenticated request to the installed helper through the same
# tuck://perform URL the Finder extension uses, against a disposable directory.
# Usage: scripts/verify-ipc.sh [operation] [argument]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPERATION="${1:-newFile}"
ARGUMENT="${2:-Untitled.txt}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tuck-ipc.XXXXXX")"
BIN="$(mktemp -t tuck-ipc-probe.XXXXXX)"
trap 'rm -rf "$WORK"; rm -f "$BIN"' EXIT

swiftc -swift-version 6 -framework AppKit -framework CryptoKit \
  "$ROOT"/Sources/Shared/*.swift "$ROOT/scripts/IPCProbe.swift" -o "$BIN"
"$BIN" "$WORK" "$OPERATION" "$ARGUMENT"

for _ in $(seq 1 20); do
  if [ "$(ls -A "$WORK" | wc -l | tr -d ' ')" -gt 1 ]; then break; fi
  sleep 1
done

echo "--- $WORK ---"
ls -la "$WORK"