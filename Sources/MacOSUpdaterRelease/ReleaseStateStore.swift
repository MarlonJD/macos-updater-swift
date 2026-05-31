// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct ReleaseStateStore {
    public let fileURL: URL
    public var fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    public func load() throws -> DesktopReleaseState {
        let data = try Data(contentsOf: fileURL)
        return try ManifestCoding.decoder().decode(DesktopReleaseState.self, from: data)
    }

    public func save(_ state: DesktopReleaseState) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try ManifestCoding.prettyJSONData(for: state)
        try data.write(to: fileURL, options: .atomic)
    }

    public func nextState(channel: UpdateChannel, version: SemanticVersion) throws -> DesktopReleaseState {
        let current = try load()
        let nextBuildNumber = current.nextBuildNumber()
        switch channel {
        case .stable:
            return DesktopReleaseState(
                lastBuildNumber: nextBuildNumber,
                lastStableVersion: version,
                lastBetaVersion: current.lastBetaVersion
            )
        case .beta, .canary:
            return DesktopReleaseState(
                lastBuildNumber: nextBuildNumber,
                lastStableVersion: current.lastStableVersion,
                lastBetaVersion: version
            )
        }
    }
}
