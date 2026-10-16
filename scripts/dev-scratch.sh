#!/bin/bash
# Source from local development scripts; never from application runtime.
# GitHub Actions uses its own disposable runner storage.
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then return 0; fi
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Tuck's native build requires macOS." >&2
  return 2
fi
tuck_mount_is_active() {
  /sbin/mount | /usr/bin/grep -Fq " on $1 ("
}
tuck_volume=""
if [[ -n "${TUCK_SCRATCH_VOLUME:-}" ]]; then
  case "$TUCK_SCRATCH_VOLUME" in /Volumes/*) ;; *)
    echo "TUCK_SCRATCH_VOLUME must be a mounted /Volumes path." >&2; return 2 ;;
  esac
  if tuck_mount_is_active "$TUCK_SCRATCH_VOLUME"; then
    tuck_volume="$TUCK_SCRATCH_VOLUME"
  else
    echo "Requested Tuck scratch volume is not mounted: $TUCK_SCRATCH_VOLUME" >&2
    return 2
  fi
else
  for volume in /Volumes/T7Tmp /Volumes/T7Projects; do
    if tuck_mount_is_active "$volume"; then tuck_volume="$volume"; break; fi
  done
fi
if [[ -z "$tuck_volume" ]]; then
  echo "No verified T7 scratch mount. Mount T7Tmp/T7Projects or set TUCK_SCRATCH_VOLUME; refusing internal fallback." >&2
  return 2
fi
export TUCK_SCRATCH_ROOT="${tuck_volume}/ai-dev/tuck"
export TUCK_SWIFT_MODULE_CACHE="${TUCK_SCRATCH_ROOT}/swift-module-cache"
export CLANG_MODULE_CACHE_PATH="${TUCK_SCRATCH_ROOT}/clang-module-cache"
export TMPDIR="${TUCK_SCRATCH_ROOT}/tmp/"
/bin/mkdir -p "$TMPDIR" "$TUCK_SWIFT_MODULE_CACHE" "$CLANG_MODULE_CACHE_PATH" || return 2
if ! tuck_mount_is_active "$tuck_volume"; then
  echo "Scratch volume disconnected while preparing work directories." >&2
  return 2
fi
