// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MacOSUpdater",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "MacOSUpdaterCore",
            targets: ["MacOSUpdaterCore"]
        ),
        .library(
            name: "MacOSUpdaterManifest",
            targets: ["MacOSUpdaterManifest"]
        ),
        .library(
            name: "MacOSUpdaterRelease",
            targets: ["MacOSUpdaterRelease"]
        ),
        .executable(
            name: "macos-updater-release",
            targets: ["MacOSUpdaterReleaseCLI"]
        ),
        .executable(
            name: "macos-update-installer",
            targets: ["MacOSUpdateInstallerCLI"]
        )
    ],
    targets: [
        .target(
            name: "MacOSUpdaterManifest"
        ),
        .target(
            name: "MacOSUpdaterCore",
            dependencies: ["MacOSUpdaterManifest"]
        ),
        .target(
            name: "MacOSUpdaterRelease",
            dependencies: ["MacOSUpdaterManifest"]
        ),
        .executableTarget(
            name: "MacOSUpdaterReleaseCLI",
            dependencies: [
                "MacOSUpdaterManifest",
                "MacOSUpdaterRelease"
            ]
        ),
        .executableTarget(
            name: "MacOSUpdateInstallerCLI",
            dependencies: [
                "MacOSUpdaterCore",
                "MacOSUpdaterManifest"
            ]
        ),
        .testTarget(
            name: "MacOSUpdaterManifestTests",
            dependencies: ["MacOSUpdaterManifest"]
        ),
        .testTarget(
            name: "MacOSUpdaterCoreTests",
            dependencies: [
                "MacOSUpdaterCore",
                "MacOSUpdaterManifest"
            ]
        ),
        .testTarget(
            name: "MacOSUpdaterReleaseTests",
            dependencies: [
                "MacOSUpdaterManifest",
                "MacOSUpdaterRelease"
            ],
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
