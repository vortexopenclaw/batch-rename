# Release runbook

This is the canonical procedure for shipping a Batch Rename update. Updater behavior and limits are in [UPDATES.md](UPDATES.md).

## Delivery

- Manifest: `https://batch-rename-updates.vortexradar.workers.dev/batch-rename/manifest.json`
- Archive: `https://batch-rename-updates.vortexradar.workers.dev/batch-rename/download`

The `batch-rename-updates` Cloudflare Worker (`workers/batch-rename/github-updates.mjs`, configured by `wrangler-github.json`) serves the `manifest.json` and archive of exactly one GitHub release, pinned by `RELEASE_TAG`. It follows GitHub redirects server-side, rejects query strings, other routes, unsafe asset keys, and write methods, and needs no R2 access, GitHub token, or user data. Clients verify everything themselves.

`Resources/UpdateConfiguration.json` holds the public Ed25519 trust key. Never change it in a routine release: every installed client trusts only that key. The private key exists only as the GitHub repository secret `BATCH_RENAME_ED25519_PRIVATE_KEY` (base64 raw 32-byte seed). Do not retrieve, export, or paste it.

## Compatibility rules

- Installed 0.1.3 and earlier clients verify only the legacy signature over the seven original fields. Every release must keep producing it (`sign-update.swift` does, and `verify-release.swift` requires it).
- Version and build must both increase. Versions are three components without leading zeros. The build is a positive integer and is also the manifest `sequence`.

## Release sequence

1. In one reviewed commit, raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`, update the README title to `# Batch Rename <version> (build <build>)`, and set `RELEASE_TAG` in `workers/batch-rename/wrangler-github.json` to the new tag (`v<version>` or `v<version>-beta`). CI rejects any mismatch.
2. Run the headless checks from the repository root with a physical scratch directory:

   ```sh
   export BATCH_RENAME_SCRATCH="$HOME/Developer/BatchRenameScratch"
   source scripts/env.sh
   python3 scripts/release-metadata.py readme
   bash scripts/test-direct.sh
   bash scripts/package.sh --direct
   bash scripts/test-update-bundle.sh
   python3 scripts/test-release-update.py
   node --test workers/batch-rename/*.test.mjs
   ```

3. Push the commit and a new tag pointing at it. Never move an existing tag.
4. Dispatch `.github/workflows/batch-rename-release.yml` with that tag. Its release job runs in the `batch-rename-release` GitHub environment, on GitHub-hosted `macos-15` Apple Silicon runners. The release job checks out `refs/tags/<tag>`, runs `release-metadata.py tag`, finds the highest other published (non-draft) release with `gh release list --exclude-drafts`, reads that release's `manifest.json` for the previous version and build, packages, signs with the repository secret, and runs `verify-release` against the previous release. It then creates a **draft** release. Its permissions are `contents: write` only, and checkout credentials are not persisted.
5. Download the draft assets into ignored `release-assets/<version>/` and verify them locally against the bundled trust key:

   ```sh
   source scripts/env.sh
   swiftc -I build -L build -lRenameCore -Xlinker -rpath -Xlinker "$PWD/build" \
     scripts/verify-release.swift -o build/verify-release
   build/verify-release release-assets/<version>/manifest.json release-assets/<version>/<archive>.zip \
     --previous-version <published version> --previous-build <published build>
   ```

   `verify-release` checks both signatures, the strict payload, a version and build strictly greater than the previous release, the archive checksum and name, then extracts the ZIP with the client's `UpdateArchive` and runs `UpdateInstaller.validateBundle` (bundle identity, minimum macOS, and `codesign`).
6. Publish the verified draft and read the public assets back. Never replace archive bytes of a published release.
7. Never deploy the Worker with a new `RELEASE_TAG` before that GitHub release is published; until then the feed returns 503. Deploy the Worker with existing authorized Cloudflare access: `wrangler deploy --config workers/batch-rename/wrangler-github.json`. Read both live endpoints back with an app User-Agent, compare the manifest bytes and archive SHA-256 with the release, and verify the signatures.

## Rolling back

Clients never install an older version, and clients that saw a newer manifest reject older ones by sequence. Re-pinning `RELEASE_TAG` to an older release only stops new installs of the bad one. To fix a bad release, ship a newer version and build.

## History

The initial beta had no update configuration, so it cannot discover this service and needs one manual installation of a configured build.

## Qualification boundary

Automated tests cover manifest trust and compatibility, archive parsing, release tooling on the real packaged artifact, replacement and backup handling, cleanup, and failure cases. They do not prove the complete graphical quit, install, and relaunch behavior on every Mac. The disposable GUI lifecycle harness is paused because ad-hoc identity changes caused repeated macOS approval requests. Do not restart it without explicit authorization. No quarantine or privacy database bypass is part of this workflow.
