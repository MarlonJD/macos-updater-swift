# MacOSUpdater

`MacOSUpdater` is the initial Swift Package Manager foundation for the
`MarlonJD/macos-updater-swift` repository. It provides reusable manifest,
release-tooling, and installer-planning primitives for a native macOS updater
without Sparkle or third-party updater frameworks.

## Products

- `MacOSUpdaterManifest`: signed manifest models, P-256 ECDSA manifest signing
  and verification helpers, SHA-256 hashing, compressed payload metadata, and
  SemVer/build-number release state models.
- `MacOSUpdaterRelease`: release-side helpers for Conventional Commits
  changelog drafts and S3/CloudFront key planning with dry-run output.
- `MacOSUpdaterCore`: client-side policy and installer dry-run planning
  primitives that remain independent of the host app.
- `macos-updater-release`: local release utility for changelog drafts and
  distribution key dry-runs.
- `macos-update-installer`: helper executable scaffold that validates and
  prints installer dry-run plans.

## Scope

This package intentionally excludes host-app signing, entitlements, embedding,
privileged helper registration, and UI integration. The consuming macOS app owns
those concerns. The package also does not adopt Sparkle or any third-party
updater framework.

## License

Copyright (C) 2026 Burak Karahan.

Licensed under the GNU Lesser General Public License v3.0 or later
(`LGPL-3.0-or-later`).

## Development

Run the test suite:

```sh
swift test
```

Generate a changelog draft from Conventional Commit subjects:

```sh
swift run macos-updater-release changelog --version 1.4.3 --commits-file commits.txt
```

Preview S3/CloudFront object keys without uploading:

```sh
swift run macos-updater-release plan-keys --channel stable --version 1.4.3 --build 1848 --base-build 1847 --payload-sha256 abcd...
```
