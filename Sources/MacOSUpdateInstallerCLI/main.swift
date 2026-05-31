// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Foundation
import MacOSUpdaterCore
import MacOSUpdaterManifest
import CryptoKit

enum InstallerCLI {
    static func main(arguments: [String] = Array(CommandLine.arguments.dropFirst())) throws {
        let options = parseOptions(arguments)

        if options["dry-run"] == "true", let requestPath = options["request"] {
            let requestData = try Data(contentsOf: URL(fileURLWithPath: requestPath))
            let request = try ManifestCoding.decoder().decode(UpdateInstallRequest.self, from: requestData)
            print(UpdateInstallerPlanner.dryRunPlan(for: request).text())
            return
        }

        if options["dry-run"] == "true", let legacyRequestPath = options["legacy-request"] {
            let requestData = try Data(contentsOf: URL(fileURLWithPath: legacyRequestPath))
            let request = try ManifestCoding.decoder().decode(InstallerDryRunRequest.self, from: requestData)
            print(UpdateInstallerPlanner.dryRunPlan(for: request).text())
            return
        }

        guard
            options["perform"] == "true",
            let signedRequestPath = options["signed-request"],
            let publicKeyValue = options["public-key-x963-base64"],
            let keyID = options["key-id"]
        else {
            printUsage()
            return
        }

        guard let publicKeyData = Data(base64Encoded: publicKeyValue) else {
            throw InstallerCLIError.invalidPublicKey
        }
        let publicKey = try P256.Signing.PublicKey(x963Representation: publicKeyData)
        let signedRequestData = try Data(contentsOf: URL(fileURLWithPath: signedRequestPath))
        let signedRequest = try ManifestCoding.decoder().decode(SignedManifest<UpdateInstallRequest>.self, from: signedRequestData)
        try ManifestVerifier(
            publicKeysByID: [keyID: publicKey],
            requiredKeyIDs: [keyID]
        ).verify(signedRequest)
        let result = try UpdateInstaller().performInstall(request: signedRequest.manifest)
        print(String(data: try ManifestCoding.prettyJSONData(for: result), encoding: .utf8) ?? "")
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
        print("""
        Usage:
          macos-update-installer --dry-run --request <install-request.json>
          macos-update-installer --perform --signed-request <signed-request.json> --public-key-x963-base64 <key> --key-id <id>
        """)
    }
}

enum InstallerCLIError: Error, LocalizedError {
    case invalidPublicKey

    var errorDescription: String? {
        switch self {
        case .invalidPublicKey:
            return "Invalid installer request public key."
        }
    }
}

do {
    try InstallerCLI.main()
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
