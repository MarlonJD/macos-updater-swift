// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public struct UpdateDownloadState: Codable, Equatable, Sendable {
    public let targetBuild: Int
    public var completedPayloads: [String: String]

    public init(targetBuild: Int, completedPayloads: [String: String] = [:]) {
        self.targetBuild = targetBuild
        self.completedPayloads = completedPayloads
    }
}

public struct UpdateDownloadStateStore {
    public let stateURL: URL
    public var fileManager: FileManager

    public init(stateURL: URL, fileManager: FileManager = .default) {
        self.stateURL = stateURL
        self.fileManager = fileManager
    }

    public func load() throws -> UpdateDownloadState? {
        guard fileManager.fileExists(atPath: stateURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: stateURL)
        return try JSONDecoder().decode(UpdateDownloadState.self, from: data)
    }

    public func save(_ state: UpdateDownloadState) throws {
        try fileManager.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: .atomic)
    }

    public func markCompleted(path: String, sha256: String, targetBuild: Int) throws {
        var state = try load() ?? UpdateDownloadState(targetBuild: targetBuild)
        if state.targetBuild != targetBuild {
            state = UpdateDownloadState(targetBuild: targetBuild)
        }
        state.completedPayloads[path] = sha256
        try save(state)
    }
}
