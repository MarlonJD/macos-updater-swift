import Foundation
import MacOSUpdaterCore
import MacOSUpdaterManifest

enum InstallerCLI {
    static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        let options = parseOptions(arguments)
        guard options["dry-run"] == "true", let requestPath = options["request"] else {
            printUsage()
            return
        }

        let requestData = try Data(contentsOf: URL(fileURLWithPath: requestPath))
        let request = try ManifestCoding.decoder().decode(InstallerDryRunRequest.self, from: requestData)
        print(UpdateInstallerPlanner.dryRunPlan(for: request).text())
    }

    private static func parseOptions(_ arguments: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("--") else {
                index += 1
                continue
            }
            let key = String(argument.dropFirst(2))
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                options[key] = arguments[index + 1]
                index += 2
            } else {
                options[key] = "true"
                index += 1
            }
        }
        return options
    }

    private static func printUsage() {
        print("Usage: macos-update-installer --dry-run --request <installer-request.json>")
    }
}

do {
    try InstallerCLI.main()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
