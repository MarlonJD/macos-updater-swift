// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct ReleaseManifestBuildInput: Sendable {
    public let targetManifest: TargetFileManifest
    public let version: SemanticVersion
    public let buildNumber: Int
    public let channel: UpdateChannel
    public let platform: PlatformName
    public let architectures: [CPUArchitecture]
    public let minimumSystemVersion: String
    public let minimumSupportedBuild: Int
    public let commitSHA: String
    public let changelog: String
    public let fullArchive: FullArchiveMetadata
    public let deltaManifestsByBaseBuild: [Int: DeltaManifest]
    public let notarization: NotarizationEvidence
    public let publishedAt: Date

    public init(
        targetManifest: TargetFileManifest,
        version: SemanticVersion,
        buildNumber: Int,
        channel: UpdateChannel,
        platform: PlatformName = .macOS,
        architectures: [CPUArchitecture],
        minimumSystemVersion: String,
        minimumSupportedBuild: Int,
        commitSHA: String,
        changelog: String,
        fullArchive: FullArchiveMetadata,
        deltaManifestsByBaseBuild: [Int: DeltaManifest],
        notarization: NotarizationEvidence,
        publishedAt: Date = Date()
    ) {
        self.targetManifest = targetManifest
        self.version = version
        self.buildNumber = buildNumber
        self.channel = channel
        self.platform = platform
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.minimumSupportedBuild = minimumSupportedBuild
        self.commitSHA = commitSHA
        self.changelog = changelog
        self.fullArchive = fullArchive
        self.deltaManifestsByBaseBuild = deltaManifestsByBaseBuild
        self.notarization = notarization
        self.publishedAt = publishedAt
    }
}

public enum ReleaseManifestBuilder {
    public static func makeReleaseManifest(input: ReleaseManifestBuildInput) throws -> ReleaseManifest {
        let targetManifestData = try ManifestCoding.canonicalJSONData(for: input.targetManifest)
        var deltaHashes: [Int: String] = [:]
        for (baseBuild, deltaManifest) in input.deltaManifestsByBaseBuild {
            let data = try ManifestCoding.canonicalJSONData(for: deltaManifest)
            deltaHashes[baseBuild] = SHA256Digest.hex(for: data)
        }

        return ReleaseManifest(
            releaseID: input.targetManifest.releaseID,
            version: input.version,
            buildNumber: input.buildNumber,
            channel: input.channel,
            bundleIdentifier: input.targetManifest.bundleIdentifier,
            teamIdentifier: input.targetManifest.teamIdentifier,
            platform: input.platform,
            architectures: input.architectures,
            minimumSystemVersion: input.minimumSystemVersion,
            minimumSupportedBuild: input.minimumSupportedBuild,
            commitSHA: input.commitSHA,
            changelog: input.changelog,
            targetFileManifestSHA256: SHA256Digest.hex(for: targetManifestData),
            deltaManifestSHA256ByBaseBuild: deltaHashes,
            fullArchive: input.fullArchive,
            notarization: input.notarization,
            publishedAt: input.publishedAt
        )
    }

    public static func makeChannelManifest(
        releaseManifest: ReleaseManifest,
        releaseManifestStorageKey: String,
        mandatory: Bool = false,
        summary: String
    ) throws -> ChannelManifest {
        let releaseData = try ManifestCoding.canonicalJSONData(for: releaseManifest)
        return ChannelManifest(
            channel: releaseManifest.channel,
            releaseID: releaseManifest.releaseID,
            releaseManifestSHA256: SHA256Digest.hex(for: releaseData),
            releaseManifestStorageKey: releaseManifestStorageKey,
            mandatory: mandatory,
            summary: summary,
            publishedAt: releaseManifest.publishedAt
        )
    }
}
