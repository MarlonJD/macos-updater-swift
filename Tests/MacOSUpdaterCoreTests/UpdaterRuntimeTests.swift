// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import XCTest
@testable import MacOSUpdaterCore
@testable import MacOSUpdaterManifest
@testable import MacOSUpdaterRelease

final class UpdaterRuntimeTests: XCTestCase {
    func testStagesCompressedDeltaAndVerifiesStagedApp() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseApp = root.appendingPathComponent("Base.app")
        let targetApp = root.appendingPathComponent("Target.app")
        try makeAppBundle(at: baseApp, marker: "old", codeResources: "signature-old")
        try makeAppBundle(at: targetApp, marker: "new", codeResources: "signature-new")

        let manifestGenerator = BundleManifestGenerator()
        let baseManifest = try manifestGenerator.makeTargetManifest(
            appBundleURL: baseApp,
            metadata: metadata(version: "1.4.2", build: 1847)
        )
        let targetManifest = try manifestGenerator.makeTargetManifest(
            appBundleURL: targetApp,
            metadata: metadata(version: "1.4.3", build: 1848)
        )
        let releasePrefix = "desktop/macos/stable/releases/1.4.3+1848"
        let generated = try DeltaManifestGenerator().makeDelta(
            baseManifest: baseManifest,
            targetManifest: targetManifest,
            targetAppURL: targetApp,
            releasePrefix: releasePrefix
        )
        let assetsRoot = root.appendingPathComponent("assets")
        try DeltaManifestGenerator().writePayloads(generated.payloads, to: assetsRoot)

        let verifier = RecordingStagedBundleVerifier()
        let core = UpdaterCore(
            policy: policy(),
            assetFetcher: URLSessionUpdateAssetFetcher(),
            bundleVerifier: verifier,
            stateStore: UpdateDownloadStateStore(stateURL: root.appendingPathComponent("state.json"))
        )

        let stagedApp = try await core.stageDelta(
            deltaManifest: generated.manifest,
            targetManifest: targetManifest,
            baseAppURL: baseApp,
            assetLocator: UpdateAssetLocator(baseURL: assetsRoot),
            stagingDirectory: root.appendingPathComponent("staging")
        )

