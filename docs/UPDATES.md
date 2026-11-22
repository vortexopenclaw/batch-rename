# Batch Rename updates

This document describes how the in-app updater behaves today and where its guarantees stop. The release procedure is in [HOSTING.md](HOSTING.md).

Batch Rename is ad-hoc signed (no Developer ID, no notarization). Update authenticity comes only from an Ed25519 public key bundled in `Resources/UpdateConfiguration.json`. The Worker and GitHub never supply a trust key, and routine releases never change it.

## Checking

The app checks once per launch, silently: offline, current-version, and error results show nothing. **Check for Updates** reports every result. Requests go only to the two configured HTTPS endpoints, without redirects, cookies, or a persistent URL cache. They send `User-Agent: BatchRename/<version> (<build>) CFNetwork/Darwin`, built from the running bundle, and JSON/ZIP `Accept` headers. The manifest is capped at 64 KiB.

## Manifest format

One `manifest.json` carries two Ed25519 signatures made with the same release key:

```json
{
  "assetKey": "batch-rename/releases/batch-rename-0_1_4-5-<sha256>.zip",
  "build": "5",
  "bundleIdentifier": "com.vortexopenclaw.batch-rename",
  "downloadURL": "https://batch-rename-updates.vortexradar.workers.dev/batch-rename/download",
  "envelope": {
    "payload": "<base64 of the raw payload JSON bytes>",
    "signature": "<base64 Ed25519 signature over exactly those bytes>"
  },
  "minimumMacOS": "14.0.0",
  "sha256": "<64 lowercase hex>",
  "signature": "<base64 legacy Ed25519 signature>",
  "version": "0.1.4"
}
```

The decoded payload (schema 1) is:

```json
{"assetKey":"batch-rename/releases/batch-rename-0_1_4-5-<sha256>.zip","build":"5","bundleIdentifier":"com.vortexopenclaw.batch-rename","downloadURL":"https://batch-rename-updates.vortexradar.workers.dev/batch-rename/download","issuedAt":"2026-11-22T15:18:12Z","minimumMacOS":"14.0.0","schema":1,"sequence":5,"sha256":"<sha256>","version":"0.1.4"}
```

- **Legacy signature (`signature`).** Covers the seven top-level fields (`assetKey`, `build`, `bundleIdentifier`, `downloadURL`, `minimumMacOS`, `sha256`, `version`) re-encoded as Swift sorted-key JSON without escaped slashes. Installed 0.1.3 and earlier clients verify only this and ignore unknown keys such as `envelope`. Its byte encoding is frozen: changing it would strand every installed client. A copy of the 0.1.3 verifier in `Tests/RenameCoreTests/UpdateTests.swift` guards this.
- **Envelope (`envelope`).** Current clients require it. They verify the signature over the raw payload bytes before parsing, then decode strictly: unknown or missing keys, a `schema` other than 1, a malformed ISO 8601 `issuedAt`, or a `sequence` that is not the integer build are rejected. Every top-level legacy field must equal its payload value.
- **Rollback detection.** `sequence` equals the build number. Clients store the highest accepted sequence in user defaults (`UpdateHighestAcceptedSequence`) and reject a lower one as "older than an update already seen". Version checks separately require a strictly newer three-component version (no leading zeros) for installation.
- **No expiry.** `issuedAt` is informational. A hard expiry would force periodic re-releases of a personal app just to keep the feed valid, so none is enforced. Consequently a network attacker who controls delivery can keep serving the latest manifest a client has already seen (a freeze), but cannot serve an older one to a client that has seen a newer one, or forge a newer one.

`scripts/sign-update.swift` produces both signatures. `scripts/verify-release.swift` checks both.

## Download and staging

After the user chooses **Install and Restart**, and before anything is downloaded, the app refuses to continue if it runs from App Translocation, through a symbolic link, or from a folder (or bundle) it cannot write. Move it to a writable folder such as `/Applications` first.

The archive streams into `release.zip` (mode 0600) inside a new private (0700) `.batch-rename-update-<UUID>` directory beside the app. It is hashed while it is written, so memory use stays bounded. The download is capped at 256 MiB, with 30 second request and 180 second resource timeouts. The digest must equal the signed SHA-256. The app then extracts a scratch copy, validates the bundle, and deletes the scratch copy. If anything fails before the install helper starts, the whole transaction directory is removed.

Archives must be produced by `scripts/release-update.py`. The reader accepts only stored ZIP entries with matching central and local records and regular-file or directory Unix modes. It rejects links, traversal, absolute paths, empty or dot components, colons, backslashes, NULs, case- or Unicode-equivalent duplicate paths, encryption, compression, data descriptors, ZIP64, and extra fields. It validates the whole index before writing into a new private directory, and never uses `unzip` or `ditto`. The signed SHA-256 provides integrity; ZIP CRCs are not used for authentication.

## Installation

The helper is a mode of the already installed executable, started before the app quits. There is no launcher app, shell interpolation, privilege elevation, or quarantine stripping. The helper revalidates the manifest (including the sequence) and archive, extracts the authenticated bytes again, checks exact bundle ID, version, build, executable name, minimum macOS, and `codesign --verify --deep --strict`, then waits up to 60 seconds for the app to exit. Exclusive renames move the original to `previous.app` in the transaction directory and the candidate to the original path. If the move fails, the original is restored. If launching fails, the candidate is kept as `failed-<UUID>.app` and the original is restored. An occupied destination is never overwritten.

## Acknowledgment and cleanup

The new app acknowledges only after its window appears, the undo journal opens, the bundle identity and code signature pass, and the transaction token matches. The helper waits 60 seconds for that.

On every healthy launch the app:

- clears a recovery notice whose transaction it is the acknowledged result of (for example, a slow startup that acknowledged after the helper gave up),
- keeps the acknowledged transaction with the highest manifest build, plus any whose manifest version and build match the running app (its `previous.app` is the only rollback), ordering by build number rather than file dates so clock skew cannot pick the wrong one,
- removes only `release.zip` and the `install` and `stage` directories from kept transactions; `previous.app`, `plan.json`, `healthy`, and small records such as `ready`, `original-code.sha256`, `original-info.plist`, and any `failed-*` or `restore-*` copies stay, and
- deletes the other acknowledged transactions for this app.

Transactions that are unacknowledged, hold `NEEDS-RECOVERY.txt`, belong to another app path, or cannot be read are never deleted.

## Recovery

If startup is not acknowledged, the helper writes `NEEDS-RECOVERY.txt` and keeps both apps rather than racing a possibly running new app. Each launch shows the notice with **Show in Finder** and **Dismiss**. Dismiss removes only the notice; backups and recovery files stay. To recover manually, quit every Batch Rename window, then move `previous.app` from the named transaction directory back to the original, unoccupied path.

## Limits

Not established by automated tests: Gatekeeper approval of a downloaded unsigned app, real App Translocation, the graphical quit, relaunch, and acknowledgment sequence, a live HTTPS Worker, the protected GitHub release job, and power loss or process death during the two exclusive renames. Same-user modification of the installation folder between checks and system calls is outside the guarantee; this is not a privileged installer. Rollback detection is per Mac and starts only after a manifest has been accepted there.

The GUI lifecycle harness (`scripts/test-update-lifecycle.sh`) launches apps and installers. It refuses to run without `--allow-gui-lifecycle` and needs separate interactive authorization; it is not part of headless testing.
