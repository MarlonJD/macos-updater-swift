// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import XCTest
@testable import MacOSUpdaterManifest
@testable import MacOSUpdaterRelease

final class ReleaseGenerationTests: XCTestCase {
    func testDeltaGeneratorCreatesContentAddressedCompressedPayloads() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseApp = root.appendingPathComponent("Base.app")
        let targetApp = root.appendingPathComponent("Target.app")
        try makeAppBundle(
            at: baseApp,
            executableText: "executable-v1",
            resourceText: "resource-v1",
            codeResourcesText: "root-signature-v1",
            nestedExecutableText: "nested-v1",
            nestedCodeResourcesText: "nested-signature-v1",
            includesDeletedFile: true,
            includesNewFile: false
        )
        try makeAppBundle(
            at: targetApp,
            executableText: "executable-v2",
            resourceText: "resource-v2",
            codeResourcesText: "root-signature-v2",
            nestedExecutableText: "nested-v2",
            nestedCodeResourcesText: "nested-signature-v2",
            includesDeletedFile: false,
            includesNewFile: true
        )

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

        let downloadPaths = Set(generated.manifest.operations.filter { $0.kind == .downloadFile }.map(\.path))
        XCTAssertTrue(downloadPaths.contains("Contents/MacOS/emsi_macos"))
        XCTAssertTrue(downloadPaths.contains("Contents/_CodeSignature/CodeResources"))
        XCTAssertTrue(downloadPaths.contains("Contents/Frameworks/Delta.framework/Delta"))
        XCTAssertTrue(downloadPaths.contains("Contents/Frameworks/Delta.framework/_CodeSignature/CodeResources"))
        XCTAssertTrue(generated.manifest.operations.contains { $0.kind == .delete && $0.path == "Contents/Resources/old.txt" })
        XCTAssertTrue(generated.manifest.operations.contains { $0.kind == .setSymlink && $0.path == "Contents/Resources/current.txt" })

