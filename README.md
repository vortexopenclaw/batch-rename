# Batch Rename 0.1.1

A native macOS utility for renaming files and folders locally, with a live preview and durable undo. Requires macOS 14 or later and Apple Silicon.

Add text to the beginning or end, or find and replace literal text. Choose the file name without the extension, the entire file name and extension, or the file extension. No separator is inserted: `clip.mp4` plus ` edited` becomes `clip edited.mp4`. Extension spelling and case are preserved. The suffix guard skips names that already end with the supplied text.

The left sidebar contains text controls and a single horizontal **Process** row: **Files**, **Folders**, and **Subfolders and their contents**. **Add Files or Folders…** and **Clear List** sit above the right preview. Drop files or folders into the preview or onto the Dock icon. Repeated additions accumulate, including while a scan is running; duplicate directory entries are removed without merging distinct hardlinks.

The preview contains only Current Name and New Name. Both use blue change highlights and selectable, copyable native text with full-name tooltips and horizontal scrolling to the affected segment. Completed names return to neutral text. Completion totals count selected entries, including files and folders, rather than internal rename steps.

Files are selected by default. Dropped folders contribute immediate files; folder entries and recursion are separate options. Hidden descendants and package contents are skipped. Explicitly selected hidden items are allowed. Symbolic links can be renamed but are never followed; paths with symbolic-link ancestors are rejected. Volume roots and nested-volume traversal are rejected or skipped.

Completed rows stay visible and cannot be renamed again accidentally. **Clear List** removes only the inventory, preserving text, disk files, and undo history. The cross beside the text field clears only that text. **Undo Last Batch** reverses one batch and clears the visible list. The local undo journal contains file paths and persists across launches.

Renames never intentionally overwrite an existing entry. The engine checks identities and collisions, uses exclusive filesystem renames, and stops on unexpected errors. Undo refuses occupied destinations or externally changed files. A batch is not an atomic transaction; partial work may require undo. Unsupported filesystems fail closed.

## Build and headless checks

Use Xcode with Swift, Python 3, and Node. From the repository root, select an existing writable scratch directory. Scripts resolve it to a physical path and reject system `/tmp` locations.

```sh
export BATCH_RENAME_SCRATCH="$HOME/Developer/BatchRenameScratch"
mkdir -p "$BATCH_RENAME_SCRATCH"
source scripts/env.sh
bash scripts/test-direct.sh
python3 scripts/test-publish-update.py
node --test workers/batch-rename/worker.test.mjs
```

Scratch selection uses `BATCH_RENAME_SCRATCH`, then an optional ignored `.env.scratch` file containing one directory path, then `TMPDIR`. Compiler caches stay in the checkout. Direct XCTest compiles the app model without running the app entry point and exercises real fixture renames and undo.

To package a fresh app without replacing the existing project app:

```sh
BATCH_RENAME_APP_OUTPUT="dist-next/Batch Rename.app" bash scripts/package.sh --direct
```

Output is `dist-next/Batch Rename.app`, ad-hoc signed without Developer ID or notarization. Packaging replaces that output; do not run it against an app currently in use. Headless tests do not establish downloaded-app Gatekeeper behavior or interactive UI acceptance.

## Updates and validation limits

The updater implements authenticated manifests, archive validation, staged installation and recovery. The parent-managed public configuration is bundled unchanged. The service will be enabled at `https://batch-rename-updates.vortexradar.workers.dev/batch-rename/manifest.json` and `/batch-rename/download`. Startup checks once per launch and stays silent when offline or up to date; manual checks report results. A valid newer release offers **Install and Restart** or **Later** after file operations finish and the rename engine is healthy. Installation blocks new file operations. Live graphical installation, relaunch and downloaded-app validation remain unqualified. See [update setup and recovery](docs/UPDATES.md).

The GUI lifecycle harness is disabled by default. Its `--allow-gui-lifecycle` flag explicitly enables app and installer launches and requires separate interactive authorization. Do not run it during headless testing. Changing app signatures can cause macOS to request file access again.

Further acceptance work includes interactive drops and accessibility, external-media failure cases, exhaustive crash boundaries, and very large inventories or long undo histories. Preview validation currently runs on the main actor.

## License

[MIT](LICENSE). The app, engine, tests, and geometric icon are original source and artwork, with no third-party source dependencies.
