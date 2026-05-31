// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Darwin
import Foundation
import MacOSUpdaterManifest

public struct BundleManifestMetadata: Equatable, Sendable {
    public let releaseID: ReleaseID
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let generatedAt: Date

    public init(
        releaseID: ReleaseID,
        bundleIdentifier: String,
        teamIdentifier: String,
        generatedAt: Date = Date()
    ) {
        self.releaseID = releaseID
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.generatedAt = generatedAt
    }
}

public enum ReleaseGeneratorError: Error, Equatable, LocalizedError {
    case appBundleNotFound(String)
    case invalidRelativePath(String)
    case unsupportedFileKind(String)
    case missingPayload(String)
    case missingSignatureSidecar(String)
    case invalidArchive(String)

    public var errorDescription: String? {
        switch self {
        case .appBundleNotFound(let path):
            return "App bundle not found: \(path)."
        case .invalidRelativePath(let path):
            return "Invalid bundle-relative path: \(path)."
        case .unsupportedFileKind(let path):
            return "Unsupported file kind at path: \(path)."
        case .missingPayload(let path):
            return "Missing payload for changed file: \(path)."
        case .missingSignatureSidecar(let path):
            return "Delta is missing required signature sidecar payload: \(path)."
        case .invalidArchive(let path):
            return "Invalid full archive: \(path)."
        }
    }
}

public struct BundleManifestGenerator {
    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func makeTargetManifest(
        appBundleURL: URL,
        metadata: BundleManifestMetadata
    ) throws -> TargetFileManifest {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appBundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReleaseGeneratorError.appBundleNotFound(appBundleURL.path)
        }

        guard let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil) else {
            throw ReleaseGeneratorError.appBundleNotFound(appBundleURL.path)
        }

        let rootPath = appBundleURL.standardizedFileURL.path
        var entries: [FileManifestEntry] = []
        for case let itemURL as URL in enumerator {
            let itemPath = itemURL.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else {
                continue
            }

            let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
            try ReleasePath.validateBundleRelativePath(relativePath)
            let statInfo = try ReleaseFileSystem.lstatInfo(at: itemURL)
            let mode = UInt16(statInfo.st_mode & 0o777)
            let kind = try ReleaseFileSystem.bundleEntryKind(for: statInfo.st_mode, path: relativePath)

            switch kind {
            case .file:
                entries.append(
                    FileManifestEntry(
                        path: relativePath,
                        kind: .file,
                        size: Int64(statInfo.st_size),
                        sha256: try SHA256Digest.hex(forFileAt: itemURL),
                        executable: (mode & 0o111) != 0,
                        mode: mode,
                        codeUnitIdentifier: codeUnitPath(for: relativePath)
                    )
                )
            case .directory:
                entries.append(
                    FileManifestEntry(
                        path: relativePath,
                        kind: .directory,
                        executable: false,
                        mode: mode,
                        codeUnitIdentifier: codeUnitPath(for: relativePath)
                    )
                )
            case .symlink:
                entries.append(
                    FileManifestEntry(
                        path: relativePath,
                        kind: .symlink,
                        executable: false,
                        mode: mode,
                        symlinkDestination: try fileManager.destinationOfSymbolicLink(atPath: itemURL.path),
                        codeUnitIdentifier: codeUnitPath(for: relativePath)
                    )
                )
            }
        }

        return TargetFileManifest(
            releaseID: metadata.releaseID,
            bundleIdentifier: metadata.bundleIdentifier,
            teamIdentifier: metadata.teamIdentifier,
            generatedAt: metadata.generatedAt,
            entries: entries.sorted(by: ReleaseFileSystem.sortEntriesForStaging)
        )
    }

    private func codeUnitPath(for relativePath: String) -> String {
        let components = relativePath.split(separator: "/").map(String.init)
        for index in components.indices.reversed() {
            let component = components[index]
            if component.hasSuffix(".app")
                || component.hasSuffix(".xpc")
                || component.hasSuffix(".appex")
                || component.hasSuffix(".framework")
                || component.hasSuffix(".bundle")
                || component.hasSuffix(".plugin") {
                return components[...index].joined(separator: "/")
            }
        }
        return "root"
    }
}

enum ReleasePath {
    static func validateBundleRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw ReleaseGeneratorError.invalidRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ReleaseGeneratorError.invalidRelativePath(path)
        }
    }
}

enum ReleaseFileSystem {
    static func lstatInfo(at url: URL) throws -> stat {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return statInfo
    }

    static func bundleEntryKind(for mode: mode_t, path: String) throws -> BundleEntryKind {
        switch mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFREG:
            return .file
        case S_IFLNK:
            return .symlink
        default:
            throw ReleaseGeneratorError.unsupportedFileKind(path)
        }
    }

    static func sortEntriesForStaging(_ left: FileManifestEntry, _ right: FileManifestEntry) -> Bool {
        if left.path == right.path {
            return false
        }
        let leftDepth = left.path.split(separator: "/").count
        let rightDepth = right.path.split(separator: "/").count
        if leftDepth != rightDepth {
            return leftDepth < rightDepth
        }
        return left.path < right.path
    }
}