        for payload in generated.payloads {
            XCTAssertTrue(payload.metadata.storageKey.hasPrefix("\(releasePrefix)/payloads/"))
            XCTAssertTrue(payload.metadata.storageKey.hasSuffix(".lzfse"))
            XCTAssertFalse(payload.metadata.storageKey.contains(".app/Contents/"))
            XCTAssertEqual(payload.metadata.compression, .lzfse)
            XCTAssertTrue(SHA256Digest.isValidHexDigest(payload.metadata.compressedSHA256))
            XCTAssertTrue(SHA256Digest.isValidHexDigest(payload.metadata.uncompressedSHA256))
        }
    }

    func testDeltaGeneratorRejectsChangedSealedFileWithoutChangedCodeResources() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let baseApp = root.appendingPathComponent("Base.app")
        let targetApp = root.appendingPathComponent("Target.app")
        try makeAppBundle(
            at: baseApp,
            executableText: "same-executable",
            resourceText: "resource-v1",
            codeResourcesText: "root-signature",
            nestedExecutableText: "nested",
            nestedCodeResourcesText: "nested-signature",
            includesDeletedFile: false,
            includesNewFile: false
        )
        try makeAppBundle(
            at: targetApp,
            executableText: "same-executable",
            resourceText: "resource-v2",
            codeResourcesText: "root-signature",
            nestedExecutableText: "nested",
            nestedCodeResourcesText: "nested-signature",
            includesDeletedFile: false,
            includesNewFile: false
        )

        let manifestGenerator = BundleManifestGenerator()
        let baseManifest = try manifestGenerator.makeTargetManifest(
            appBundleURL: baseApp,
            metadata: metadata(version: "1.4.2", build: 1847)
        )
        let targetManifest = try manifestGenerator.makeTargetManifest(
            appBundleURL: targetApp,
            metadata: metadata(version: "1.4.3", build: 1848)
        )

        XCTAssertThrowsError(
            try DeltaManifestGenerator().makeDelta(
                baseManifest: baseManifest,
                targetManifest: targetManifest,
                targetAppURL: targetApp,
                releasePrefix: "desktop/macos/stable/releases/1.4.3+1848"
            )
        ) { error in
            XCTAssertEqual(error as? ReleaseGeneratorError, .missingSignatureSidecar("Contents/_CodeSignature/CodeResources"))
        }
    }

    func testReleaseManifestRequiresFullArchiveMetadata() throws {
        let version = try SemanticVersion("1.4.3")
        let releaseID = ReleaseID(version: version, buildNumber: 1848)
        let targetManifest = TargetFileManifest(
            releaseID: releaseID,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            generatedAt: Date(timeIntervalSince1970: 1),
            entries: []
        )
        let archive = FullArchiveMetadata(
            size: 42,
            sha256: String(repeating: "a", count: 64),
            storageKey: "desktop/macos/stable/releases/1.4.3+1848/archives/\(String(repeating: "a", count: 64)).zip",
            notarized: true,
            stapled: true
        )
        let release = try ReleaseManifestBuilder.makeReleaseManifest(
            input: ReleaseManifestBuildInput(
                targetManifest: targetManifest,
                version: version,
                buildNumber: 1848,
                channel: .stable,
                architectures: [.universal],
                minimumSystemVersion: "13.0",
                minimumSupportedBuild: 1847,
                commitSHA: "abcdef",
                changelog: "## 1.4.3",
                fullArchive: archive,
                deltaManifestsByBaseBuild: [:],
                notarization: NotarizationEvidence(
                    codesignVerified: true,
                    gatekeeperAccepted: true,
                    staplerValidated: true,
                    checkedAt: Date(timeIntervalSince1970: 2)
                )
            )
        )

        XCTAssertEqual(release.fullArchive, archive)
        XCTAssertEqual(release.notarization?.staplerValidated, true)
    }

    func testTargetManifestRejectsUnsafeSymlinkDestinations() throws {
        for destination in ["/tmp/outside", "../outside"] {
            let root = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: root) }

            let targetApp = root.appendingPathComponent("Target.app")
            try makeAppBundle(
                at: targetApp,
                executableText: "executable",
                resourceText: "resource",
                codeResourcesText: "root-signature",
                nestedExecutableText: "nested",
                nestedCodeResourcesText: "nested-signature",
                includesDeletedFile: false,
                includesNewFile: true
            )

            try FileManager.default.createSymbolicLink(
                atPath: targetApp.appendingPathComponent("Contents/Resources/unsafe.txt").path,
                withDestinationPath: destination
            )

            XCTAssertThrowsError(
                try BundleManifestGenerator().makeTargetManifest(
                    appBundleURL: targetApp,
                    metadata: metadata(version: "1.4.3", build: 1848)
                )
            ) { error in
                guard case ReleaseGeneratorError.invalidSymlinkDestination(let path, let rejectedDestination) = error else {
                    return XCTFail("Expected invalid symlink destination, got \(error).")
                }
                XCTAssertEqual(path, "Contents/Resources/unsafe.txt")
                XCTAssertEqual(rejectedDestination, destination)
            }
        }
    }

    private func metadata(version: String, build: Int) throws -> BundleManifestMetadata {
        BundleManifestMetadata(
            releaseID: ReleaseID(version: try SemanticVersion(version), buildNumber: build),
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            generatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeAppBundle(
        at url: URL,
        executableText: String,
        resourceText: String,
        codeResourcesText: String,
        nestedExecutableText: String,
        nestedCodeResourcesText: String,
        includesDeletedFile: Bool,
        includesNewFile: Bool
    ) throws {
        try createDirectory(url.appendingPathComponent("Contents/MacOS"))
        try createDirectory(url.appendingPathComponent("Contents/Resources"))
        try createDirectory(url.appendingPathComponent("Contents/_CodeSignature"))
        try createDirectory(url.appendingPathComponent("Contents/Frameworks/Delta.framework/_CodeSignature"))
        try writeFile(executableText, to: url.appendingPathComponent("Contents/MacOS/emsi_macos"), mode: 0o755)
        try writeFile(resourceText, to: url.appendingPathComponent("Contents/Resources/message.txt"))
        try writeFile(codeResourcesText, to: url.appendingPathComponent("Contents/_CodeSignature/CodeResources"))
        try writeFile(nestedExecutableText, to: url.appendingPathComponent("Contents/Frameworks/Delta.framework/Delta"), mode: 0o755)
        try writeFile(nestedCodeResourcesText, to: url.appendingPathComponent("Contents/Frameworks/Delta.framework/_CodeSignature/CodeResources"))

        if includesDeletedFile {
            try writeFile("old", to: url.appendingPathComponent("Contents/Resources/old.txt"))
        }
        if includesNewFile {
            try writeFile("new", to: url.appendingPathComponent("Contents/Resources/new.txt"))
        }
        try FileManager.default.createSymbolicLink(
            atPath: url.appendingPathComponent("Contents/Resources/current.txt").path,
            withDestinationPath: includesNewFile ? "new.txt" : "message.txt"
        )
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
