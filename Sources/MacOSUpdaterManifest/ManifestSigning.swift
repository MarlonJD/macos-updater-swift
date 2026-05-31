// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import CryptoKit
import Foundation

public enum ManifestCoding {
    public static func canonicalJSONData<T: Encodable>(for value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum ManifestSigningError: Error, Equatable, LocalizedError {
    case unknownKeyID(String)
    case unsupportedAlgorithm(ManifestSignatureAlgorithm)
    case invalidSignatureEncoding(String)
    case signatureRejected(String)
    case missingRequiredSignature(String)

    public var errorDescription: String? {
        switch self {
        case .unknownKeyID(let keyID):
            return "Unknown manifest signing key id: \(keyID)."
        case .unsupportedAlgorithm(let algorithm):
            return "Unsupported manifest signature algorithm: \(algorithm.rawValue)."
        case .invalidSignatureEncoding(let keyID):
            return "Invalid manifest signature encoding for key id: \(keyID)."
        case .signatureRejected(let keyID):
            return "Manifest signature was rejected for key id: \(keyID)."
        case .missingRequiredSignature(let keyID):
            return "Manifest is missing a required signature for key id: \(keyID)."
        }
    }
}

public enum ManifestSigner {
    public static func sign<Manifest: Codable & Equatable & Sendable>(
        _ manifest: Manifest,
        keyID: String,
        privateKey: P256.Signing.PrivateKey,
        signedAt: Date = Date()
    ) throws -> SignedManifest<Manifest> {
        let payloadData = try ManifestCoding.canonicalJSONData(for: manifest)
        let signature = try privateKey.signature(for: payloadData)
        return SignedManifest(
            manifest: manifest,
            signatures: [
                ManifestSignature(
                    keyID: keyID,
                    algorithm: .p256ECDSASHA256,
                    signatureBase64: signature.derRepresentation.base64EncodedString(),
                    signedAt: signedAt
                )
            ]
        )
    }

    public static func appendSignature<Manifest: Codable & Equatable & Sendable>(
        to signedManifest: SignedManifest<Manifest>,
        keyID: String,
        privateKey: P256.Signing.PrivateKey,
        signedAt: Date = Date()
    ) throws -> SignedManifest<Manifest> {
        let payloadData = try ManifestCoding.canonicalJSONData(for: signedManifest.manifest)
        let signature = try privateKey.signature(for: payloadData)
        var signatures = signedManifest.signatures
        signatures.append(
            ManifestSignature(
                keyID: keyID,
                algorithm: .p256ECDSASHA256,
                signatureBase64: signature.derRepresentation.base64EncodedString(),
                signedAt: signedAt
            )
        )
        return SignedManifest(manifest: signedManifest.manifest, signatures: signatures)
    }
}

public struct ManifestVerifier: Sendable {
    public let publicKeysByID: [String: P256.Signing.PublicKey]
    public let requiredKeyIDs: Set<String>

    public init(
        publicKeysByID: [String: P256.Signing.PublicKey],
        requiredKeyIDs: Set<String> = []
    ) {
        self.publicKeysByID = publicKeysByID
        self.requiredKeyIDs = requiredKeyIDs
    }

    @discardableResult
    public func verify<Manifest: Codable & Equatable & Sendable>(
        _ signedManifest: SignedManifest<Manifest>
    ) throws -> Set<String> {
        let payloadData = try ManifestCoding.canonicalJSONData(for: signedManifest.manifest)
        var acceptedKeyIDs = Set<String>()

        for signature in signedManifest.signatures {
            guard signature.algorithm == .p256ECDSASHA256 else {
                throw ManifestSigningError.unsupportedAlgorithm(signature.algorithm)
            }
            guard let publicKey = publicKeysByID[signature.keyID] else {
                throw ManifestSigningError.unknownKeyID(signature.keyID)
            }
            guard let signatureData = Data(base64Encoded: signature.signatureBase64) else {
                throw ManifestSigningError.invalidSignatureEncoding(signature.keyID)
            }

            let cryptoSignature: P256.Signing.ECDSASignature
            do {
                cryptoSignature = try P256.Signing.ECDSASignature(derRepresentation: signatureData)
            } catch {
                throw ManifestSigningError.invalidSignatureEncoding(signature.keyID)
            }

            guard publicKey.isValidSignature(cryptoSignature, for: payloadData) else {
                throw ManifestSigningError.signatureRejected(signature.keyID)
            }
            acceptedKeyIDs.insert(signature.keyID)
        }

        for requiredKeyID in requiredKeyIDs where !acceptedKeyIDs.contains(requiredKeyID) {
            throw ManifestSigningError.missingRequiredSignature(requiredKeyID)
        }

        return acceptedKeyIDs
    }
}
