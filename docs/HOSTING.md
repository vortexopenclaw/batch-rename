# Production update delivery

The Batch Rename app is configured to use:

- Manifest: `https://batch-rename-updates.vortexradar.workers.dev/batch-rename/manifest.json`
- Archive: `https://batch-rename-updates.vortexradar.workers.dev/batch-rename/download`

`Resources/UpdateConfiguration.json` contains the public Ed25519 trust key. The private release key is not in this repository. Never change the trust key in a routine update.

The dedicated `batch-rename-updates` Cloudflare Worker uses `github-updates.mjs` and `wrangler-github.json`. It delivers public GitHub release assets from this repository through stable HTTPS endpoints. It does not need R2 access, a GitHub token, or access to user files. The Worker follows GitHub redirects server-side. The client receives the manifest or archive directly and independently verifies signatures and checksums.

Only the configured release tag is served. Query strings, arbitrary routes, unsafe asset keys, and write methods are rejected. Release archives must be immutable. Publish and verify the new GitHub release assets before advancing `RELEASE_TAG`.

## Release sequence

1. Run the headless tests and package to a separate output if the working app is running.
2. Run `scripts/release-update.py` on the packaged app to generate the restricted ZIP and unsigned manifest.
3. Compile `scripts/sign-update.swift` against the matching core library. Supply the dedicated private key on stdin through the approved protected signing process, never command-line arguments or chat.
4. Verify the signed manifest and ZIP with `scripts/verify-release.swift`.
5. Publish the versioned ZIP and `manifest.json` to the matching GitHub release. Download both and verify their bytes again.
6. Set `RELEASE_TAG` in `workers/batch-rename/wrangler-github.json`, then deploy using existing authorized Cloudflare access.
7. Read back both live endpoints with the app User-Agent. Verify the manifest signature and exact archive checksum using the bundled public configuration.

The initial beta had no update configuration, so it cannot discover this service. It requires one manual installation of a configured build. Future configured builds can discover later signed releases.

## Qualification boundary

Automated tests cover manifest trust, archive parsing, replacement/backup handling, and failure cases. They do not prove the complete graphical quit/install/relaunch behavior on every Mac. Disposable GUI app-copy tests are paused because ad-hoc identity changes caused repeated macOS approval requests. Do not restart that harness without explicit authorization. No quarantine or privacy database bypass is part of this workflow.
