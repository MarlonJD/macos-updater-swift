// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Darwin
import Foundation
import MacOSUpdaterManifest

public struct UpdateInstallRequest: Codable, Equatable, Sendable {
    public let installedAppPath: String
    public let stagedAppPath: String
    public let backupAppPath: String
    public let mainAppPID: Int32
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let targetReleaseID: ReleaseID
    public let launchToken: String
    public let logDirectoryPath: String

    public init(
        installedAppPath: String,
        stagedAppPath: String,
        backupAppPath: String,
        mainAppPID: Int32,
        bundleIdentifier: String,
        teamIdentifier: String,
        targetReleaseID: ReleaseID,
        launchToken: String,
        logDirectoryPath: String
    ) {
        self.installedAppPath = installedAppPath
        self.stagedAppPath = stagedAppPath
        self.backupAppPath = backupAppPath
        self.mainAppPID = mainAppPID
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.targetReleaseID = targetReleaseID
        self.launchToken = launchToken
        self.logDirectoryPath = logDirectoryPath
    }
}

public enum UpdateInstallStatus: String, Codable, Equatable, Sendable {
    case installed
    case rolledBack
    case permissionDenied
    case abandoned
}

public struct UpdateInstallResult: Codable, Equatable, Sendable {
    public let status: UpdateInstallStatus
    public let message: String

    public init(status: UpdateInstallStatus, message: String) {
        self.status = status
        self.message = message
    }
}

public protocol UpdateProcessWaiting {
    func waitForExit(pid: Int32) throws
}

public protocol UpdateApplicationLaunching {
    func launchApplication(at url: URL, arguments: [String]) throws
}

public struct PollingUpdateProcessWaiter: UpdateProcessWaiting {
    public var pollInterval: TimeInterval
    public var timeout: TimeInterval

    public init(pollInterval: TimeInterval = 0.2, timeout: TimeInterval = 120) {
        self.pollInterval = pollInterval
        self.timeout = timeout
    }

    public func waitForExit(pid: Int32) throws {
        if pid <= 0 {
            return
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 && errno == ESRCH {
                return
            }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        throw UpdaterCoreError.verificationFailed("Timed out waiting for PID \(pid) to exit.")
    }
}

public struct OpenCommandApplicationLauncher: UpdateApplicationLaunching {
    public init() {}

    public func launchApplication(at url: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", url.path, "--args"] + arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterCoreError.verificationFailed("Failed to launch \(url.path).")
        }
    }
}

public struct UpdateInstaller {
    public var fileManager: FileManager
    public var waiter: UpdateProcessWaiting
    public var launcher: UpdateApplicationLaunching
    public var bundleVerifier: StagedBundleVerifying

    public init(
        fileManager: FileManager = .default,
        waiter: UpdateProcessWaiting = PollingUpdateProcessWaiter(),
        launcher: UpdateApplicationLaunching = OpenCommandApplicationLauncher(),
        bundleVerifier: StagedBundleVerifying = ProcessStagedBundleVerifier()
    ) {
        self.fileManager = fileManager
        self.waiter = waiter
        self.launcher = launcher
        self.bundleVerifier = bundleVerifier
    }

    public func performInstall(request: UpdateInstallRequest) throws -> UpdateInstallResult {
        let installedURL = URL(fileURLWithPath: request.installedAppPath)
        let stagedURL = URL(fileURLWithPath: request.stagedAppPath)
        let backupURL = URL(fileURLWithPath: request.backupAppPath)
        let logger = UpdateInstallLogger(
            directoryURL: URL(fileURLWithPath: request.logDirectoryPath),
            fileManager: fileManager
        )
        let verificationContext = StagedBundleVerificationContext(
            expectedBundleIdentifier: request.bundleIdentifier,
            expectedTeamIdentifier: request.teamIdentifier
        )

        try logger.append("Waiting for PID \(request.mainAppPID) before installing \(request.targetReleaseID).")
        try waiter.waitForExit(pid: request.mainAppPID)

        guard fileManager.fileExists(atPath: stagedURL.path) else {
            try logger.append("Staged app missing at \(stagedURL.path).")
            return UpdateInstallResult(status: .abandoned, message: "Staged app is missing.")
        }

        let installedParent = installedURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: installedParent.path) else {
            try logger.append("Install parent is not writable: \(installedParent.path).")
            return UpdateInstallResult(status: .permissionDenied, message: "Install location is not writable.")
        }

        guard try sameVolume(installedParent, stagedURL.deletingLastPathComponent()),
              try sameVolume(installedParent, backupURL.deletingLastPathComponent()) else {
            try logger.append("Install, staged, and backup paths are not on the same volume.")
            return UpdateInstallResult(status: .abandoned, message: "Install, staged, and backup paths must share a volume.")
        }

        try bundleVerifier.verifyStagedApp(at: stagedURL, context: verificationContext)

        var movedInstalledApp = false
        do {
            if fileManager.fileExists(atPath: backupURL.path) {
                try fileManager.removeItem(at: backupURL)
            }

            try fileManager.moveItem(at: installedURL, to: backupURL)
            movedInstalledApp = true
            UpdaterFileSystem.fsyncParentDirectory(of: backupURL)

            try fileManager.moveItem(at: stagedURL, to: installedURL)
            UpdaterFileSystem.fsyncParentDirectory(of: installedURL)
            try bundleVerifier.verifyStagedApp(at: installedURL, context: verificationContext)

            try launcher.launchApplication(
                at: installedURL,
                arguments: ["--update-complete", "--updated-build", "\(request.targetReleaseID.buildNumber)"]
            )
            try logger.append("Installed and relaunched \(request.targetReleaseID).")
            return UpdateInstallResult(status: .installed, message: "Update installed.")
        } catch {
            try logger.append("Install failed: \(error.localizedDescription)")
            if movedInstalledApp {
                try rollback(installedURL: installedURL, stagedURL: stagedURL, backupURL: backupURL, logger: logger)
                try launcher.launchApplication(at: installedURL, arguments: ["--update-rollback"])
                return UpdateInstallResult(status: .rolledBack, message: "Update rolled back.")
            }
            throw error
        }
    }

    private func rollback(
        installedURL: URL,
        stagedURL: URL,
        backupURL: URL,
        logger: UpdateInstallLogger
    ) throws {
        if fileManager.fileExists(atPath: installedURL.path) {
            let failedURL = stagedURL.deletingLastPathComponent().appendingPathComponent("failed-\(installedURL.lastPathComponent)")
            if fileManager.fileExists(atPath: failedURL.path) {
                try fileManager.removeItem(at: failedURL)
            }
            try fileManager.moveItem(at: installedURL, to: failedURL)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.moveItem(at: backupURL, to: installedURL)
            UpdaterFileSystem.fsyncParentDirectory(of: installedURL)
        }
        try logger.append("Rollback restored \(installedURL.path).")
    }

    private func sameVolume(_ left: URL, _ right: URL) throws -> Bool {
        let leftValues = try left.resourceValues(forKeys: [.volumeIdentifierKey])
        let rightValues = try right.resourceValues(forKeys: [.volumeIdentifierKey])
        guard let leftID = leftValues.volumeIdentifier, let rightID = rightValues.volumeIdentifier else {
            return true
        }
        return "\(leftID)" == "\(rightID)"
    }
}

private struct UpdateInstallLogger {
    var directoryURL: URL
    var fileManager: FileManager

    func append(_ message: String) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let logURL = directoryURL.appendingPathComponent("update-installer.log")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let data = Data(line.utf8)

        if fileManager.fileExists(atPath: logURL.path) {
            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: logURL, options: .atomic)
        }
    }
}
