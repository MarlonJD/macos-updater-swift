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
        let plan = planner.plan(
            channel: .stable,
            version: try SemanticVersion("1.4.3"),
            buildNumber: 1848,
            baseBuildNumber: 1847,
            payloadSHA256Values: [payloadSHA]
        )

        XCTAssertEqual(plan.releaseID.description, "1.4.3+1848")
        XCTAssertEqual(plan.uploadObjects.map(\.role), [
            .payload,
            .targetFileManifest,
            .deltaManifest,
            .releaseManifest,
            .latestChannelManifest
        ])
        XCTAssertEqual(
            plan.uploadObjects.first?.s3Key,
            "desktop/macos/stable/releases/1.4.3+1848/payloads/ab/cd/\(payloadSHA).lzfse"
        )
        XCTAssertEqual(plan.cloudFrontInvalidationPaths, ["/desktop/macos/stable/latest.json"])

        let dryRun = plan.dryRunText()
        XCTAssertTrue(dryRun.contains("Dry run: macOS update distribution plan"))
        XCTAssertTrue(dryRun.contains("delta-from-1847-to-1848.json"))
        XCTAssertTrue(dryRun.contains("latest.json"))
    }
}
