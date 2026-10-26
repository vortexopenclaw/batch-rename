#!/bin/bash
set -euo pipefail
if [[ "${1:-}" != "--allow-gui-lifecycle" ]]; then
  echo "Refusing GUI/installer launches. Requires --allow-gui-lifecycle and explicit interactive authorization." >&2
  exit 2
fi
export BATCH_RENAME_ALLOW_GUI_LIFECYCLE=1
cd "$(dirname "$0")/.."
source scripts/env.sh
# Build an isolated package; never overwrite the running project app or its dylib.
fixture_build=$(mktemp -d "$TMPDIR/batch-rename-lifecycle-build-XXXXXXXX")
export BATCH_RENAME_LIFECYCLE_APP="$fixture_build/Batch Rename.app"
mkdir -p "$BATCH_RENAME_LIFECYCLE_APP/Contents/MacOS" "$BATCH_RENAME_LIFECYCLE_APP/Contents/Frameworks" "$BATCH_RENAME_LIFECYCLE_APP/Contents/Resources"
swiftc -parse-as-library -emit-library -emit-module -module-name RenameCore -target arm64-apple-macosx14.0 -O Sources/RenameCore/*.swift -emit-module-path "$fixture_build/RenameCore.swiftmodule" -Xlinker -install_name -Xlinker @rpath/libRenameCore.dylib -o "$fixture_build/libRenameCore.dylib"
swiftc -parse-as-library -target arm64-apple-macosx14.0 -O -I "$fixture_build" -L "$fixture_build" -lRenameCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks Sources/BatchRename/*.swift -o "$BATCH_RENAME_LIFECYCLE_APP/Contents/MacOS/BatchRename"
cp "$fixture_build/libRenameCore.dylib" "$BATCH_RENAME_LIFECYCLE_APP/Contents/Frameworks/"
cp Resources/Info.plist "$BATCH_RENAME_LIFECYCLE_APP/Contents/Info.plist"
swiftc -I "$fixture_build" -L "$fixture_build" -lRenameCore -Xlinker -rpath -Xlinker "$fixture_build" scripts/test-update-lifecycle.swift -o "$fixture_build/test-update-lifecycle"
"$fixture_build/test-update-lifecycle"
