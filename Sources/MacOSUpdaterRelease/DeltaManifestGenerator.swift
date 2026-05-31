// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct GeneratedPayload: Codable, Equatable, Sendable {
    public let entryPath: String
    public let metadata: CompressedPayloadMetadata

    public init(entryPath: String, metadata: CompressedPayloadMetadata) {
        self.entryPath = entryPath
        self.metadata = metadata
    }
}

public struct GeneratedDelta: Codable, Equatable, Sendable {
    public let manifest: DeltaManifest
    public let payloads: [GeneratedPayload]

    public init(manifest: DeltaManifest, payloads: [GeneratedPayload]) {
        self.manifest = manifest
        self.payloads = payloads
    }
}

public struct DeltaManifestGenerator {
    public var fileManager: FileManager
    public var compression: PayloadCompression

    public init(fileManager: FileManager = .default, compression: PayloadCompression = .lzfse) {
        self.fileManager = fileManager
        self.compression = compression
    }

    public func makeDelta(
        baseManifest: TargetFileManifest,
        targetManifest: TargetFileManifest,
        targetAppURL: URL,
        releasePrefix: String
    ) throws -> GeneratedDelta {
        let baseEntries = Dictionary(uniqueKeysWithValues: baseManifest.entries.map { ($0.path, $0) })
        let targetEntries = Dictionary(uniqueKeysWithValues: targetManifest.entries.map { ($0.path, $0) })
        var operations: [DeltaOperation] = []
        var payloads: [GeneratedPayload] = []
        var changedPaths = Set<String>()

        for targetEntry in targetManifest.entries.sorted(by: ReleaseFileSystem.sortEntriesForStaging) {
            if let baseEntry = baseEntries[targetEntry.path], baseEntry == targetEntry {
                operations.append(copyOperation(for: targetEntry))
                continue
            }

            changedPaths.insert(targetEntry.path)
            let operation = try changedOperation(for: targetEntry, targetAppURL: targetAppURL, releasePrefix: releasePrefix)
            operations.append(operation.operation)
            if let payload = operation.payload {
                payloads.append(payload)
            }
        }

        for baseEntry in baseManifest.entries where targetEntries[baseEntry.path] == nil {
            operations.append(DeltaOperation(kind: .delete, path: baseEntry.path))
        }

        try validateSignatureSidecars(
            baseEntries: baseEntries,
            targetEntries: targetEntries,
            changedPaths: changedPaths
        )

        return GeneratedDelta(
            manifest: DeltaManifest(
                baseReleaseID: baseManifest.releaseID,
                targetReleaseID: targetManifest.releaseID,
                operations: operations.sorted(by: sortOperations)
            ),
            payloads: payloads.sorted { $0.metadata.storageKey < $1.metadata.storageKey }
        )
    }

