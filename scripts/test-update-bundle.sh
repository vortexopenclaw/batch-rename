#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
swiftc -I build -L build -lRenameCore -Xlinker -rpath -Xlinker "$PWD/build" scripts/test-update-bundle.swift -o build/test-update-bundle
build/test-update-bundle
node --test workers/batch-rename/worker.test.mjs
