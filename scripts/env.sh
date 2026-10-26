#!/bin/bash
# Source from the project root. Keep compiler caches local and fixtures physical.
if [[ -n "${BATCH_RENAME_SCRATCH:-}" ]]; then
  batch_scratch="$BATCH_RENAME_SCRATCH"
elif [[ -f .env.scratch ]]; then
  IFS= read -r batch_scratch < .env.scratch
else
  batch_scratch="${TMPDIR:?Set BATCH_RENAME_SCRATCH or TMPDIR to an existing scratch directory}"
fi
batch_scratch=$(cd "$batch_scratch" && pwd -P) || return 1
case "$batch_scratch" in
  /|/tmp|/tmp/*|/private/tmp|/private/tmp/*)
    echo "Use a dedicated physical scratch directory outside system /tmp" >&2
    return 1 ;;
esac
export TMPDIR="$batch_scratch"
export BATCH_RENAME_SCRATCH="$batch_scratch"
export CLANG_MODULE_CACHE_PATH="$PWD/.build-native/modules"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build-native/modules"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
unset batch_scratch
