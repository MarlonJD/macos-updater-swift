// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import XCTest
@testable import MacOSUpdaterManifest
@testable import MacOSUpdaterRelease

final class ReleaseToolingTests: XCTestCase {
    func testChangelogDraftIncludesConfiguredConventionalCommitTypes() throws {
        let fixtureURL = Bundle.module.url(forResource: "commits", withExtension: "txt", subdirectory: "Fixtures")
        let fixture = try XCTUnwrap(fixtureURL).path
        let commits = try String(contentsOfFile: fixture, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let changelog = ChangelogDraftGenerator().generate(
            version: try SemanticVersion("1.4.3"),
            commits: commits
        )

        XCTAssertTrue(changelog.contains("### Features"))
        XCTAssertTrue(changelog.contains("- updater: add signed manifest envelope"))
        XCTAssertTrue(changelog.contains("### Fixes"))
        XCTAssertTrue(changelog.contains("- core: reject stale build numbers"))
        XCTAssertTrue(changelog.contains("### Breaking Changes"))
        XCTAssertTrue(changelog.contains("- manifest: require P-256 signatures"))
        XCTAssertFalse(changelog.contains("update docs only"))
    }

    func testDistributionKeyPlannerBuildsSafeUploadOrderAndDryRun() throws {
        let planner = DistributionKeyPlanner(bucketName: "emsi-updates-prod")
        let payloadSHA = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let archiveSHA = "bbbbbb0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let plan = planner.plan(
            channel: .stable,
            version: try SemanticVersion("1.4.3"),
            buildNumber: 1848,
            baseBuildNumber: 1847,
            payloadSHA256Values: [payloadSHA],
            fullArchiveSHA256: archiveSHA
        )

        XCTAssertEqual(plan.releaseID.description, "1.4.3+1848")
        XCTAssertEqual(plan.uploadObjects.map(\.role), [
            .payload,
            .fullArchive,
            .targetFileManifest,
            .deltaManifest,
            .releaseManifest,
            .latestChannelManifest
        ])
        XCTAssertEqual(
            plan.uploadObjects.first?.s3Key,
            "desktop/macos/stable/releases/1.4.3+1848/payloads/ab/cd/\(payloadSHA).lzfse"
        )
        XCTAssertEqual(
            plan.uploadObjects[1].s3Key,
            "desktop/macos/stable/releases/1.4.3+1848/archives/\(archiveSHA).zip"
        )
        XCTAssertEqual(plan.cloudFrontInvalidationPaths, ["/desktop/macos/stable/latest.json"])

        let dryRun = plan.dryRunText()
        XCTAssertTrue(dryRun.contains("Dry run: macOS update distribution plan"))
        XCTAssertTrue(dryRun.contains("delta-from-1847-to-1848.json"))
        XCTAssertTrue(dryRun.contains("/archives/\(archiveSHA).zip"))
        XCTAssertTrue(dryRun.contains("latest.json"))
    }

    func testFullArchiveBuilderUsesDittoWithMacOSBundleSafeFlags() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let appURL = root.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)

        let runner = RecordingReleaseCommandRunner()
        let metadata = try FullArchiveBuilder(commandRunner: runner).createZipArchive(
            appBundleURL: appURL,
            releasePrefix: "desktop/macos/stable/releases/1.4.3+1848",
            outputDirectory: root.appendingPathComponent("out")
        )

        XCTAssertEqual(runner.executablePath, "/usr/bin/ditto")
        XCTAssertTrue(runner.arguments.contains("-c"))
        XCTAssertTrue(runner.arguments.contains("-k"))
        XCTAssertTrue(runner.arguments.contains("--keepParent"))
        XCTAssertTrue(runner.arguments.contains("--sequesterRsrc"))
        XCTAssertEqual(runner.arguments.suffix(2).first, appURL.path)
        XCTAssertTrue(metadata.storageKey.hasPrefix("desktop/macos/stable/releases/1.4.3+1848/archives/"))
        XCTAssertTrue(metadata.storageKey.hasSuffix(".zip"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}

private final class RecordingReleaseCommandRunner: ReleaseCommandRunning {
    private(set) var executablePath = ""
    private(set) var arguments: [String] = []

    func run(_ executablePath: String, arguments: [String]) throws -> String {
        self.executablePath = executablePath
        self.arguments = arguments

        guard let outputPath = arguments.last else {
            return ""
        }
        let outputURL = URL(fileURLWithPath: outputPath)
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("zip-fixture".utf8).write(to: outputURL)
        return ""
    }
}
