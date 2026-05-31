// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public protocol ReleaseCommandRunning {
    func run(_ executablePath: String, arguments: [String]) throws -> String
}

public struct ProcessReleaseCommandRunner: ReleaseCommandRunning {
    public init() {}

    public func run(_ executablePath: String, arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ReleaseGeneratorError.invalidArchive(output)
        }
        return output
    }
}

public struct FullArchiveBuilder {
    public var fileManager: FileManager
    public var commandRunner: ReleaseCommandRunning

    public init(
        fileManager: FileManager = .default,
        commandRunner: ReleaseCommandRunning = ProcessReleaseCommandRunner()
    ) {
        self.fileManager = fileManager
        self.commandRunner = commandRunner
    }

    public func createZipArchive(
        appBundleURL: URL,
        releasePrefix: String,
        outputDirectory: URL
    ) throws -> FullArchiveMetadata {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appBundleURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReleaseGeneratorError.appBundleNotFound(appBundleURL.path)
        }

        let temporaryURL = outputDirectory
            .appendingPathComponent(releasePrefix)
            .appendingPathComponent("archives")
            .appendingPathComponent("archive-building.zip")
        try fileManager.createDirectory(at: temporaryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: temporaryURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        }

        _ = try commandRunner.run(
            "/usr/bin/ditto",
            arguments: [
                "-c",
                "-k",
                "--keepParent",
                "--sequesterRsrc",
                "--zlibCompressionLevel",
                "9",
                appBundleURL.path,
                temporaryURL.path
            ]
        )

        let sha256 = try SHA256Digest.hex(forFileAt: temporaryURL)
        let finalStorageKey = "\(releasePrefix)/archives/\(sha256).zip"
        let finalURL = outputDirectory.appendingPathComponent(finalStorageKey)
        try fileManager.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: finalURL)
        }

        let size = try fileManager.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber
        return FullArchiveMetadata(
            compression: .none,
            size: size?.int64Value ?? 0,
            sha256: sha256,
            storageKey: finalStorageKey,
            notarized: true,
            stapled: true
        )
    }
}