    public func writePayloads(_ payloads: [GeneratedPayload], to outputDirectory: URL) throws {
        for payload in payloads {
            let destinationURL = outputDirectory.appendingPathComponent(payload.metadata.storageKey)
            if fileManager.fileExists(atPath: destinationURL.path) {
                continue
            }
            guard let data = payload.encodedPayloadData else {
                throw ReleaseGeneratorError.missingPayload(payload.entryPath)
            }
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destinationURL, options: .atomic)
        }
    }

    private func changedOperation(
        for entry: FileManifestEntry,
        targetAppURL: URL,
        releasePrefix: String
    ) throws -> (operation: DeltaOperation, payload: GeneratedPayload?) {
        switch entry.kind {
        case .file:
            guard let expectedSHA256 = entry.sha256, let uncompressedSize = entry.size else {
                throw ReleaseGeneratorError.missingPayload(entry.path)
            }
            let sourceURL = targetAppURL.appendingPathComponent(entry.path)
            let uncompressedData = try Data(contentsOf: sourceURL)
            let encodedData = try ReleasePayloadCodec.encode(uncompressedData, compression: compression)
            let compressedSHA256 = SHA256Digest.hex(for: encodedData)
            let storageKey = "\(releasePrefix)/payloads/\(payloadPathComponent(for: compressedSHA256)).\(compression.rawValue)"
            let metadata = CompressedPayloadMetadata(
                compression: compression,
                compressedSize: Int64(encodedData.count),
                compressedSHA256: compressedSHA256,
                uncompressedSize: uncompressedSize,
                uncompressedSHA256: expectedSHA256,
                storageKey: storageKey
            )
            return (
                DeltaOperation(
                    kind: .downloadFile,
                    path: entry.path,
                    payload: metadata,
                    expectedSHA256: expectedSHA256,
                    mode: entry.mode,
                    symlinkDestination: nil
                ),
                GeneratedPayload(entryPath: entry.path, metadata: metadata, encodedPayloadData: encodedData)
            )
        case .directory:
            return (copyOperation(for: entry), nil)
        case .symlink:
            return (
                DeltaOperation(
                    kind: .setSymlink,
                    path: entry.path,
                    mode: entry.mode,
                    symlinkDestination: entry.symlinkDestination
                ),
                nil
            )
        }
    }

    private func copyOperation(for entry: FileManifestEntry) -> DeltaOperation {
        DeltaOperation(
            kind: .copyFromBase,
            path: entry.path,
            expectedSHA256: entry.sha256,
            mode: entry.mode,
            symlinkDestination: entry.symlinkDestination
        )
    }

    private func validateSignatureSidecars(
        baseEntries: [String: FileManifestEntry],
        targetEntries: [String: FileManifestEntry],
        changedPaths: Set<String>
    ) throws {
        let changedSealedPaths = changedPaths.filter { !$0.contains("/_CodeSignature/") }
        let requiredSidecars = Set(changedSealedPaths.compactMap { signatureSidecarPath(for: $0, targetEntries: targetEntries) })

        for sidecarPath in requiredSidecars where !changedPaths.contains(sidecarPath) {
            if baseEntries[sidecarPath] == targetEntries[sidecarPath] {
                throw ReleaseGeneratorError.missingSignatureSidecar(sidecarPath)
            }
            throw ReleaseGeneratorError.missingSignatureSidecar(sidecarPath)
        }
    }

    private func signatureSidecarPath(
        for relativePath: String,
        targetEntries: [String: FileManifestEntry]
    ) -> String? {
        let components = relativePath.split(separator: "/").map(String.init)
        for index in components.indices.reversed() {
            let component = components[index]
            if component.hasSuffix(".app") || component.hasSuffix(".xpc") || component.hasSuffix(".appex") {
                let bundlePath = components[...index].joined(separator: "/")
                let sidecarPath = "\(bundlePath)/Contents/_CodeSignature/CodeResources"
                if targetEntries[sidecarPath] != nil {
                    return sidecarPath
                }
            }
            if component.hasSuffix(".framework") || component.hasSuffix(".bundle") || component.hasSuffix(".plugin") {
                let bundlePath = components[...index].joined(separator: "/")
                let sidecarPath = "\(bundlePath)/_CodeSignature/CodeResources"
                if targetEntries[sidecarPath] != nil {
                    return sidecarPath
                }
            }
        }

        return targetEntries["Contents/_CodeSignature/CodeResources"] == nil
            ? nil
            : "Contents/_CodeSignature/CodeResources"
    }

    private func sortOperations(_ left: DeltaOperation, _ right: DeltaOperation) -> Bool {
        if left.kind == .delete && right.kind != .delete {
            return false
        }
        if left.kind != .delete && right.kind == .delete {
            return true
        }
        let leftDepth = left.path.split(separator: "/").count
        let rightDepth = right.path.split(separator: "/").count
        if leftDepth != rightDepth {
            return leftDepth < rightDepth
        }
        return left.path < right.path
    }

    private func payloadPathComponent(for sha256: String) -> String {
        let normalized = sha256.lowercased()
        let firstBreak = normalized.index(normalized.startIndex, offsetBy: 2)
        let secondBreak = normalized.index(normalized.startIndex, offsetBy: 4)
        return "\(normalized[..<firstBreak])/\(normalized[firstBreak..<secondBreak])/\(normalized)"
    }
}

private extension GeneratedPayload {
    init(entryPath: String, metadata: CompressedPayloadMetadata, encodedPayloadData: Data) {
        self.init(entryPath: entryPath, metadata: metadata)
        PayloadDataStore.shared.set(encodedPayloadData, for: metadata.storageKey)
    }

    var encodedPayloadData: Data? {
        PayloadDataStore.shared.data(for: metadata.storageKey)
    }
}

private final class PayloadDataStore: @unchecked Sendable {
    static let shared = PayloadDataStore()
    private var values: [String: Data] = [:]
    private let lock = NSLock()

    func set(_ data: Data, for key: String) {
        lock.lock()
        values[key] = data
        lock.unlock()
    }

    func data(for key: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}
