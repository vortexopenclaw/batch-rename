#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p build
if [[ "${1:-}" == "--direct" ]]; then
  swiftc -parse-as-library -emit-library -emit-module -enable-testing -module-name RenameCore -target arm64-apple-macosx14.0 -O Sources/RenameCore/*.swift -emit-module-path build/RenameCore.swiftmodule -Xlinker -install_name -Xlinker @rpath/libRenameCore.dylib -o build/libRenameCore.dylib
  swiftc -parse-as-library -target arm64-apple-macosx14.0 -O -I build -L build -lRenameCore -Xlinker -rpath -Xlinker @executable_path/../Frameworks Sources/BatchRename/*.swift -o build/BatchRename
  binary=build/BatchRename
else
  swift build --build-system native --scratch-path .build-native --cache-path .build-native/cache -c release --arch arm64
  binary=.build-native/arm64-apple-macosx/release/BatchRename
fi
app="${BATCH_RENAME_APP_OUTPUT:-build/Batch Rename.app}"
# Never replace the executable of a running GUI app.
python3 - "$app" <<'PY'
import pathlib, subprocess, sys
executable = str(pathlib.Path(sys.argv[1]).resolve() / 'Contents/MacOS/BatchRename')
commands = subprocess.run(['ps', '-axo', 'command='], check=True, capture_output=True, text=True).stdout.splitlines()
if any(command.strip() == executable or command.strip().startswith(executable + ' ') for command in commands):
    raise SystemExit('Packaging refused: this app is running. Close it or select a different BATCH_RENAME_APP_OUTPUT.')
PY
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary" "$app/Contents/MacOS/BatchRename"
if [[ "${1:-}" == "--direct" ]]; then cp build/libRenameCore.dylib "$app/Contents/Frameworks/"; fi
swift scripts/Icon.swift build/Icon.png
mkdir -p build/Icon.iconset
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" build/Icon.png --out "build/Icon.iconset/icon_${size}x${size}.png" >/dev/null
  twice=$((size * 2))
  sips -z "$twice" "$twice" build/Icon.png --out "build/Icon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
python3 scripts/make-icns.py "$app/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$app/Contents/Info.plist"
if [[ -f Resources/UpdateConfiguration.json ]]; then
  cp Resources/UpdateConfiguration.json "$app/Contents/Resources/UpdateConfiguration.json"
elif [[ -f "$app/Contents/Resources/UpdateConfiguration.json" ]]; then
  rm "$app/Contents/Resources/UpdateConfiguration.json"
fi
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"
file "$app/Contents/MacOS/BatchRename"
