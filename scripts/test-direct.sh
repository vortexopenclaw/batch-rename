#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
mkdir -p build
swiftc -parse-as-library -emit-library -emit-module -enable-testing -module-name RenameCore -target arm64-apple-macosx14.0 Sources/RenameCore/*.swift -emit-module-path build/RenameCore.swiftmodule -Xlinker -install_name -Xlinker @rpath/libRenameCore.dylib -o build/libRenameCore.dylib
frameworks=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Frameworks
support=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib
mkdir -p build/CoreTests.xctest/Contents/MacOS
swiftc -D DIRECT_UI_TESTS -emit-library -module-name RenameCoreTests -I "$support" -L "$support" -Xlinker -rpath -Xlinker "$support" -I build -L build -lRenameCore -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$PWD/build" Tests/RenameCoreTests/*.swift Sources/BatchRename/*.swift -o build/CoreTests.xctest/Contents/MacOS/CoreTests
/Applications/Xcode.app/Contents/Developer/usr/bin/xctest build/CoreTests.xctest
