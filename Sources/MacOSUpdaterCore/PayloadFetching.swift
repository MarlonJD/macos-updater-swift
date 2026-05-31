// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Compression
import Foundation
import MacOSUpdaterManifest

public protocol UpdateAssetFetching {
    func fetchData(at url: URL) async throws -> Data
}

public struct URLSessionUpdateAssetFetcher: UpdateAssetFetching {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchData(at url: URL) async throws -> Data {
        if url.isFileURL {
            return try Data(contentsOf: url)
        }

        let (data, response) = try await session.data(from: url)
        if let httpResponse = response as? HTTPURLResponse, !(200..<300).contains(httpResponse.statusCode) {
            throw UpdaterCoreError.verificationFailed("Request failed with HTTP \(httpResponse.statusCode) for \(url).")
        }
        return data
    }
}

public enum UpdatePayloadCodec {
    public static func decoded(_ data: Data, compression: PayloadCompression) throws -> Data {
        switch compression {
        case .none:
            return data
        case .lzfse:
            return try decode(data, algorithm: COMPRESSION_LZFSE)
        case .zlib, .lzma, .lz4:
            throw UpdaterCoreError.unsupportedCompression(compression.rawValue)
        }
    }

    private static func decode(_ data: Data, algorithm: compression_algorithm) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        var capacity = max(data.count * 4, 1024)
        while capacity <= 1024 * 1024 * 512 {
            var destination = [UInt8](repeating: 0, count: capacity)
            let decodedCount = data.withUnsafeBytes { sourceBuffer in
                compression_decode_buffer(
                    &destination,
                    destination.count,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    algorithm
                )
            }

            if decodedCount > 0 && decodedCount <= destination.count {
                return Data(destination.prefix(decodedCount))
            }
            capacity *= 2
        }

        throw UpdaterCoreError.unsupportedCompression("lzfse")
    }
}
