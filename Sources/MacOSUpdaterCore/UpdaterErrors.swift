// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation

public enum UpdaterCoreError: Error, Equatable, LocalizedError {
    case invalidRelativePath(String)
    case missingPayload(String)
    case checksumMismatch(path: String, expected: String, actual: String)
    case fileKindMismatch(String)
    case modeMismatch(path: String, expected: UInt16, actual: UInt16)
    case unsupportedCompression(String)
    case verificationFailed(String)
    case archiveUnavailable
    case permissionDenied(String)
    case sameVolumeRequired

    public var errorDescription: String? {
        switch self {
        case .invalidRelativePath(let path):
            return "Invalid bundle-relative update path: \(path)."
        case .missingPayload(let path):
            return "Missing update payload for \(path)."
        case .checksumMismatch(let path, let expected, let actual):
            return "Checksum mismatch for \(path): expected \(expected), got \(actual)."
        case .fileKindMismatch(let path):
            return "Unexpected file kind for \(path)."
        case .modeMismatch(let path, let expected, let actual):
            return "Mode mismatch for \(path): expected \(expected), got \(actual)."
        case .unsupportedCompression(let compression):
            return "Unsupported update payload compression: \(compression)."
        case .verificationFailed(let message):
            return message
        case .archiveUnavailable:
            return "Full archive fallback is unavailable."
        case .permissionDenied(let path):
            return "Install location is not writable: \(path)."
        case .sameVolumeRequired:
            return "Installed, staged, and backup app paths must be on the same volume."
        }
    }
}
