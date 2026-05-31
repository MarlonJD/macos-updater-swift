// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public enum SemanticVersionError: Error, Equatable, LocalizedError {
    case invalidFormat(String)
    case invalidNumericIdentifier(String)

    public var errorDescription: String? {
        switch self {
        case .invalidFormat(let value):
            return "Invalid semantic version: \(value)"
        case .invalidNumericIdentifier(let value):
            return "Invalid semantic version numeric identifier: \(value)"
        }
    }
}

public struct SemanticVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prereleaseIdentifiers: [String]
    public let buildMetadataIdentifiers: [String]

    public init(
        major: Int,
        minor: Int,
        patch: Int,
        prereleaseIdentifiers: [String] = [],
        buildMetadataIdentifiers: [String] = []
    ) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prereleaseIdentifiers = prereleaseIdentifiers
        self.buildMetadataIdentifiers = buildMetadataIdentifiers
    }

    public init(_ value: String) throws {
        let buildSplit = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let versionAndPrerelease = String(buildSplit[0])
        let buildMetadata = buildSplit.count == 2 ? String(buildSplit[1]) : nil

        let prereleaseSplit = versionAndPrerelease.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let core = prereleaseSplit[0].split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else {
            throw SemanticVersionError.invalidFormat(value)
        }

        let coreIdentifiers = core.map(String.init)
        guard coreIdentifiers.allSatisfy(Self.isValidCoreNumericIdentifier) else {
            throw SemanticVersionError.invalidNumericIdentifier(value)
        }
        guard
            let major = Int(core[0]), major >= 0,
            let minor = Int(core[1]), minor >= 0,
            let patch = Int(core[2]), patch >= 0
        else {
            throw SemanticVersionError.invalidNumericIdentifier(value)
        }

        let prereleaseIdentifiers = prereleaseSplit.count == 2
            ? try SemanticVersion.splitIdentifiers(
                String(prereleaseSplit[1]),
                originalValue: value,
                allowLeadingZeroNumericIdentifiers: false
            )
            : []
        let buildMetadataIdentifiers: [String]
        if let buildMetadata {
            buildMetadataIdentifiers = try SemanticVersion.splitIdentifiers(
                buildMetadata,
                originalValue: value,
                allowLeadingZeroNumericIdentifiers: true
            )
        } else {
            buildMetadataIdentifiers = []
        }

        self.init(
            major: major,
            minor: minor,
            patch: patch,
            prereleaseIdentifiers: prereleaseIdentifiers,
            buildMetadataIdentifiers: buildMetadataIdentifiers
        )
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try SemanticVersion(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    public var description: String {
        var value = "\(major).\(minor).\(patch)"
        if !prereleaseIdentifiers.isEmpty {
            value += "-\(prereleaseIdentifiers.joined(separator: "."))"
        }
        if !buildMetadataIdentifiers.isEmpty {
            value += "+\(buildMetadataIdentifiers.joined(separator: "."))"
        }
        return value
    }

    public static func < (left: SemanticVersion, right: SemanticVersion) -> Bool {
        if left.major != right.major {
            return left.major < right.major
        }
        if left.minor != right.minor {
            return left.minor < right.minor
        }
        if left.patch != right.patch {
            return left.patch < right.patch
        }
        return comparePrerelease(left.prereleaseIdentifiers, right.prereleaseIdentifiers) == .orderedAscending
    }

    private static func isValidCoreNumericIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.allSatisfy(\.isNumber) else {
            return false
        }
        return value == "0" || !value.hasPrefix("0")
    }

    private static func splitIdentifiers(
        _ value: String,
        originalValue: String,
        allowLeadingZeroNumericIdentifiers: Bool
    ) throws -> [String] {
        let identifiers = value.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !identifiers.isEmpty else {
            throw SemanticVersionError.invalidFormat(originalValue)
        }

        for identifier in identifiers {
            guard !identifier.isEmpty else {
                throw SemanticVersionError.invalidFormat(originalValue)
            }
            guard identifier.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
                throw SemanticVersionError.invalidFormat(originalValue)
            }
            if
                !allowLeadingZeroNumericIdentifiers,
                identifier.allSatisfy(\.isNumber),
                identifier.count > 1,
                identifier.hasPrefix("0")
            {
                throw SemanticVersionError.invalidNumericIdentifier(identifier)
            }
        }

        return identifiers
    }

    private static func comparePrerelease(_ left: [String], _ right: [String]) -> ComparisonResult {
        if left.isEmpty && right.isEmpty {
            return .orderedSame
        }
        if left.isEmpty {
            return .orderedDescending
        }
        if right.isEmpty {
            return .orderedAscending
        }

        for index in 0..<min(left.count, right.count) {
            let leftIdentifier = left[index]
            let rightIdentifier = right[index]
            if leftIdentifier == rightIdentifier {
                continue
            }

            let leftNumber = Int(leftIdentifier)
            let rightNumber = Int(rightIdentifier)
            switch (leftNumber, rightNumber) {
            case (.some(let leftNumber), .some(let rightNumber)):
                return leftNumber < rightNumber ? .orderedAscending : .orderedDescending
            case (.some, .none):
                return .orderedAscending
            case (.none, .some):
                return .orderedDescending
            case (.none, .none):
                return leftIdentifier < rightIdentifier ? .orderedAscending : .orderedDescending
            }
        }

        if left.count == right.count {
            return .orderedSame
        }
        return left.count < right.count ? .orderedAscending : .orderedDescending
    }
}

public struct ReleaseID: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let version: SemanticVersion
    public let buildNumber: Int

    public init(version: SemanticVersion, buildNumber: Int) {
        self.version = version
        self.buildNumber = buildNumber
    }

    public var description: String {
        "\(version)+\(buildNumber)"
    }

    public static func < (left: ReleaseID, right: ReleaseID) -> Bool {
        if left.buildNumber != right.buildNumber {
            return left.buildNumber < right.buildNumber
        }
        return left.version < right.version
    }
}

public enum ReleaseStateError: Error, Equatable, LocalizedError {
    case buildNumberMustIncrease(current: Int, proposed: Int)

    public var errorDescription: String? {
        switch self {
        case .buildNumberMustIncrease(let current, let proposed):
            return "Build number must increase. Current: \(current), proposed: \(proposed)."
        }
    }
}

public struct DesktopReleaseState: Codable, Equatable, Sendable {
    public let lastBuildNumber: Int
    public let lastStableVersion: SemanticVersion
    public let lastBetaVersion: SemanticVersion?

    public init(
        lastBuildNumber: Int,
        lastStableVersion: SemanticVersion,
        lastBetaVersion: SemanticVersion? = nil
    ) {
        self.lastBuildNumber = lastBuildNumber
        self.lastStableVersion = lastStableVersion
        self.lastBetaVersion = lastBetaVersion
    }

    public func nextBuildNumber() -> Int {
        lastBuildNumber + 1
    }

    public func validateNextBuildNumber(_ proposedBuildNumber: Int) throws {
        guard proposedBuildNumber > lastBuildNumber else {
            throw ReleaseStateError.buildNumberMustIncrease(
                current: lastBuildNumber,
                proposed: proposedBuildNumber
            )
        }
    }
}
