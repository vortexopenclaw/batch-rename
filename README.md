# Batch Rename 0.1.3 (build 4)

A native macOS utility for renaming files and folders locally, with a live preview and durable undo. Requires macOS 14 or later and Apple Silicon.

Add text to the beginning or end, or find and replace literal text. Choose the file name without the extension, the entire file name and extension, or the file extension. No separator is inserted: `clip.mp4` plus ` edited` becomes `clip edited.mp4`. Extension spelling and case are preserved. The suffix guard skips names that already end with the supplied text.

The left sidebar contains text controls and a single horizontal **Process** row: **Files**, **Folders**, and **Subfolders and their contents**, with **Companion files** below it. **Add Files or Folders…** (Cmd+O) and **Clear List** sit above the right preview. Drop files or folders into the window or onto the Dock icon, including at launch; the window highlights while a drop is over it. Dropped items that are not files on disk, such as Photos images, are counted and reported. Repeated additions accumulate, including while a scan is running; duplicate directory entries are removed without merging distinct hardlinks.

The preview contains only Current Name and New Name. Rows stay 25 points high. Click rows, Cmd-click to add individual selections, or Shift-click for a range. Cmd+A selects all while the preview has focus; Delete/Backspace and **Remove from List** remove selected entries only from the preview. Text fields retain their normal editing shortcuts. Full names are available in tooltips and the context menu’s copy commands. Vivid blue highlights mark changes; measured, composed-character-safe text windows reveal the tail for append, head for prepend, and first match for replacement. Horizontal gestures over a cell browse longer names without scrollbar chrome. Completed names return to neutral text. Completion totals count selected entries, including files and folders, rather than internal rename steps. Each row's status (Pending, Completed, Edited, Already ends with this text, or its problem) appears in the tooltip and to VoiceOver; problems and skipped rows use different symbols, and change highlights invert on selected rows so they stay readable.

Files are selected by default. Dropped folders contribute immediate files; folder entries and recursion are separate options. Hidden descendants and package contents are skipped. Explicitly selected hidden items are allowed. Symbolic links can be renamed but are never followed; paths with symbolic-link ancestors are rejected. Volume roots and nested-volume traversal are rejected or skipped.

Completed rows stay visible and cannot be renamed again accidentally. **Clear List** removes only the inventory, preserving text, disk files, and undo history. Removed rows remain excluded across rescans and Process changes until explicitly added again (dropping a folder restores its excluded descendants). Removal preserves text and undo history, including mixed completed and pending selections, and is disabled during rename or installation. The cross beside the text field clears only that text. **Undo Last Batch** (Cmd+Z when no text field is being edited) reverses one batch; its tooltip names the batch. The list stays: undone rows return to their original names and other rows are kept. The local undo journal contains file paths and persists across launches.

Renames never intentionally overwrite an existing entry. The engine checks identities and collisions, uses exclusive filesystem renames, and stops on unexpected errors. Undo refuses occupied destinations or externally changed files. A batch is not an atomic transaction; partial work may require undo. On volumes without exclusive renames, such as exFAT and FAT SD cards, the engine first reserves the new name with an empty placeholder, then renames over it, so an existing file is never replaced. Other unsupported filesystems fail closed.

## Working with clips

