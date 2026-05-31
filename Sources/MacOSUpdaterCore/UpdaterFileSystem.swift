// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Darwin
import Foundation
import MacOSUpdaterManifest

enum UpdaterPath {
    static func validateBundleRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/") else {
            throw UpdaterCoreError.invalidRelativePath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw UpdaterCoreError.invalidRelativePath(path)
        }
    }
}

enum UpdaterFileSystem {
    static func lstatInfo(at url: URL) throws -> stat {
        var statInfo = stat()
        guard lstat(url.path, &statInfo) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return statInfo
    }

    static func kind(at url: URL) throws -> BundleEntryKind {
        switch try lstatInfo(at: url).st_mode & S_IFMT {
        case S_IFDIR:
            return .directory
        case S_IFLNK:
            return .symlink
        default:
            return .file
        }
    }

    static func mode(at url: URL) throws -> UInt16 {
        UInt16(try lstatInfo(at: url).st_mode & 0o777)
    }

    static func setPermissions(_ mode: UInt16, at url: URL, fileManager: FileManager) throws {
        try fileManager.setAttributes([.posixPermissions: Int(mode)], ofItemAtPath: url.path)
    }

    static func createParentDirectory(for url: URL, fileManager: FileManager) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    static func fsyncParentDirectory(of url: URL) {
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else {
            return
        }
        _ = fsync(descriptor)
        _ = close(descriptor)
    }
}
