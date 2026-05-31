// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public enum UpdateStagingSource: Equatable, Sendable {
    case delta
    case fullArchive
}

public struct StagedUpdate: Equatable, Sendable {
    public let appURL: URL
    public let source: UpdateStagingSource

    public init(appURL: URL, source: UpdateStagingSource) {
        self.appURL = appURL
        self.source = source
    }
}

public protocol FullArchiveExtracting {
    func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws -> URL
}

public struct DittoFullArchiveExtractor: FullArchiveExtracting {
    public init() {}

    public func extractArchive(at archiveURL: URL, to destinationDirectory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archiveURL.path, destinationDirectory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            throw UpdaterCoreError.verificationFailed(output)
        }

        let appURLs = try FileManager.default.contentsOfDirectory(
            at: destinationDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "app" }
        guard let appURL = appURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first else {
            throw UpdaterCoreError.archiveUnavailable
        }
        return appURL
    }
}

public struct UpdateAssetLocator: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func url(for storageKey: String) -> URL {
        storageKey
            .split(separator: "/", omittingEmptySubsequences: true)
            .reduce(baseURL) { url, component in
                url.appendingPathComponent(String(component))
            }
    }
}

public struct UpdaterCore {
    public var policy: UpdateEligibilityPolicy
    public var assetFetcher: UpdateAssetFetching
    public var bundleVerifier: StagedBundleVerifying
    public var stateStore: UpdateDownloadStateStore
    public var archiveExtractor: FullArchiveExtracting
    public var fileManager: FileManager
    public var maxRetryCount: Int
    public var fullArchiveFallbackRatio: Double

    public init(
        policy: UpdateEligibilityPolicy,
        assetFetcher: UpdateAssetFetching = URLSessionUpdateAssetFetcher(),
        bundleVerifier: StagedBundleVerifying = ProcessStagedBundleVerifier(),
        stateStore: UpdateDownloadStateStore,
        archiveExtractor: FullArchiveExtracting = DittoFullArchiveExtractor(),
        fileManager: FileManager = .default,
        maxRetryCount: Int = 2,
        fullArchiveFallbackRatio: Double = 0.85
    ) {
        self.policy = policy
        self.assetFetcher = assetFetcher
        self.bundleVerifier = bundleVerifier
        self.stateStore = stateStore
        self.archiveExtractor = archiveExtractor
        self.fileManager = fileManager
        self.maxRetryCount = maxRetryCount
        self.fullArchiveFallbackRatio = fullArchiveFallbackRatio
    }

    public func validateRelease(
        releaseManifest: ReleaseManifest,
        installedApp: InstalledAppState
    ) throws -> UpdateDecision {
        try policy.validate(releaseManifest: releaseManifest, installedApp: installedApp)
    }

    public func stageUpdate(
        releaseManifest: ReleaseManifest,
        installedApp: InstalledAppState,
        baseAppURL: URL,
        deltaManifest: DeltaManifest?,
        targetManifest: TargetFileManifest,
        assetLocator: UpdateAssetLocator,
        stagingDirectory: URL
    ) async throws -> StagedUpdate {
        _ = try validateRelease(releaseManifest: releaseManifest, installedApp: installedApp)
        if let deltaManifest, shouldUseDelta(deltaManifest: deltaManifest, fullArchive: releaseManifest.fullArchive) {
            do {
                let stagedAppURL = try await stageDelta(
                    deltaManifest: deltaManifest,
                    targetManifest: targetManifest,
                    baseAppURL: baseAppURL,
                    assetLocator: assetLocator,
                    stagingDirectory: stagingDirectory
                )
                return StagedUpdate(appURL: stagedAppURL, source: .delta)
            } catch {
                let stagedAppURL = try await stageFullArchive(
                    releaseManifest: releaseManifest,
                    targetManifest: targetManifest,
                    assetLocator: assetLocator,
                    stagingDirectory: stagingDirectory
                )
                return StagedUpdate(appURL: stagedAppURL, source: .fullArchive)
            }
        }

        let stagedAppURL = try await stageFullArchive(
            releaseManifest: releaseManifest,
            targetManifest: targetManifest,
            assetLocator: assetLocator,
            stagingDirectory: stagingDirectory
        )
        return StagedUpdate(appURL: stagedAppURL, source: .fullArchive)
    }

