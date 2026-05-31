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

## Installation

Add the package to a Swift Package Manager project:

```swift
// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(
            name: "MacOSUpdater",
            url: "https://github.com/MarlonJD/macos-updater-swift.git",
            branch: "main"
        )
    ],
    targets: [
        .target(
            name: "YourApp",
            dependencies: [
                .product(name: "MacOSUpdaterCore", package: "MacOSUpdater"),
                .product(name: "MacOSUpdaterManifest", package: "MacOSUpdater")
            ]
        )
    ]
)
```

Import only the products needed by each target:

```swift
import MacOSUpdaterCore
import MacOSUpdaterManifest
import MacOSUpdaterRelease
```

## Current Status

This is the bootstrap package. It is ready for manifest modeling, signing,
verification, release-state handling, changelog drafting, distribution-key
planning, and installer dry-run request validation. It does not yet perform a
production app replacement, privileged helper registration, payload download,
payload decompression, or host-app UI integration.

## Command Line Usage

Generate a changelog draft from Conventional Commit subjects:

```sh
cat > commits.txt <<'EOF'
feat(updater): add signed manifest envelope
fix(core): reject stale build numbers
docs: update README
perf(release): sort payload uploads
EOF

swift run macos-updater-release changelog \
  --version 1.4.3 \
  --commits-file commits.txt
```

Preview S3/CloudFront object keys without uploading:

```sh
swift run macos-updater-release plan-keys \
  --channel stable \
  --version 1.4.3 \
  --build 1848 \
  --base-build 1847 \
  --payload-sha256 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
```

Validate an installer dry-run request:

```json
{
  "installedAppPath": "/Applications/emsi_macos.app",
  "stagedAppPath": "/Users/me/Library/Caches/emsi/update/staged.app",
  "backupAppPath": "/Users/me/Library/Caches/emsi/update/backup.app",
  "mainProcessID": 1234,
  "targetBundleIdentifier": "com.radlof.emsi-swift",
  "targetReleaseID": {
    "version": "1.4.3",
    "buildNumber": 1848
  }
}
```

```sh
swift run macos-update-installer --dry-run --request installer-request.json
```

The dry-run command prints the planned transactional steps only. It does not
replace an app bundle.

## Library Usage

Hash data or files with SHA-256:

```swift
import Foundation
import MacOSUpdaterManifest

let dataDigest = SHA256Digest.hex(for: Data("payload".utf8))
let fileDigest = try SHA256Digest.hex(forFileAt: payloadURL)
```

Decode and verify a signed release manifest with a pinned P-256 public key:

```swift
import CryptoKit
import Foundation
import MacOSUpdaterManifest

let manifestData = try Data(contentsOf: releaseManifestURL)
let signedManifest = try ManifestCoding.decoder().decode(
    SignedManifest<ReleaseManifest>.self,
    from: manifestData
)

let publicKey = try P256.Signing.PublicKey(x963Representation: pinnedKeyData)
let verifier = ManifestVerifier(
    publicKeysByID: ["stable-2026": publicKey],
    requiredKeyIDs: ["stable-2026"]
)

try verifier.verify(signedManifest)
let releaseManifest = signedManifest.manifest
```

Check whether a release is eligible for an installed app:

```swift
import MacOSUpdaterCore
import MacOSUpdaterManifest

let policy = UpdateEligibilityPolicy(
    channel: .stable,
    bundleIdentifier: "com.radlof.emsi-swift",
    teamIdentifier: "UPK4SC93AN",
    architecture: .arm64
)

let installedApp = InstalledAppState(
    releaseID: ReleaseID(version: try SemanticVersion("1.4.2"), buildNumber: 1847),
    buildNumber: 1847,
    bundleIdentifier: "com.radlof.emsi-swift",
    teamIdentifier: "UPK4SC93AN",
    platform: .macOS,
    architecture: .arm64
)

let decision = try policy.validate(
    releaseManifest: releaseManifest,
    installedApp: installedApp
)
```

Create a release-state value and validate monotonic build numbers:

```swift
import MacOSUpdaterManifest

let state = DesktopReleaseState(
    lastBuildNumber: 1847,
    lastStableVersion: try SemanticVersion("1.4.2"),
    lastBetaVersion: try SemanticVersion("1.5.0-beta.1")
)

let nextBuild = state.nextBuildNumber()
try state.validateNextBuildNumber(nextBuild)
```

