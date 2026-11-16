# Bug-fix verification

This local, unreleased pass repairs the initial advisory-review finding and additional defects confirmed by isolated headless reproductions. The pre-existing removal of a UI explanatory label is preserved.

## Repairs

- **Removed explicit roots:** Removing a row removes corresponding explicit inventory roots, including alternate-case aliases. A later external deletion no longer poisons fresh drops. Clear List remains usable when a failed scan leaves no rows.
- **Partial undo:** If undo restores an ancestor and then rejects a modified child, the model discards stale inventory paths while preserving text, queued additions, and remaining undo history. Fresh drops continue to work.
- **Undo-storage protection:** The engine preflights the entire batch and rejects sources or destinations that move its journal, lock, or containing directories before any batch entry is renamed. Comparisons are conservatively case/Unicode folded and resolve filesystem aliases. This does not remove the documented hostile namespace race around filesystem syscalls.
- **Directory-entry aliases:** Inventory deduplication uses parent identity and the filesystem-reported entry name, not a guessed case-folding policy or inode alone. Alternate-case selections merge while distinct hardlinks and symlinks remain separate.
- **Minimum macOS:** Release generation derives and normalizes the minimum from packaged `LSMinimumSystemVersion`. Missing or malformed values fail before archiving. Candidate bundle validation rejects disagreement with the authenticated manifest before codesign or replacement. Existing OS policy checks remain in place.
- **Malformed Worker manifests:** Both delivery implementations reject null, scalar, array, and wrong-type metadata with controlled failures before archive access.
- **Legacy publisher collision:** New archives have full SHA-256 content-addressed names. The legacy R2 publisher snapshots local inputs and refuses to create unaddressed keys. Competing supported publishers cannot put different bytes at one content-addressed key. Existing legacy archives can still be verified and reused. This is not a storage-level write-once guarantee against out-of-band credential holders. Production delivery remains GitHub-backed.

## Executed checks

Use an existing dedicated writable scratch directory outside system `/tmp`, then run from the repository root:

```sh
export BATCH_RENAME_SCRATCH="$HOME/Developer/BatchRenameScratch"
source scripts/env.sh
bash scripts/test-direct.sh
python3 scripts/test-publish-update.py
python3 scripts/test-release-update.py
python3 scripts/test-review-rules.py
bash scripts/test-update-bundle.sh
node --test workers/batch-rename/github-updates.test.mjs
git diff --check
```

Observed final results:

- Native XCTest: **53 executed, 1 skipped, 0 failures**. The skipped check requires a case-sensitive filesystem, unavailable in the selected scratch volume. The case-insensitive alias and distinct-hardlink regressions executed successfully.
- Publisher: **10 passed**, including an interleaved competing-publication regression and fail-closed missing legacy key.
- Release metadata: **2 passed**, with normalization, invalid/missing minimums, archive digest, and content-addressed filename assertions.
- OCR rule integration: **5 passed**, including missing-include and disabled-merge negative controls.
- Workers: **9 passed** across both delivery implementations.
- Update bundle roundtrip: **passed**, using an ephemeral test key and disposable fixture bundle for release generation, extraction, ad-hoc codesign, and identity validation.
- `git diff --check`: clean.

The new core/model regressions failed against the old implementations before their fixes. Worker and release-metadata regressions also failed before the corresponding fixes. The competing-publisher and missing-unaddressed-key tests failed before publisher hardening.

An independent final review consumed actual OCR preview and resolved rules for all **20 selected changed paths**, including full untracked files: **20 reviewed, 0 skipped, 0 excluded**. It found no confirmed introduced blockers. It independently exercised the core/model and new bundle-minimum cases in a scratch native build, reran Python and Worker tests, and verified normal, dangling, and self-referential symlink rename/undo alongside case aliases and distinct hardlinks.

## Boundaries

This verification was performed before publication. No application installation, GUI lifecycle, Gatekeeper acceptance, live Worker deployment, production signing, release publication, or user-file mutation was part of the bug-fix verification pass. Release publication is a separate maintainer-authorized step. Tests and review are finite evidence, not proof of complete filesystem or crash safety. The GUI behavior of the now-enabled empty-list Clear List control has not been interactively exercised.