    public func stageDelta(
        deltaManifest: DeltaManifest,
        targetManifest: TargetFileManifest,
        baseAppURL: URL,
        assetLocator: UpdateAssetLocator,
        stagingDirectory: URL
    ) async throws -> URL {
        let stagedAppURL = stagingDirectory.appendingPathComponent("\(deltaManifest.targetReleaseID.buildNumber)-staged.app")
        try prepareStagingDirectory(stagedAppURL, targetBuild: deltaManifest.targetReleaseID.buildNumber)

        for operation in deltaManifest.operations {
            try Task.checkCancellation()
            try UpdaterPath.validateBundleRelativePath(operation.path)
            switch operation.kind {
            case .copyFromBase:
                try copyFromBase(operation: operation, baseAppURL: baseAppURL, stagedAppURL: stagedAppURL)
            case .downloadFile:
                try await downloadFile(
                    operation: operation,
                    assetLocator: assetLocator,
                    stagedAppURL: stagedAppURL,
                    targetBuild: deltaManifest.targetReleaseID.buildNumber
                )
            case .setSymlink:
                try setSymlink(operation: operation, stagedAppURL: stagedAppURL)
            case .delete:
                try deletePath(operation.path, stagedAppURL: stagedAppURL)
            case .setMode:
                try setMode(operation: operation, stagedAppURL: stagedAppURL)
            }
        }

        try pruneExtraPaths(in: stagedAppURL, targetManifest: targetManifest)
        try verifyFiles(in: stagedAppURL, targetManifest: targetManifest)
        try verifyStagedApp(at: stagedAppURL, targetManifest: targetManifest)
        return stagedAppURL
    }

