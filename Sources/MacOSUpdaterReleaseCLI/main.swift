// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterManifest
import MacOSUpdaterRelease

enum ReleaseCLI {
    static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        guard let command = arguments.first else {
            printUsage()
            return
        }

        let options = parseOptions(Array(arguments.dropFirst()))
        switch command {
        case "changelog":
            guard
                let versionValue = options.firstValue(for: "version"),
                let commitsFile = options.firstValue(for: "commits-file")
            else {
                throw CLIError.invalidArguments("changelog requires --version and --commits-file")
            }
            let version = try SemanticVersion(versionValue)
            let commits = try String(contentsOfFile: commitsFile, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            print(ChangelogDraftGenerator().generate(version: version, commits: commits))

        case "state-next":
            guard
                let stateFile = options.firstValue(for: "state-file"),
                let channelValue = options.firstValue(for: "channel"),
                let channel = UpdateChannel(rawValue: channelValue),
                let versionValue = options.firstValue(for: "version")
            else {
                throw CLIError.invalidArguments("state-next requires --state-file, --channel, and --version")
            }
            let state = try ReleaseStateStore(fileURL: URL(fileURLWithPath: stateFile))
                .nextState(channel: channel, version: try SemanticVersion(versionValue))
            print(String(data: try ManifestCoding.prettyJSONData(for: state), encoding: .utf8) ?? "")

        case "plan-keys":
            guard
                let channelValue = options.firstValue(for: "channel"),
                let channel = UpdateChannel(rawValue: channelValue),
                let versionValue = options.firstValue(for: "version"),
                let buildValue = options.firstValue(for: "build"),
                let buildNumber = Int(buildValue)
            else {
                throw CLIError.invalidArguments("plan-keys requires --channel, --version, and --build")
            }
            let version = try SemanticVersion(versionValue)
            let baseBuildNumber = options.firstValue(for: "base-build").flatMap(Int.init)
            let payloadSHA256Values = options.values(for: "payload-sha256")
            let fullArchiveSHA256 = options.firstValue(for: "full-archive-sha256")
            let plan = DistributionKeyPlanner(
                bucketName: options.firstValue(for: "bucket") ?? "emsi-updates-prod"
            ).plan(
                channel: channel,
                version: version,
                buildNumber: buildNumber,
                baseBuildNumber: baseBuildNumber,
                payloadSHA256Values: payloadSHA256Values,
                fullArchiveSHA256: fullArchiveSHA256
            )
            print(plan.dryRunText())

        case "target-manifest":
            guard
                let appPath = options.firstValue(for: "app"),
                let outputPath = options.firstValue(for: "output"),
                let versionValue = options.firstValue(for: "version"),
                let buildValue = options.firstValue(for: "build"),
                let buildNumber = Int(buildValue),
                let bundleIdentifier = options.firstValue(for: "bundle-id"),
                let teamIdentifier = options.firstValue(for: "team-id")
            else {
                throw CLIError.invalidArguments("target-manifest requires --app, --output, --version, --build, --bundle-id, and --team-id")
            }
            let version = try SemanticVersion(versionValue)
            let manifest = try BundleManifestGenerator().makeTargetManifest(
                appBundleURL: URL(fileURLWithPath: appPath),
                metadata: BundleManifestMetadata(
                    releaseID: ReleaseID(version: version, buildNumber: buildNumber),
                    bundleIdentifier: bundleIdentifier,
                    teamIdentifier: teamIdentifier
                )
            )
            try writeJSON(manifest, to: URL(fileURLWithPath: outputPath))

        case "delta":
            guard
                let baseManifestPath = options.firstValue(for: "base-manifest"),
                let targetManifestPath = options.firstValue(for: "target-manifest"),
                let targetAppPath = options.firstValue(for: "target-app"),
                let outputDirectoryPath = options.firstValue(for: "output-dir"),
                let channelValue = options.firstValue(for: "channel"),
                let channel = UpdateChannel(rawValue: channelValue)
            else {
                throw CLIError.invalidArguments("delta requires --base-manifest, --target-manifest, --target-app, --output-dir, and --channel")
            }
            let baseManifest: TargetFileManifest = try readJSON(URL(fileURLWithPath: baseManifestPath))
            let targetManifest: TargetFileManifest = try readJSON(URL(fileURLWithPath: targetManifestPath))
            let prefix = releasePrefix(channel: channel, releaseID: targetManifest.releaseID)
            let generated = try DeltaManifestGenerator().makeDelta(
                baseManifest: baseManifest,
                targetManifest: targetManifest,
                targetAppURL: URL(fileURLWithPath: targetAppPath),
                releasePrefix: prefix
            )
            let outputDirectory = URL(fileURLWithPath: outputDirectoryPath)
            try DeltaManifestGenerator().writePayloads(generated.payloads, to: outputDirectory)
            try writeJSON(
                generated.manifest,
                to: outputDirectory
                    .appendingPathComponent(prefix)
                    .appendingPathComponent("delta-from-\(baseManifest.releaseID.buildNumber)-to-\(targetManifest.releaseID.buildNumber).json")
            )

        case "full-archive":
            guard
                let appPath = options.firstValue(for: "app"),
                let outputDirectoryPath = options.firstValue(for: "output-dir"),
                let channelValue = options.firstValue(for: "channel"),
                let channel = UpdateChannel(rawValue: channelValue),
                let versionValue = options.firstValue(for: "version"),
                let buildValue = options.firstValue(for: "build"),
                let buildNumber = Int(buildValue)
            else {
                throw CLIError.invalidArguments("full-archive requires --app, --output-dir, --channel, --version, and --build")
            }
            let releaseID = ReleaseID(version: try SemanticVersion(versionValue), buildNumber: buildNumber)
            let metadata = try FullArchiveBuilder().createZipArchive(
                appBundleURL: URL(fileURLWithPath: appPath),
                releasePrefix: releasePrefix(channel: channel, releaseID: releaseID),
                outputDirectory: URL(fileURLWithPath: outputDirectoryPath)
            )
            print(String(data: try ManifestCoding.prettyJSONData(for: metadata), encoding: .utf8) ?? "")

        case "release-manifest":
            guard
                let targetManifestPath = options.firstValue(for: "target-manifest"),
                let fullArchivePath = options.firstValue(for: "full-archive"),
                let outputPath = options.firstValue(for: "output"),
                let channelValue = options.firstValue(for: "channel"),
                let channel = UpdateChannel(rawValue: channelValue),
                let versionValue = options.firstValue(for: "version"),
                let buildValue = options.firstValue(for: "build"),
                let buildNumber = Int(buildValue),
                let minimumSystemVersion = options.firstValue(for: "minimum-system-version"),
                let minimumBuildValue = options.firstValue(for: "minimum-supported-build"),
                let minimumSupportedBuild = Int(minimumBuildValue),
                let commitSHA = options.firstValue(for: "commit-sha"),
                let changelogFile = options.firstValue(for: "changelog-file")
            else {
                throw CLIError.invalidArguments("release-manifest requires target manifest, full archive, channel, version, build, minimum versions, commit, changelog, and output")
            }
            let targetManifest: TargetFileManifest = try readJSON(URL(fileURLWithPath: targetManifestPath))
            let version = try SemanticVersion(versionValue)
            let releaseID = ReleaseID(version: version, buildNumber: buildNumber)
            let archiveURL = URL(fileURLWithPath: fullArchivePath)
            let archiveSHA = try SHA256Digest.hex(forFileAt: archiveURL)
            let archiveSize = try FileManager.default.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber
            var deltas: [Int: DeltaManifest] = [:]
            for deltaPath in options.values(for: "delta-manifest") {
                let delta: DeltaManifest = try readJSON(URL(fileURLWithPath: deltaPath))
                deltas[delta.baseReleaseID.buildNumber] = delta
            }
            let changelog = try String(contentsOfFile: changelogFile, encoding: .utf8)
            let release = try ReleaseManifestBuilder.makeReleaseManifest(
                input: ReleaseManifestBuildInput(
                    targetManifest: targetManifest,
                    version: version,
                    buildNumber: buildNumber,
                    channel: channel,
                    architectures: architectures(from: options.values(for: "architecture")),
                    minimumSystemVersion: minimumSystemVersion,
                    minimumSupportedBuild: minimumSupportedBuild,
                    commitSHA: commitSHA,
                    changelog: changelog,
                    fullArchive: FullArchiveMetadata(
                        size: archiveSize?.int64Value ?? 0,
                        sha256: archiveSHA,
                        storageKey: "\(releasePrefix(channel: channel, releaseID: releaseID))/archives/\(archiveSHA).zip",
                        notarized: true,
                        stapled: true
                    ),
                    deltaManifestsByBaseBuild: deltas,
                    notarization: NotarizationEvidence(
                        codesignVerified: true,
                        gatekeeperAccepted: true,
                        staplerValidated: true,
                        checkedAt: Date()
                    )
                )
            )
            try writeJSON(release, to: URL(fileURLWithPath: outputPath))

        default:
            printUsage()
        }
    }

