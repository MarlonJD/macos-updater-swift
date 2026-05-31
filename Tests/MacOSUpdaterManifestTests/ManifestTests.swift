import CryptoKit
import Foundation
import XCTest
@testable import MacOSUpdaterManifest

final class ManifestTests: XCTestCase {
    func testSHA256DigestMatchesKnownValue() throws {
        let data = Data("hello updater".utf8)
        XCTAssertEqual(
            SHA256Digest.hex(for: data),
            "026cfa17e5bb78d47c0b760323306b7727f62d83e4a8435b3dcf1ef5ec1da1ac"
        )

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        XCTAssertEqual(try SHA256Digest.hex(forFileAt: fileURL), SHA256Digest.hex(for: data))
    }

    func testSemanticVersionOrderingUsesSemVerPrecedence() throws {
        XCTAssertLessThan(try SemanticVersion("1.5.0-beta.1"), try SemanticVersion("1.5.0"))
        XCTAssertLessThan(try SemanticVersion("1.5.0-beta.1"), try SemanticVersion("1.5.0-beta.2"))
        XCTAssertLessThan(try SemanticVersion("1.5.0-alpha.9"), try SemanticVersion("1.5.0-beta.1"))
        XCTAssertThrowsError(try SemanticVersion("1.05.0"))
        XCTAssertThrowsError(try SemanticVersion("1.5.0-beta.01"))
    }

    func testBuildNumberMustIncrease() throws {
        let state = DesktopReleaseState(
            lastBuildNumber: 1847,
            lastStableVersion: try SemanticVersion("1.4.2"),
            lastBetaVersion: try SemanticVersion("1.5.0-beta.1")
        )

        XCTAssertEqual(state.nextBuildNumber(), 1848)
        XCTAssertNoThrow(try state.validateNextBuildNumber(1848))
        XCTAssertThrowsError(try state.validateNextBuildNumber(1847)) { error in
            XCTAssertEqual(
                error as? ReleaseStateError,
                .buildNumberMustIncrease(current: 1847, proposed: 1847)
            )
        }

        let encoded = try ManifestCoding.canonicalJSONData(for: state)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(json.contains(#""lastStableVersion":"1.4.2""#))
        XCTAssertTrue(json.contains(#""lastBetaVersion":"1.5.0-beta.1""#))
    }

    func testManifestSigningAcceptsPinnedKeyAndRejectsMutatedManifest() throws {
        let privateKey = P256.Signing.PrivateKey()
        let version = try SemanticVersion("1.4.3")
        let releaseManifest = fixtureReleaseManifest(version: version, buildNumber: 1848)
        let signedManifest = try ManifestSigner.sign(
            releaseManifest,
            keyID: "stable-2026",
            privateKey: privateKey,
            signedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let verifier = ManifestVerifier(
            publicKeysByID: ["stable-2026": privateKey.publicKey],
            requiredKeyIDs: ["stable-2026"]
        )
        XCTAssertEqual(try verifier.verify(signedManifest), ["stable-2026"])

        let mutatedManifest = fixtureReleaseManifest(version: version, buildNumber: 1849)
        let mutatedSignedManifest = SignedManifest(
            manifest: mutatedManifest,
            signatures: signedManifest.signatures
        )
        XCTAssertThrowsError(try verifier.verify(mutatedSignedManifest)) { error in
            XCTAssertEqual(error as? ManifestSigningError, .signatureRejected("stable-2026"))
        }
    }

    func testCompressedPayloadMetadataRoundTrips() throws {
        let payload = CompressedPayloadMetadata(
            compression: .lzfse,
            compressedSize: 42,
            compressedSHA256: String(repeating: "a", count: 64),
            uncompressedSize: 128,
            uncompressedSHA256: String(repeating: "b", count: 64),
            storageKey: "desktop/macos/stable/releases/1.4.3+1848/payloads/aa/aa/file.lzfse"
        )
        let encoded = try ManifestCoding.canonicalJSONData(for: payload)
        let decoded = try ManifestCoding.decoder().decode(CompressedPayloadMetadata.self, from: encoded)
        XCTAssertEqual(decoded, payload)
    }

    private func fixtureReleaseManifest(version: SemanticVersion, buildNumber: Int) -> ReleaseManifest {
        ReleaseManifest(
            releaseID: ReleaseID(version: version, buildNumber: buildNumber),
            version: version,
            buildNumber: buildNumber,
            channel: .stable,
            bundleIdentifier: "com.radlof.emsi-swift",
            teamIdentifier: "UPK4SC93AN",
            platform: .macOS,
            architectures: [.arm64, .x86_64],
            minimumSystemVersion: "13.0",
            minimumSupportedBuild: 1847,
            commitSHA: "abcdef123456",
            changelog: "## \(version)\n- Test release",
            targetFileManifestSHA256: String(repeating: "c", count: 64),
            deltaManifestSHA256ByBaseBuild: [1847: String(repeating: "d", count: 64)],
            publishedAt: Date(timeIntervalSince1970: 1_800_000_001)
        )
    }
}
