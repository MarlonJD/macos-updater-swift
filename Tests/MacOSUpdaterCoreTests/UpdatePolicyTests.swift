import Foundation
import XCTest
@testable import MacOSUpdaterCore
@testable import MacOSUpdaterManifest

final class UpdatePolicyTests: XCTestCase {
    func testEligibilityAcceptsMatchingNewerRelease() throws {
        let policy = UpdateEligibilityPolicy(
            channel: .stable,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            architecture: .arm64
        )

        let decision = try policy.validate(
            releaseManifest: releaseManifest(buildNumber: 1848, architectures: [.universal]),
            installedApp: installedApp(buildNumber: 1847)
        )

        XCTAssertEqual(decision.targetBuildNumber, 1848)
        XCTAssertEqual(decision.deltaManifestSHA256, String(repeating: "d", count: 64))
    }

    func testEligibilityRejectsWrongChannelAndStaleBuild() throws {
        let policy = UpdateEligibilityPolicy(
            channel: .stable,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            architecture: .arm64
        )

        XCTAssertThrowsError(
            try policy.validate(
                releaseManifest: releaseManifest(buildNumber: 1848, channel: .beta),
                installedApp: installedApp(buildNumber: 1847)
            )
        ) { error in
            XCTAssertEqual(error as? UpdatePolicyError, .channelMismatch(expected: .stable, actual: .beta))
        }

        XCTAssertThrowsError(
            try policy.validate(
                releaseManifest: releaseManifest(buildNumber: 1847),
                installedApp: installedApp(buildNumber: 1847)
            )
        ) { error in
            XCTAssertEqual(error as? UpdatePolicyError, .staleBuild(current: 1847, target: 1847))
        }
    }

    func testInstallerDryRunPlanContainsTransactionalSteps() throws {
        let request = InstallerDryRunRequest(
            installedAppPath: "/Applications/emsi_macos.app",
            stagedAppPath: "/Users/me/Library/Caches/emsi/update/staged.app",
            backupAppPath: "/Users/me/Library/Caches/emsi/update/backup.app",
            mainProcessID: 1234,
            targetBundleIdentifier: "com.radlof.emsi-swift",
            targetReleaseID: ReleaseID(version: try SemanticVersion("1.4.3"), buildNumber: 1848)
        )

        let text = UpdateInstallerPlanner.dryRunPlan(for: request).text()
        XCTAssertTrue(text.contains("Wait for process 1234"))
        XCTAssertTrue(text.contains("Restore backup if launch verification fails"))
    }

    private func installedApp(buildNumber: Int) throws -> InstalledAppState {
        InstalledAppState(
            releaseID: ReleaseID(version: try SemanticVersion("1.4.2"), buildNumber: buildNumber),
            buildNumber: buildNumber,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            platform: .macOS,
            architecture: .arm64
        )
    }

    private func releaseManifest(
        buildNumber: Int,
        channel: UpdateChannel = .stable,
        architectures: [CPUArchitecture] = [.arm64]
    ) throws -> ReleaseManifest {
        let version = try SemanticVersion("1.4.3")
        return ReleaseManifest(
            releaseID: ReleaseID(version: version, buildNumber: buildNumber),
            version: version,
            buildNumber: buildNumber,
            channel: channel,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            platform: .macOS,
            architectures: architectures,
            minimumSystemVersion: "13.0",
            minimumSupportedBuild: 1847,
            commitSHA: "abcdef123456",
            changelog: "## 1.4.3\n- Test release",
            targetFileManifestSHA256: String(repeating: "c", count: 64),
            deltaManifestSHA256ByBaseBuild: [1847: String(repeating: "d", count: 64)],
            publishedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }
}
