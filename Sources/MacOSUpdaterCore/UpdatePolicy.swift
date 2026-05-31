// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct InstalledAppState: Equatable, Sendable {
    public let releaseID: ReleaseID
    public let buildNumber: Int
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let platform: PlatformName
    public let architecture: CPUArchitecture

    public init(
        releaseID: ReleaseID,
        buildNumber: Int,
        bundleIdentifier: String,
        teamIdentifier: String,
        platform: PlatformName,
        architecture: CPUArchitecture
    ) {
        self.releaseID = releaseID
        self.buildNumber = buildNumber
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.platform = platform
        self.architecture = architecture
    }
}

public enum UpdatePolicyError: Error, Equatable, LocalizedError {
    case channelMismatch(expected: UpdateChannel, actual: UpdateChannel)
    case bundleIdentifierMismatch(expected: String, actual: String)
    case teamIdentifierMismatch(expected: String, actual: String)
    case platformMismatch(expected: PlatformName, actual: PlatformName)
    case unsupportedArchitecture(CPUArchitecture)
    case staleBuild(current: Int, target: Int)
    case belowMinimumSupportedBuild(current: Int, minimum: Int)

    public var errorDescription: String? {
        switch self {
        case .channelMismatch(let expected, let actual):
            return "Update channel mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
        case .bundleIdentifierMismatch(let expected, let actual):
            return "Bundle identifier mismatch. Expected \(expected), got \(actual)."
        case .teamIdentifierMismatch(let expected, let actual):
            return "Team identifier mismatch. Expected \(expected), got \(actual)."
        case .platformMismatch(let expected, let actual):
            return "Platform mismatch. Expected \(expected.rawValue), got \(actual.rawValue)."
        case .unsupportedArchitecture(let architecture):
            return "Unsupported update architecture: \(architecture.rawValue)."
        case .staleBuild(let current, let target):
            return "Target build \(target) is not newer than installed build \(current)."
        case .belowMinimumSupportedBuild(let current, let minimum):
            return "Installed build \(current) is below the minimum supported build \(minimum)."
        }
    }
}

public struct UpdateDecision: Equatable, Sendable {
    public let targetReleaseID: ReleaseID
    public let targetBuildNumber: Int
    public let deltaManifestSHA256: String?
    public let fullArchive: FullArchiveMetadata?

    public init(
        targetReleaseID: ReleaseID,
        targetBuildNumber: Int,
        deltaManifestSHA256: String?,
        fullArchive: FullArchiveMetadata?
    ) {
        self.targetReleaseID = targetReleaseID
        self.targetBuildNumber = targetBuildNumber
        self.deltaManifestSHA256 = deltaManifestSHA256
        self.fullArchive = fullArchive
    }
}

public struct UpdateEligibilityPolicy: Sendable {
    public let channel: UpdateChannel
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let platform: PlatformName
    public let architecture: CPUArchitecture

    public init(
        channel: UpdateChannel,
        bundleIdentifier: String,
        teamIdentifier: String,
        platform: PlatformName = .macOS,
        architecture: CPUArchitecture
    ) {
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.platform = platform
        self.architecture = architecture
    }

    public func validate(
        releaseManifest: ReleaseManifest,
        installedApp: InstalledAppState
    ) throws -> UpdateDecision {
        guard releaseManifest.channel == channel else {
            throw UpdatePolicyError.channelMismatch(expected: channel, actual: releaseManifest.channel)
        }
        guard releaseManifest.bundleIdentifier == bundleIdentifier else {
            throw UpdatePolicyError.bundleIdentifierMismatch(
                expected: bundleIdentifier,
                actual: releaseManifest.bundleIdentifier
            )
        }
        guard releaseManifest.teamIdentifier == teamIdentifier else {
            throw UpdatePolicyError.teamIdentifierMismatch(
                expected: teamIdentifier,
                actual: releaseManifest.teamIdentifier
            )
        }
        guard releaseManifest.platform == platform, installedApp.platform == platform else {
            throw UpdatePolicyError.platformMismatch(expected: platform, actual: releaseManifest.platform)
        }
        guard releaseManifest.architectures.contains(.universal) || releaseManifest.architectures.contains(architecture) else {
            throw UpdatePolicyError.unsupportedArchitecture(architecture)
        }
        guard installedApp.buildNumber >= releaseManifest.minimumSupportedBuild else {
            throw UpdatePolicyError.belowMinimumSupportedBuild(
                current: installedApp.buildNumber,
                minimum: releaseManifest.minimumSupportedBuild
            )
        }
        guard releaseManifest.buildNumber > installedApp.buildNumber else {
            throw UpdatePolicyError.staleBuild(
                current: installedApp.buildNumber,
                target: releaseManifest.buildNumber
            )
        }

        return UpdateDecision(
            targetReleaseID: releaseManifest.releaseID,
            targetBuildNumber: releaseManifest.buildNumber,
            deltaManifestSHA256: releaseManifest.deltaManifestSHA256ByBaseBuild[installedApp.buildNumber],
            fullArchive: releaseManifest.fullArchive
        )
    }
}