    private static func parseOptions(_ arguments: [String]) -> [String: [String]] {
        var options: [String: [String]] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index += 1
                continue
            }
            let key = String(argument.dropFirst(2))
            let value: String
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                value = arguments[index + 1]
                index += 2
            } else {
                value = "true"
                index += 1
            }
            options[key, default: []].append(value)
        }
        return options
    }

    private static func printUsage() {
        print("""
        Usage:
          macos-updater-release changelog --version <semver> --commits-file <path>
          macos-updater-release state-next --state-file <path> --channel <stable|beta|canary> --version <semver>
          macos-updater-release plan-keys --channel <stable|beta|canary> --version <semver> --build <number> [--base-build <number>] [--payload-sha256 <sha256>] [--full-archive-sha256 <sha256>] [--bucket <name>]
          macos-updater-release target-manifest --app <path> --output <path> --version <semver> --build <number> --bundle-id <id> --team-id <id>
          macos-updater-release delta --base-manifest <path> --target-manifest <path> --target-app <path> --output-dir <dir> --channel <stable|beta|canary>
          macos-updater-release full-archive --app <path> --output-dir <dir> --channel <stable|beta|canary> --version <semver> --build <number>
          macos-updater-release release-manifest --target-manifest <path> --full-archive <path> --output <path> --channel <stable|beta|canary> --version <semver> --build <number> --minimum-system-version <version> --minimum-supported-build <number> --commit-sha <sha> --changelog-file <path> [--architecture <arm64|x86_64|universal>] [--delta-manifest <path>]
        """)
    }

    private static func readJSON<T: Decodable>(_ url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try ManifestCoding.decoder().decode(T.self, from: data)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ManifestCoding.prettyJSONData(for: value).write(to: url, options: .atomic)
    }

    private static func releasePrefix(channel: UpdateChannel, releaseID: ReleaseID) -> String {
        "desktop/macos/\(channel.rawValue)/releases/\(releaseID)"
    }

    private static func architectures(from values: [String]) -> [CPUArchitecture] {
        let parsed = values.compactMap(CPUArchitecture.init(rawValue:))
        return parsed.isEmpty ? [.universal] : parsed
    }
}

enum CLIError: Error, LocalizedError {
    case invalidArguments(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let message):
            return message
        }
    }
}

private extension Dictionary where Key == String, Value == [String] {
    func firstValue(for key: String) -> String? {
        self[key]?.first
    }

    func values(for key: String) -> [String] {
        self[key] ?? []
    }
}

do {
    try ReleaseCLI.main()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