Generate a changelog draft in Swift:

```swift
import MacOSUpdaterManifest
import MacOSUpdaterRelease

let changelog = ChangelogDraftGenerator().generate(
    version: try SemanticVersion("1.4.3"),
    commits: [
        "feat(updater): add signed manifest envelope",
        "fix(core): reject stale build numbers",
        "docs: update README"
    ]
)
```

Build a dry-run distribution plan:

```swift
import MacOSUpdaterManifest
import MacOSUpdaterRelease

let plan = DistributionKeyPlanner(bucketName: "emsi-updates-prod").plan(
    channel: .stable,
    version: try SemanticVersion("1.4.3"),
    buildNumber: 1848,
    baseBuildNumber: 1847,
    payloadSHA256Values: [
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
    ]
)

print(plan.dryRunText())
```

## Host App Responsibilities

The consuming macOS app is responsible for:

- embedding any helper executable;
- configuring signing, hardened runtime, sandboxing, and entitlements;
- pinning update public keys;
- storing updater state and downloaded payloads;
- presenting localized update UI;
- performing final code-signing and Gatekeeper checks before install;
- deciding whether privileged installation support is required.

## Release Workflow

This section describes the intended end-to-end release flow from app changes to
a published update. The current bootstrap package already supports changelog
drafting, release-state modeling, executable builds, and S3/CloudFront key
dry-runs. Full app-bundle diffing, payload compression, manifest generation,
uploading, notarization orchestration, and production installation are planned
follow-up work.

### 1. Start From A Clean Release Branch

Create releases from a clean branch that contains only the changes intended for
the next app update.

```sh
git status --short
git pull --ff-only
swift test
```

For the consuming macOS app, also run the app's release verification commands,
including signing, notarization, and bundle validation checks. This package does
not replace the host app's release pipeline.

### 2. Collect Changes Since The Previous Release

Use Conventional Commit subjects as the input for the release notes draft.

```sh
mkdir -p release

git log <previous-release-tag>..HEAD \
  --pretty=format:'%s' \
  > release/commits-1.4.3+1848.txt
```

Recommended commit types:

- `feat`: user-visible feature
- `fix`: bug fix
- `perf`: performance improvement
- `security`: security fix
- `type!`: breaking change

The default changelog generator includes `feat`, `fix`, `perf`, `security`,
and breaking-change commits. It excludes `docs`, `test`, `chore`, and
`refactor` unless they are marked as breaking changes.

### 3. Choose SemVer And Build Number

Use SemVer for the visible app version and a monotonically increasing build
number for update ordering.

```text
CFBundleShortVersionString = 1.4.3
CFBundleVersion = 1848
releaseID = 1.4.3+1848
```

The local release state file records the last published build and channel
versions:

```text
release/desktop-release-state.json
```

Example:

```json
{
  "lastBuildNumber": 1848,
  "lastStableVersion": "1.4.3",
  "lastBetaVersion": "1.5.0-beta.1"
}
```

This repository includes `release/desktop-release-state.example.json` as the
starter template. Copy it to `release/desktop-release-state.json` in the
release-owning repository when real app releases are prepared.

Update this file only after choosing the release version. Commit it with the
release-preparation change so the next release owner can compute the next build
number from source control.

### 4. Generate A Changelog Draft

Run the release CLI against the collected Conventional Commit subjects:

```sh
swift run macos-updater-release changelog \
  --version 1.4.3 \
  --commits-file release/commits-1.4.3+1848.txt \
  > release/changelog-1.4.3+1848.md
```

Review and edit the draft before publishing. The reviewed text is copied into
the signed `release.json` manifest and into any human-facing release notes.

### 5. Build The Release Executables

Build the package executables in release mode:

```sh
swift build -c release \
  --product macos-updater-release \
  --product macos-update-installer
```

The executable paths are:

```text
.build/release/macos-updater-release
.build/release/macos-update-installer
```

`macos-updater-release` is a local maintainer tool. It is not embedded in the
customer app.

`macos-update-installer` is the helper executable scaffold. The consuming app is
responsible for embedding, signing, entitlements, sandbox behavior, and launch
integration before it is used in production.