- **Per-row problems.** Each row is checked on its own. A row with a problem (for example, a name that already exists) shows it and is skipped; the others can still be renamed. The status line reads, for example, "12 changes ready. 2 have problems."
- **Progress and cancel.** Long batches show "Renaming 412 of 1,000". **Cancel** appears only while renaming and stops after the current item. Quitting during a rename cancels it and quits when safe; quitting during an undo waits for it to finish.
- **Edit one name.** Double-click a New Name cell, press Return with one row selected, or choose **Edit New Name** from the context menu. Return saves, Escape cancels, and an empty name or the automatic name reverts to automatic (also **Use Automatic Name**). Edited rows show a pencil and keep their names through text, option, and filter changes until renamed or the list is cleared. With **Companion files** on, rear, interior, and sidecar clips with the same name and no edit of their own follow the newest edit in their group, including later changes and reverts. **Use Automatic Name** on one of them stops it following.
- **Companion files.** When on, adding a clip also adds rear or interior clips and sidecar files (.LRV, .THM, .SRT, .GPX) that share its name. The setting is remembered.
- **Types.** The **Types** menu lists the file types in the list with counts. Hidden types are not renamed; folders are unaffected. With companion files on, a clip's companions stay visible with it. The header shows, for example, "Showing 120 of 180 items."
- **Tokens.** **Insert** adds a sequence number (1, 01, 001, or 0001), `{date}`, or `{time}`. Numbers follow the displayed order of pending rows and start at the **Start at** value. Date and time come from each file's modified date.
- **Recent text and presets.** The clock menu beside the text field lists the last 10 texts used in successful renames and saved presets (action, scope, text, find text, options, and start number). Presets can be saved and deleted from the same menu.
- **History.** **History…** lists recent batches with their time, item count, examples, and state. **Undo Through This Batch** undoes that batch and every newer one after confirmation. Batches from earlier versions show "Earlier".
- **Shortcuts.** Cmd+Return renames, Cmd+O adds files or folders, Cmd+Z undoes typing in a text field or otherwise the last batch, and Cmd+Shift+Z redoes typing.

## Build and headless checks

Use Xcode with Swift, Python 3, and Node. From the repository root, select an existing writable scratch directory. Scripts resolve it to a physical path and reject system `/tmp` locations.

```sh
export BATCH_RENAME_SCRATCH="$HOME/Developer/BatchRenameScratch"
mkdir -p "$BATCH_RENAME_SCRATCH"
source scripts/env.sh
python3 scripts/release-metadata.py readme
bash scripts/test-direct.sh
python3 scripts/test-release-update.py
node --test workers/batch-rename/*.test.mjs
```

After packaging (below) to `build/Batch Rename.app`, `bash scripts/test-update-bundle.sh` runs the release tools on a copy of the real app with a throwaway signing key: `sign-update`, `verify-release`, archive extraction, and `codesign` validation.

Scratch selection uses `BATCH_RENAME_SCRATCH`, then an optional ignored `.env.scratch` file containing one directory path, then `TMPDIR`. Compiler caches stay in the checkout. Direct XCTest compiles the app model without running the app entry point and exercises real fixture renames and undo.

To package a fresh app without replacing the existing project app:

```sh
BATCH_RENAME_APP_OUTPUT="dist-next-v012/Batch Rename.app" bash scripts/package.sh --direct
```

Output is `dist-next-v012/Batch Rename.app`, ad-hoc signed without Developer ID or notarization. Packaging replaces that output; do not run it against an app currently in use. Headless tests do not establish downloaded-app Gatekeeper behavior or interactive UI acceptance.

## Updates and validation limits

The updater accepts only releases signed by the bundled Ed25519 key, from `https://batch-rename-updates.vortexradar.workers.dev/batch-rename/manifest.json` and `/batch-rename/download`. Startup checks once per launch and stays silent when offline or up to date; manual checks report results. A valid newer release offers **Install and Restart** or **Later** after file operations finish and the rename engine is healthy. The app must run from a writable folder, not App Translocation. Installation blocks new file operations, keeps the previous app as a backup, and after a healthy relaunch keeps only the newest backup. Manifests carry a legacy signature for installed 0.1.x clients and a strict signed envelope with rollback detection for current clients. Live graphical installation, relaunch, and downloaded-app validation remain unqualified. See [updater behavior and limits](docs/UPDATES.md) and the [release runbook](docs/HOSTING.md).

The GUI lifecycle harness is disabled by default. Its `--allow-gui-lifecycle` flag explicitly enables app and installer launches and requires separate interactive authorization. Do not run it during headless testing. Changing app signatures can cause macOS to request file access again.

Further acceptance work includes interactive drops and accessibility, external-media failure cases, exhaustive crash boundaries, and very large inventories or long undo histories. Name previews are computed immediately; filesystem validation runs off the main thread about 100 ms after the last change, and **Rename** stays disabled until it finishes.

## Advisory code review

[Code review setup and pilot results](docs/CODE-REVIEW.md) describe the optional OpenCodeReview delegation workflow. It uses repository-local safety rules and the existing coding agent, without adding an app dependency or changing release gates.

## License

[MIT](LICENSE). The app, engine, tests, and geometric icon are original source and artwork, with no third-party source dependencies.
