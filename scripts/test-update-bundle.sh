#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
for tool in test-update-bundle sign-update verify-release; do
  swiftc -I build -L build -lRenameCore -Xlinker -rpath -Xlinker "$PWD/build" "scripts/$tool.swift" -o "build/$tool"
done
build/test-update-bundle
node --test workers/batch-rename/worker.test.mjs
