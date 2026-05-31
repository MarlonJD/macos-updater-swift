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
            let plan = DistributionKeyPlanner(
                bucketName: options.firstValue(for: "bucket") ?? "emsi-updates-prod"
            ).plan(
                channel: channel,
                version: version,
                buildNumber: buildNumber,
                baseBuildNumber: baseBuildNumber,
                payloadSHA256Values: payloadSHA256Values
            )
            print(plan.dryRunText())

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
          macos-updater-release plan-keys --channel <stable|beta|canary> --version <semver> --build <number> [--base-build <number>] [--payload-sha256 <sha256>] [--bucket <name>]
        """)
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