        XCTAssertEqual(
            try String(contentsOf: stagedApp.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8),
            "new"
        )
        XCTAssertEqual(verifier.verifiedURLs.map(\.lastPathComponent), ["1848-staged.app"])
        XCTAssertEqual(verifier.contexts.first?.expectedTeamIdentifier, "UPK4SC93AN")
    }

    func testFullArchiveFallbackUsesSameVerifierGate() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let targetApp = root.appendingPathComponent("Target.app")
        try makeAppBundle(at: targetApp, marker: "new", codeResources: "signature-new")
        let targetManifest = try BundleManifestGenerator().makeTargetManifest(
            appBundleURL: targetApp,
            metadata: metadata(version: "1.4.3", build: 1848)
        )
        let archiveData = Data("not-a-real-zip-fixture".utf8)
        let archiveSHA = SHA256Digest.hex(for: archiveData)
        let archiveKey = "desktop/macos/stable/releases/1.4.3+1848/archives/\(archiveSHA).zip"
        let assetsRoot = root.appendingPathComponent("assets")
        let archiveURL = assetsRoot.appendingPathComponent(archiveKey)
        try FileManager.default.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archiveData.write(to: archiveURL)

        let version = try SemanticVersion("1.4.3")
        let releaseManifest = ReleaseManifest(
            releaseID: ReleaseID(version: version, buildNumber: 1848),
            version: version,
            buildNumber: 1848,
            channel: .stable,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            platform: .macOS,
            architectures: [.universal],
            minimumSystemVersion: "13.0",
            minimumSupportedBuild: 1847,
            commitSHA: "abcdef",
            changelog: "## 1.4.3",
            targetFileManifestSHA256: String(repeating: "a", count: 64),
            deltaManifestSHA256ByBaseBuild: [:],
            fullArchive: FullArchiveMetadata(
                size: Int64(archiveData.count),
                sha256: archiveSHA,
                storageKey: archiveKey,
                notarized: true,
                stapled: true
            ),
            notarization: NotarizationEvidence(
                codesignVerified: true,
                gatekeeperAccepted: true,
                staplerValidated: true,
                checkedAt: Date(timeIntervalSince1970: 1)
            ),
            publishedAt: Date(timeIntervalSince1970: 2)
        )

        let verifier = RecordingStagedBundleVerifier()
        let core = UpdaterCore(
            policy: policy(),
            assetFetcher: URLSessionUpdateAssetFetcher(),
            bundleVerifier: verifier,
            stateStore: UpdateDownloadStateStore(stateURL: root.appendingPathComponent("state.json")),
            archiveExtractor: FixtureArchiveExtractor(appURL: targetApp)
        )

        let staged = try await core.stageFullArchive(
            releaseManifest: releaseManifest,
            targetManifest: targetManifest,
            assetLocator: UpdateAssetLocator(baseURL: assetsRoot),
            stagingDirectory: root.appendingPathComponent("staging")
        )

        XCTAssertEqual(staged.path, targetApp.path)
        XCTAssertEqual(verifier.verifiedURLs, [targetApp])
        XCTAssertEqual(verifier.contexts.first?.expectedBundleIdentifier, "com.radlof.emsi-swift")
    }

    func testDeltaRejectsUnsafeSymlinkDestinations() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseApp = root.appendingPathComponent("Base.app")
        try makeAppBundle(at: baseApp, marker: "old", codeResources: "signature-old")

        for (index, destination) in ["/tmp/outside", "../outside"].enumerated() {
            let targetManifest = TargetFileManifest(
                releaseID: ReleaseID(version: try SemanticVersion("1.4.3"), buildNumber: 1848 + index),
                bundleIdentifier: "com.radlof.emsi-swift",
                teamIdentifier: "UPK4SC93AN",
                generatedAt: Date(timeIntervalSince1970: 1),
                entries: [
                    FileManifestEntry(
                        path: "Contents/Resources/current.txt",
                        kind: .symlink,
                        symlinkDestination: destination
                    )
                ]
            )
            let deltaManifest = DeltaManifest(
                baseReleaseID: ReleaseID(version: try SemanticVersion("1.4.2"), buildNumber: 1847),
                targetReleaseID: targetManifest.releaseID,
                operations: [
                    DeltaOperation(
                        kind: .setSymlink,
                        path: "Contents/Resources/current.txt",
                        symlinkDestination: destination
                    )
                ]
            )
            let core = UpdaterCore(
                policy: policy(),
                bundleVerifier: RecordingStagedBundleVerifier(),
                stateStore: UpdateDownloadStateStore(stateURL: root.appendingPathComponent("state-\(index).json"))
            )

            do {
                _ = try await core.stageDelta(
                    deltaManifest: deltaManifest,
                    targetManifest: targetManifest,
                    baseAppURL: baseApp,
                    assetLocator: UpdateAssetLocator(baseURL: root.appendingPathComponent("assets")),
                    stagingDirectory: root.appendingPathComponent("staging-\(index)")
                )
                XCTFail("Expected unsafe symlink destination to be rejected.")
            } catch UpdaterCoreError.verificationFailed(let message) {
                XCTAssertTrue(message.contains("Unsafe symlink destination"))
                XCTAssertTrue(message.contains(destination))
            }
        }
    }

    func testInstallerRollsBackWhenLaunchFails() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let installedApp = root.appendingPathComponent("emsi_macos.app")
        let stagedApp = root.appendingPathComponent("staged.app")
        let backupApp = root.appendingPathComponent("backup.app")
        try makeAppBundle(at: installedApp, marker: "old", codeResources: "signature-old")
        try makeAppBundle(at: stagedApp, marker: "new", codeResources: "signature-new")

        let launcher = RecordingLauncher()
        launcher.failingLaunchIndexes = [0]
        let verifier = RecordingStagedBundleVerifier()
        let installer = UpdateInstaller(
            waiter: ImmediateWaiter(),
            launcher: launcher,
            bundleVerifier: verifier
        )

        let result = try installer.performInstall(
            request: UpdateInstallRequest(
                installedAppPath: installedApp.path,
                stagedAppPath: stagedApp.path,
                backupAppPath: backupApp.path,
                mainAppPID: 0,
                bundleIdentifier: "com.radlof.emsi-swift",
                teamIdentifier: "UPK4SC93AN",
                targetReleaseID: ReleaseID(version: try SemanticVersion("1.4.3"), buildNumber: 1848),
                launchToken: "test-token",
                logDirectoryPath: root.appendingPathComponent("logs").path
            )
        )

        XCTAssertEqual(result.status, .rolledBack)
        XCTAssertEqual(
            try String(contentsOf: installedApp.appendingPathComponent("Contents/Resources/marker.txt"), encoding: .utf8),
            "old"
        )
        XCTAssertGreaterThanOrEqual(verifier.verifiedURLs.count, 1)
        XCTAssertEqual(launcher.launched.last?.arguments, ["--update-rollback"])
    }

    private func metadata(version: String, build: Int) throws -> BundleManifestMetadata {
        BundleManifestMetadata(
            releaseID: ReleaseID(version: try SemanticVersion(version), buildNumber: build),
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func policy() -> UpdateEligibilityPolicy {
        UpdateEligibilityPolicy(
            channel: .stable,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            architecture: .arm64
        )
    }

    private func makeAppBundle(at url: URL, marker: String, codeResources: String) throws {
        try createDirectory(url.appendingPathComponent("Contents/MacOS"))
        try createDirectory(url.appendingPathComponent("Contents/Resources"))
        try createDirectory(url.appendingPathComponent("Contents/_CodeSignature"))
        try writeFile("executable-\(marker)", to: url.appendingPathComponent("Contents/MacOS/emsi_macos"), mode: 0o755)
        try writeFile(marker, to: url.appendingPathComponent("Contents/Resources/marker.txt"))
        try writeFile(codeResources, to: url.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        let infoPlist: [String: Any] = ["CFBundleIdentifier": "com.radlof.emsi-swift"]
        let plistData = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try plistData.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(_ text: String, to url: URL, mode: UInt16 = 0o644) throws {
        try createDirectory(url.deletingLastPathComponent())
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: url.path)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class RecordingStagedBundleVerifier: StagedBundleVerifying {
    var verifiedURLs: [URL] = []
    var contexts: [StagedBundleVerificationContext] = []

    func verifyStagedApp(at url: URL, context: StagedBundleVerificationContext) throws {
        verifiedURLs.append(url)
        contexts.append(context)
    }
}

private struct FixtureArchiveExtractor: FullArchiveExtracting {
    let appURL: URL

    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws -> URL {
        appURL
    }
}

private struct ImmediateWaiter: UpdateProcessWaiting {
    func waitForExit(pid: Int32) throws {}
}

private final class RecordingLauncher: UpdateApplicationLaunching {
    var launched: [(url: URL, arguments: [String])] = []
    var failingLaunchIndexes: Set<Int> = []

    func launchApplication(at url: URL, arguments: [String]) throws {
        let index = launched.count
        launched.append((url, arguments))
        if failingLaunchIndexes.contains(index) {
            throw UpdaterCoreError.verificationFailed("Launch failed.")
        }
    }
}