    public func stageFullArchive(
        releaseManifest: ReleaseManifest,
        targetManifest: TargetFileManifest,
        assetLocator: UpdateAssetLocator,
        stagingDirectory: URL
    ) async throws -> URL {
        guard let fullArchive = releaseManifest.fullArchive else {
            throw UpdaterCoreError.archiveUnavailable
        }
        let archiveData = try await fetchWithRetry(at: assetLocator.url(for: fullArchive.storageKey))
        let actualArchiveSHA = SHA256Digest.hex(for: archiveData)
        guard actualArchiveSHA == fullArchive.sha256 else {
            throw UpdaterCoreError.checksumMismatch(
                path: fullArchive.storageKey,
                expected: fullArchive.sha256,
                actual: actualArchiveSHA
            )
        }

        let archiveURL = stagingDirectory.appendingPathComponent("full-\(fullArchive.sha256).zip")
        let extractionDirectory = stagingDirectory.appendingPathComponent("full-\(releaseManifest.buildNumber)")
        if fileManager.fileExists(atPath: extractionDirectory.path) {
            try fileManager.removeItem(at: extractionDirectory)
        }
        try fileManager.createDirectory(at: archiveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try archiveData.write(to: archiveURL, options: .atomic)
        let stagedAppURL = try archiveExtractor.extractArchive(at: archiveURL, to: extractionDirectory)
        try verifyFiles(in: stagedAppURL, targetManifest: targetManifest)
        try verifyStagedApp(at: stagedAppURL, targetManifest: targetManifest)
        return stagedAppURL
    }

    private func shouldUseDelta(deltaManifest: DeltaManifest, fullArchive: FullArchiveMetadata?) -> Bool {
        guard let fullArchive, fullArchive.size > 0 else {
            return true
        }
        let deltaBytes = deltaManifest.requiredPayloads.reduce(Int64(0)) { $0 + $1.compressedSize }
        return Double(deltaBytes) <= Double(fullArchive.size) * fullArchiveFallbackRatio
    }

    private func prepareStagingDirectory(_ stagedAppURL: URL, targetBuild: Int) throws {
        let state = try stateStore.load()
        if state?.targetBuild != targetBuild, fileManager.fileExists(atPath: stagedAppURL.path) {
            try fileManager.removeItem(at: stagedAppURL)
        }
        try fileManager.createDirectory(at: stagedAppURL, withIntermediateDirectories: true)
    }

    private func copyFromBase(operation: DeltaOperation, baseAppURL: URL, stagedAppURL: URL) throws {
        let sourceURL = baseAppURL.appendingPathComponent(operation.path)
        let targetURL = stagedAppURL.appendingPathComponent(operation.path)
        try UpdaterFileSystem.createParentDirectory(for: targetURL, fileManager: fileManager)
        let kind = try UpdaterFileSystem.kind(at: sourceURL)
        if fileManager.fileExists(atPath: targetURL.path) || kind == .symlink {
            try? fileManager.removeItem(at: targetURL)
        }

        switch kind {
        case .directory:
            try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        case .file:
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        case .symlink:
            let destination = try fileManager.destinationOfSymbolicLink(atPath: sourceURL.path)
            try fileManager.createSymbolicLink(atPath: targetURL.path, withDestinationPath: destination)
        }

        if let mode = operation.mode, kind != .symlink {
            try UpdaterFileSystem.setPermissions(mode, at: targetURL, fileManager: fileManager)
        }
    }

    private func downloadFile(
        operation: DeltaOperation,
        assetLocator: UpdateAssetLocator,
        stagedAppURL: URL,
        targetBuild: Int
    ) async throws {
        guard let payload = operation.payload else {
            throw UpdaterCoreError.missingPayload(operation.path)
        }
        let targetURL = stagedAppURL.appendingPathComponent(operation.path)
        let state = try stateStore.load()
        if state?.targetBuild == targetBuild,
           state?.completedPayloads[operation.path] == payload.uncompressedSHA256,
           fileManager.fileExists(atPath: targetURL.path),
           try SHA256Digest.hex(forFileAt: targetURL) == payload.uncompressedSHA256 {
            return
        }

        let encodedData = try await fetchWithRetry(at: assetLocator.url(for: payload.storageKey))
        let encodedSHA = SHA256Digest.hex(for: encodedData)
        guard encodedSHA == payload.compressedSHA256 else {
            throw UpdaterCoreError.checksumMismatch(
                path: payload.storageKey,
                expected: payload.compressedSHA256,
                actual: encodedSHA
            )
        }
        let decodedData = try UpdatePayloadCodec.decoded(encodedData, compression: payload.compression)
        let decodedSHA = SHA256Digest.hex(for: decodedData)
        guard decodedSHA == payload.uncompressedSHA256 else {
            throw UpdaterCoreError.checksumMismatch(
                path: operation.path,
                expected: payload.uncompressedSHA256,
                actual: decodedSHA
            )
        }

        try UpdaterFileSystem.createParentDirectory(for: targetURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try decodedData.write(to: targetURL, options: .atomic)
        if let mode = operation.mode {
            try UpdaterFileSystem.setPermissions(mode, at: targetURL, fileManager: fileManager)
        }
        try stateStore.markCompleted(path: operation.path, sha256: payload.uncompressedSHA256, targetBuild: targetBuild)
    }

    private func setSymlink(operation: DeltaOperation, stagedAppURL: URL) throws {
        guard let destination = operation.symlinkDestination else {
            throw UpdaterCoreError.verificationFailed("Missing symlink destination for \(operation.path).")
        }
        let targetURL = stagedAppURL.appendingPathComponent(operation.path)
        try UpdaterFileSystem.createParentDirectory(for: targetURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: targetURL.path) || (try? UpdaterFileSystem.kind(at: targetURL)) == .symlink {
            try? fileManager.removeItem(at: targetURL)
        }
        try fileManager.createSymbolicLink(atPath: targetURL.path, withDestinationPath: destination)
    }

    private func deletePath(_ path: String, stagedAppURL: URL) throws {
        let targetURL = stagedAppURL.appendingPathComponent(path)
        if fileManager.fileExists(atPath: targetURL.path) || (try? UpdaterFileSystem.kind(at: targetURL)) == .symlink {
            try fileManager.removeItem(at: targetURL)
        }
    }

    private func setMode(operation: DeltaOperation, stagedAppURL: URL) throws {
        guard let mode = operation.mode else {
            return
        }
        try UpdaterFileSystem.setPermissions(mode, at: stagedAppURL.appendingPathComponent(operation.path), fileManager: fileManager)
    }

    private func fetchWithRetry(at url: URL) async throws -> Data {
        var latestError: Error?
        for attempt in 0...maxRetryCount {
            do {
                return try await assetFetcher.fetchData(at: url)
            } catch {
                latestError = error
                if attempt == maxRetryCount {
                    break
                }
            }
        }
        throw latestError ?? UpdaterCoreError.missingPayload(url.path)
    }

    private func verifyFiles(in stagedAppURL: URL, targetManifest: TargetFileManifest) throws {
        for entry in targetManifest.entries {
            try UpdaterPath.validateBundleRelativePath(entry.path)
            let url = stagedAppURL.appendingPathComponent(entry.path)
            let kind = try UpdaterFileSystem.kind(at: url)
            guard kind == entry.kind else {
                throw UpdaterCoreError.fileKindMismatch(entry.path)
            }

            switch entry.kind {
            case .file:
                guard let expectedHash = entry.sha256 else {
                    throw UpdaterCoreError.missingPayload(entry.path)
                }
                let actualHash = try SHA256Digest.hex(forFileAt: url)
                guard actualHash == expectedHash else {
                    throw UpdaterCoreError.checksumMismatch(path: entry.path, expected: expectedHash, actual: actualHash)
                }
                if let mode = entry.mode {
                    try verifyMode(mode, at: url, path: entry.path)
                }
            case .directory:
                if let mode = entry.mode {
                    try verifyMode(mode, at: url, path: entry.path)
                }
            case .symlink:
                let destination = try fileManager.destinationOfSymbolicLink(atPath: url.path)
                guard destination == entry.symlinkDestination else {
                    throw UpdaterCoreError.verificationFailed("Symlink destination mismatch for \(entry.path).")
                }
            }
        }
    }

    private func verifyMode(_ expectedMode: UInt16, at url: URL, path: String) throws {
        let actualMode = try UpdaterFileSystem.mode(at: url)
        guard actualMode == expectedMode else {
            throw UpdaterCoreError.modeMismatch(path: path, expected: expectedMode, actual: actualMode)
        }
    }

    private func pruneExtraPaths(in stagedAppURL: URL, targetManifest: TargetFileManifest) throws {
        guard let enumerator = fileManager.enumerator(at: stagedAppURL, includingPropertiesForKeys: nil) else {
            return
        }
        let expectedPaths = expectedPathsIncludingAncestors(for: targetManifest)
        let rootPath = stagedAppURL.standardizedFileURL.path
        var extraURLs: [URL] = []
        for case let itemURL as URL in enumerator {
            let itemPath = itemURL.standardizedFileURL.path
            guard itemPath.hasPrefix(rootPath + "/") else {
                continue
            }
            let relativePath = String(itemPath.dropFirst(rootPath.count + 1))
            if !expectedPaths.contains(relativePath) {
                extraURLs.append(itemURL)
            }
        }
        for url in extraURLs.sorted(by: { $0.path.count > $1.path.count }) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func expectedPathsIncludingAncestors(for targetManifest: TargetFileManifest) -> Set<String> {
        var paths = Set(targetManifest.entries.map(\.path))
        for path in targetManifest.entries.map(\.path) {
            var components = path.split(separator: "/").map(String.init)
            while components.count > 1 {
                components.removeLast()
                paths.insert(components.joined(separator: "/"))
            }
        }
        return paths
    }

    private func verifyStagedApp(at stagedAppURL: URL, targetManifest: TargetFileManifest) throws {
        try bundleVerifier.verifyStagedApp(
            at: stagedAppURL,
            context: StagedBundleVerificationContext(
                expectedBundleIdentifier: targetManifest.bundleIdentifier,
                expectedTeamIdentifier: targetManifest.teamIdentifier
            )
        )
    }
}
