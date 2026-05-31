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

## License

Copyright (C) 2026 Burak Karahan.

Licensed under the GNU Lesser General Public License v3.0 or later
(`LGPL-3.0-or-later`).

## Development

Run the test suite:

```sh
swift test
```
