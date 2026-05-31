// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public enum UpdateChannel: String, Codable, CaseIterable, Sendable {
    case stable
    case beta
    case canary
}

public enum PlatformName: String, Codable, Sendable {
    case macOS = "macos"
}

public enum CPUArchitecture: String, Codable, CaseIterable, Sendable {
    case arm64
    case x86_64
    case universal
}

public enum PayloadCompression: String, Codable, CaseIterable, Sendable {
    case none
    case lzfse
    case zlib
    case lzma
    case lz4
}

public struct CompressedPayloadMetadata: Codable, Equatable, Sendable {
    public let compression: PayloadCompression
    public let compressedSize: Int64
    public let compressedSHA256: String
    public let uncompressedSize: Int64
    public let uncompressedSHA256: String
    public let storageKey: String

    public init(
        compression: PayloadCompression,
        compressedSize: Int64,
        compressedSHA256: String,
        uncompressedSize: Int64,
        uncompressedSHA256: String,
        storageKey: String
    ) {
        self.compression = compression
        self.compressedSize = compressedSize
        self.compressedSHA256 = compressedSHA256
        self.uncompressedSize = uncompressedSize
        self.uncompressedSHA256 = uncompressedSHA256
        self.storageKey = storageKey
    }
}

public struct FullArchiveMetadata: Codable, Equatable, Sendable {
    public let compression: PayloadCompression
    public let size: Int64
    public let sha256: String
    public let storageKey: String
    public let notarized: Bool
    public let stapled: Bool

    public init(
        compression: PayloadCompression = .none,
        size: Int64,
        sha256: String,
        storageKey: String,
        notarized: Bool,
        stapled: Bool
    ) {
        self.compression = compression
        self.size = size
        self.sha256 = sha256
        self.storageKey = storageKey
        self.notarized = notarized
        self.stapled = stapled
    }
}

public struct NotarizationEvidence: Codable, Equatable, Sendable {
    public let codesignVerified: Bool
    public let gatekeeperAccepted: Bool
    public let staplerValidated: Bool
    public let checkedAt: Date

    public init(
        codesignVerified: Bool,
        gatekeeperAccepted: Bool,
        staplerValidated: Bool,
        checkedAt: Date
    ) {
        self.codesignVerified = codesignVerified
        self.gatekeeperAccepted = gatekeeperAccepted
        self.staplerValidated = staplerValidated
        self.checkedAt = checkedAt
    }
}

public enum BundleEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symlink
}

public struct FileManifestEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: BundleEntryKind
    public let size: Int64?
    public let sha256: String?
    public let executable: Bool
    public let mode: UInt16?
    public let symlinkDestination: String?
    public let codeUnitIdentifier: String?

    public init(
        path: String,
        kind: BundleEntryKind,
        size: Int64? = nil,
        sha256: String? = nil,
        executable: Bool = false,
        mode: UInt16? = nil,
        symlinkDestination: String? = nil,
        codeUnitIdentifier: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.size = size
        self.sha256 = sha256
        self.executable = executable
        self.mode = mode
        self.symlinkDestination = symlinkDestination
        self.codeUnitIdentifier = codeUnitIdentifier
    }

    public var isSignatureSidecar: Bool {
        path == "Contents/_CodeSignature/CodeResources" || path.contains("/_CodeSignature/")
    }
}

public struct TargetFileManifest: Codable, Equatable, Sendable {
    public let releaseID: ReleaseID
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let generatedAt: Date
    public let entries: [FileManifestEntry]

    public init(
        releaseID: ReleaseID,
        bundleIdentifier: String,
        teamIdentifier: String,
        generatedAt: Date,
        entries: [FileManifestEntry]
    ) {
        self.releaseID = releaseID
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.generatedAt = generatedAt
        self.entries = entries
    }
}

public enum DeltaOperationKind: String, Codable, Sendable {
    case copyFromBase
    case downloadFile
    case setSymlink
    case delete
    case setMode
}

public struct DeltaOperation: Codable, Equatable, Sendable {
    public let kind: DeltaOperationKind
    public let path: String
    public let payload: CompressedPayloadMetadata?
    public let expectedSHA256: String?
    public let mode: UInt16?
    public let symlinkDestination: String?

