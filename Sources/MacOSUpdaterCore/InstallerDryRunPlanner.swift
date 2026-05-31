// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct InstallerDryRunRequest: Codable, Equatable, Sendable {
    public let installedAppPath: String
    public let stagedAppPath: String
    public let backupAppPath: String
    public let mainProcessID: Int32
    public let targetBundleIdentifier: String
    public let targetReleaseID: ReleaseID

    public init(
        installedAppPath: String,
        stagedAppPath: String,
        backupAppPath: String,
        mainProcessID: Int32,
        targetBundleIdentifier: String,
        targetReleaseID: ReleaseID
    ) {
        self.installedAppPath = installedAppPath
        self.stagedAppPath = stagedAppPath
        self.backupAppPath = backupAppPath
        self.mainProcessID = mainProcessID
        self.targetBundleIdentifier = targetBundleIdentifier
        self.targetReleaseID = targetReleaseID
    }
}

public struct InstallerDryRunPlan: Equatable, Sendable {
    public let steps: [String]

    public init(steps: [String]) {
        self.steps = steps
    }

    public func text() -> String {
        steps.enumerated().map { index, step in
            "\(index + 1). \(step)"
        }.joined(separator: "\n")
    }
}

public enum UpdateInstallerPlanner {
    public static func dryRunPlan(for request: InstallerDryRunRequest) -> InstallerDryRunPlan {
        InstallerDryRunPlan(
            steps: [
                "Wait for process \(request.mainProcessID) to terminate.",
                "Verify staged app at \(request.stagedAppPath).",
                "Move installed app from \(request.installedAppPath) to backup path \(request.backupAppPath).",
                "Move staged app into \(request.installedAppPath).",
                "Launch \(request.targetBundleIdentifier) at release \(request.targetReleaseID).",
                "Restore backup if launch verification fails."
            ]
        )
    }

    public static func dryRunPlan(for request: UpdateInstallRequest) -> InstallerDryRunPlan {
        InstallerDryRunPlan(
            steps: [
                "Verify signed install request before invoking the helper.",
                "Wait for process \(request.mainAppPID) to terminate.",
                "Verify staged app at \(request.stagedAppPath) with codesign, Gatekeeper, stapler, bundle identifier, and team identifier checks.",
                "Move installed app from \(request.installedAppPath) to backup path \(request.backupAppPath).",
                "Move staged app into \(request.installedAppPath).",
                "Verify installed app again with the same staged-app gate.",
                "Launch \(request.bundleIdentifier) at release \(request.targetReleaseID).",
                "Restore backup if launch verification fails."
            ]
        )
    }
}