### 6. Build, Sign, And Notarize The Host App

In the consuming macOS app repository, build the target `.app` bundle with the
selected version values:

```text
CFBundleShortVersionString = 1.4.3
CFBundleVersion = 1848
```

Then sign and notarize the full target app bundle using the host app's Developer
ID workflow. Before generating update metadata, verify the final bundle:

```sh
codesign --verify --deep --strict --verbose=4 /path/to/emsi_macos.app
spctl -a -t exec -vv /path/to/emsi_macos.app
xcrun stapler validate /path/to/emsi_macos.app
```

Do not generate delta metadata from an unsigned, unstapled, or mutable app
bundle.

### 7. Generate Release Metadata And Payloads

The intended immutable release directory for a published update is:

```text
desktop/macos/<channel>/releases/<releaseID>/
```

For a stable `1.4.3+1848` release:

```text
desktop/macos/stable/releases/1.4.3+1848/
  release.json
  target-file-manifest.json
  delta-from-1847-to-1848.json
  payloads/
    ab/cd/<payload-sha256>.lzfse
```

The target file manifest describes the final signed `.app` bundle. The delta
manifest describes how to transform a verified base build into the target
build. Payload objects contain compressed changed files.

The bootstrap package does not yet generate these files from app bundles. Until
that release generator is implemented, treat the structure above as the
contract that the generator and CDN publisher must satisfy.

### 8. Dry-Run The CDN Keys

Before upload, preview the S3 keys and CloudFront invalidation paths:

```sh
swift run macos-updater-release plan-keys \
  --channel stable \
  --version 1.4.3 \
  --build 1848 \
  --base-build 1847 \
  --payload-sha256 abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789 \
  --bucket emsi-updates-prod
```

The dry-run output shows the safe upload order:

1. payload objects;
2. target file manifest;
3. delta manifest;
4. release manifest;
5. mutable channel pointer.

### 9. Publish In Safe Order

Upload immutable release objects first. Do not update `latest.json` until every
referenced object exists and has the expected SHA-256 hash.

```text
s3://emsi-updates-prod/
  desktop/macos/stable/releases/1.4.3+1848/payloads/...
  desktop/macos/stable/releases/1.4.3+1848/target-file-manifest.json
  desktop/macos/stable/releases/1.4.3+1848/delta-from-1847-to-1848.json
  desktop/macos/stable/releases/1.4.3+1848/release.json
  desktop/macos/stable/latest.json
```

`latest.json` is the only mutable channel pointer. Clients read it to discover
which release is currently published for a channel.

### 10. Record What Was Published

There are three records of the published version:

- `release/desktop-release-state.json` in source control records the last build
  number and channel versions for the next release owner.
- `desktop/macos/<channel>/latest.json` in the update bucket records the
  currently published release for clients.
- `desktop/macos/<channel>/releases/<releaseID>/release.json` in the update
  bucket records the immutable signed metadata for that exact release.

Use a git tag for the source revision that produced the release:

```sh
git tag macos-v1.4.3+1848
git push origin macos-v1.4.3+1848
```

The source-control state, CDN `latest.json`, immutable `release.json`, and git
tag must all point to the same release ID.

### 11. Verify After Publish

After publishing `latest.json`, verify the public CloudFront URLs:

```sh
curl -fsS https://<cloudfront-domain>/desktop/macos/stable/latest.json
curl -fsS https://<cloudfront-domain>/desktop/macos/stable/releases/1.4.3+1848/release.json
```

Then run a canary update against an installed base build. Confirm that the
client requests only the changed payload URLs, stages the target bundle,
verifies hashes and signatures, and refuses the update if any signed manifest or
payload hash is wrong.

### 12. Rollback Or Correction

If release objects were uploaded but `latest.json` was not updated, clients
will not see the partial release. Fix or delete the incomplete immutable release
directory before publishing.

If `latest.json` was updated incorrectly, publish a corrected signed
`latest.json` that points back to the last known-good release or to a signed
rollback release. Do not mutate objects under an existing
`releases/<releaseID>/` directory.

## License

Copyright (C) 2026 Burak Karahan.

Licensed under the GNU Lesser General Public License v3.0 or later
(`LGPL-3.0-or-later`).

## Development

Run the test suite:

```sh
swift test
```