    public init(
        kind: DeltaOperationKind,
        path: String,
        payload: CompressedPayloadMetadata? = nil,
        expectedSHA256: String? = nil,
        mode: UInt16? = nil,
        symlinkDestination: String? = nil
    ) {
        self.kind = kind
        self.path = path
        self.payload = payload
        self.expectedSHA256 = expectedSHA256
        self.mode = mode
        self.symlinkDestination = symlinkDestination
    }
}

public struct DeltaManifest: Codable, Equatable, Sendable {
    public let baseReleaseID: ReleaseID
    public let targetReleaseID: ReleaseID
    public let operations: [DeltaOperation]

    public init(baseReleaseID: ReleaseID, targetReleaseID: ReleaseID, operations: [DeltaOperation]) {
        self.baseReleaseID = baseReleaseID
        self.targetReleaseID = targetReleaseID
        self.operations = operations
    }

    public var requiredPayloads: [CompressedPayloadMetadata] {
        operations.compactMap(\.payload)
    }
}

public struct ReleaseManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let releaseID: ReleaseID
    public let version: SemanticVersion
    public let buildNumber: Int
    public let channel: UpdateChannel
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let platform: PlatformName
    public let architectures: [CPUArchitecture]
    public let minimumSystemVersion: String
    public let minimumSupportedBuild: Int
    public let commitSHA: String
    public let changelog: String
    public let targetFileManifestSHA256: String
    public let deltaManifestSHA256ByBaseBuild: [Int: String]
    public let fullArchive: FullArchiveMetadata?
    public let notarization: NotarizationEvidence?
    public let publishedAt: Date

    public init(
        schemaVersion: Int = 1,
        releaseID: ReleaseID,
        version: SemanticVersion,
        buildNumber: Int,
        channel: UpdateChannel,
        bundleIdentifier: String,
        teamIdentifier: String,
        platform: PlatformName,
        architectures: [CPUArchitecture],
        minimumSystemVersion: String,
        minimumSupportedBuild: Int,
        commitSHA: String,
        changelog: String,
        targetFileManifestSHA256: String,
        deltaManifestSHA256ByBaseBuild: [Int: String],
        fullArchive: FullArchiveMetadata? = nil,
        notarization: NotarizationEvidence? = nil,
        publishedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.releaseID = releaseID
        self.version = version
        self.buildNumber = buildNumber
        self.channel = channel
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.platform = platform
        self.architectures = architectures
        self.minimumSystemVersion = minimumSystemVersion
        self.minimumSupportedBuild = minimumSupportedBuild
        self.commitSHA = commitSHA
        self.changelog = changelog
        self.targetFileManifestSHA256 = targetFileManifestSHA256
        self.deltaManifestSHA256ByBaseBuild = deltaManifestSHA256ByBaseBuild
        self.fullArchive = fullArchive
        self.notarization = notarization
        self.publishedAt = publishedAt
    }
}

public struct ChannelManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channel: UpdateChannel
    public let releaseID: ReleaseID
    public let releaseManifestSHA256: String
    public let releaseManifestStorageKey: String
    public let mandatory: Bool
    public let summary: String
    public let publishedAt: Date

    public init(
        schemaVersion: Int = 1,
        channel: UpdateChannel,
        releaseID: ReleaseID,
        releaseManifestSHA256: String,
        releaseManifestStorageKey: String,
        mandatory: Bool = false,
        summary: String,
        publishedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.channel = channel
        self.releaseID = releaseID
        self.releaseManifestSHA256 = releaseManifestSHA256
        self.releaseManifestStorageKey = releaseManifestStorageKey
        self.mandatory = mandatory
        self.summary = summary
        self.publishedAt = publishedAt
    }
}

public enum ManifestSignatureAlgorithm: String, Codable, Sendable {
    case p256ECDSASHA256 = "P-256-ECDSA-SHA256"
}

public struct ManifestSignature: Codable, Equatable, Sendable {
    public let keyID: String
    public let algorithm: ManifestSignatureAlgorithm
    public let signatureBase64: String
    public let signedAt: Date

    public init(
        keyID: String,
        algorithm: ManifestSignatureAlgorithm,
        signatureBase64: String,
        signedAt: Date
    ) {
        self.keyID = keyID
        self.algorithm = algorithm
        self.signatureBase64 = signatureBase64
        self.signedAt = signedAt
    }
}

public struct SignedManifest<Manifest: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let manifest: Manifest
    public let signatures: [ManifestSignature]

    public init(manifest: Manifest, signatures: [ManifestSignature]) {
        self.manifest = manifest
        self.signatures = signatures
    }
}
