import Foundation
import MacOSUpdaterManifest

public enum DistributionObjectRole: String, Codable, Sendable {
    case payload
    case targetFileManifest
    case deltaManifest
    case releaseManifest
    case latestChannelManifest
}

public struct DistributionObject: Codable, Equatable, Sendable {
    public let role: DistributionObjectRole
    public let s3Key: String
    public let immutable: Bool

    public init(role: DistributionObjectRole, s3Key: String, immutable: Bool) {
        self.role = role
        self.s3Key = s3Key
        self.immutable = immutable
    }
}

public struct DistributionPlan: Codable, Equatable, Sendable {
    public let bucketName: String
    public let releaseID: ReleaseID
    public let channel: UpdateChannel
    public let uploadObjects: [DistributionObject]
    public let cloudFrontInvalidationPaths: [String]

    public init(
        bucketName: String,
        releaseID: ReleaseID,
        channel: UpdateChannel,
        uploadObjects: [DistributionObject],
        cloudFrontInvalidationPaths: [String]
    ) {
        self.bucketName = bucketName
        self.releaseID = releaseID
        self.channel = channel
        self.uploadObjects = uploadObjects
        self.cloudFrontInvalidationPaths = cloudFrontInvalidationPaths
    }

    public func dryRunText() -> String {
        var lines = [
            "Dry run: macOS update distribution plan",
            "Bucket: s3://\(bucketName)",
            "Channel: \(channel.rawValue)",
            "Release: \(releaseID)",
            "",
            "Upload order:"
        ]

        for (index, object) in uploadObjects.enumerated() {
            let mutability = object.immutable ? "immutable" : "mutable"
            lines.append("\(index + 1). \(object.role.rawValue): s3://\(bucketName)/\(object.s3Key) (\(mutability))")
        }

        lines.append("")
        lines.append("CloudFront invalidation paths:")
        lines.append(contentsOf: cloudFrontInvalidationPaths.map { "- \($0)" })
        return lines.joined(separator: "\n")
    }
}

public struct DistributionKeyPlanner: Sendable {
    public let bucketName: String
    public let platformPrefix: String

    public init(bucketName: String = "emsi-updates-prod", platformPrefix: String = "desktop/macos") {
        self.bucketName = bucketName
        self.platformPrefix = platformPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public func plan(
        channel: UpdateChannel,
        version: SemanticVersion,
        buildNumber: Int,
        baseBuildNumber: Int?,
        payloadSHA256Values: [String] = []
    ) -> DistributionPlan {
        let releaseID = ReleaseID(version: version, buildNumber: buildNumber)
        let channelPrefix = "\(platformPrefix)/\(channel.rawValue)"
        let releasePrefix = "\(channelPrefix)/releases/\(releaseID)"
        var uploadObjects = payloadSHA256Values.sorted().map { payloadSHA256 in
            DistributionObject(
                role: .payload,
                s3Key: "\(releasePrefix)/payloads/\(payloadPathComponent(for: payloadSHA256)).lzfse",
                immutable: true
            )
        }

        uploadObjects.append(
            DistributionObject(
                role: .targetFileManifest,
                s3Key: "\(releasePrefix)/target-file-manifest.json",
                immutable: true
            )
        )

        if let baseBuildNumber {
            uploadObjects.append(
                DistributionObject(
                    role: .deltaManifest,
                    s3Key: "\(releasePrefix)/delta-from-\(baseBuildNumber)-to-\(buildNumber).json",
                    immutable: true
                )
            )
        }

        uploadObjects.append(
            DistributionObject(
                role: .releaseManifest,
                s3Key: "\(releasePrefix)/release.json",
                immutable: true
            )
        )
        uploadObjects.append(
            DistributionObject(
                role: .latestChannelManifest,
                s3Key: "\(channelPrefix)/latest.json",
                immutable: false
            )
        )

        return DistributionPlan(
            bucketName: bucketName,
            releaseID: releaseID,
            channel: channel,
            uploadObjects: uploadObjects,
            cloudFrontInvalidationPaths: uploadObjects
                .filter { !$0.immutable }
                .map { "/\($0.s3Key)" }
        )
    }

    private func payloadPathComponent(for sha256: String) -> String {
        let normalized = sha256.lowercased()
        guard normalized.count >= 4 else {
            return "unknown/\(normalized)"
        }
        let firstBreak = normalized.index(normalized.startIndex, offsetBy: 2)
        let secondBreak = normalized.index(normalized.startIndex, offsetBy: 4)
        return "\(normalized[..<firstBreak])/\(normalized[firstBreak..<secondBreak])/\(normalized)"
    }
}
