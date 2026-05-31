// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest

public struct StagedBundleVerificationContext: Equatable, Sendable {
    public let expectedBundleIdentifier: String
    public let expectedTeamIdentifier: String

    public init(expectedBundleIdentifier: String, expectedTeamIdentifier: String) {
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.expectedTeamIdentifier = expectedTeamIdentifier
    }
}

public protocol StagedBundleVerifying {
    func verifyStagedApp(at url: URL, context: StagedBundleVerificationContext) throws
}

public struct ProcessStagedBundleVerifier: StagedBundleVerifying {
    public init() {}

    public func verifyStagedApp(at url: URL, context: StagedBundleVerificationContext) throws {
        try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", "--verbose=4", url.path])
        try run("/usr/sbin/spctl", arguments: ["-a", "-t", "exec", "-vv", url.path])
        try run("/usr/bin/xcrun", arguments: ["stapler", "validate", url.path])
        try verifyBundleIdentifier(at: url, expectedBundleIdentifier: context.expectedBundleIdentifier)
        try verifyTeamIdentifier(at: url, expectedTeamIdentifier: context.expectedTeamIdentifier)
    }

    private func verifyBundleIdentifier(at url: URL, expectedBundleIdentifier: String) throws {
        let infoPlistURL = url.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: infoPlistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dictionary = plist as? [String: Any],
            let actualBundleIdentifier = dictionary["CFBundleIdentifier"] as? String
        else {
            throw UpdaterCoreError.verificationFailed("Unable to read CFBundleIdentifier from \(infoPlistURL.path).")
        }

        guard actualBundleIdentifier == expectedBundleIdentifier else {
            throw UpdaterCoreError.verificationFailed(
                "Bundle identifier mismatch: expected \(expectedBundleIdentifier), got \(actualBundleIdentifier)."
            )
        }
    }

    private func verifyTeamIdentifier(at url: URL, expectedTeamIdentifier: String) throws {
        let output = try run("/usr/bin/codesign", arguments: ["-dv", "--verbose=4", url.path])
        guard let actualTeamIdentifier = output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })?
            .split(separator: "=", maxSplits: 1)
            .last
            .map(String.init)
        else {
            throw UpdaterCoreError.verificationFailed("Unable to read TeamIdentifier from \(url.path).")
        }

        guard actualTeamIdentifier == expectedTeamIdentifier else {
            throw UpdaterCoreError.verificationFailed(
                "Team identifier mismatch: expected \(expectedTeamIdentifier), got \(actualTeamIdentifier)."
            )
        }
    }

    @discardableResult
    private func run(_ executablePath: String, arguments: [String]) throws -> String {
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
            throw UpdaterCoreError.verificationFailed(output)
        }
        return output
    }
}

public struct AcceptingStagedBundleVerifier: StagedBundleVerifying {
    public init() {}

    public func verifyStagedApp(at url: URL, context: StagedBundleVerificationContext) throws {}
}
