// Copyright (C) 2026 Burak Karahan
// SPDX-License-Identifier: LGPL-3.0-or-later

import Compression
import Foundation
import MacOSUpdaterManifest

public enum ReleasePayloadCodec {
    public static func encode(_ data: Data, compression: PayloadCompression) throws -> Data {
        switch compression {
        case .none:
            return data
        case .lzfse:
            return try encode(data, algorithm: COMPRESSION_LZFSE)
        case .zlib, .lzma, .lz4:
            throw ReleaseGeneratorError.unsupportedFileKind("Unsupported compression: \(compression.rawValue)")
        }
    }

    private static func encode(_ data: Data, algorithm: compression_algorithm) throws -> Data {
        guard !data.isEmpty else {
            return Data()
        }

        var capacity = max(data.count + 1024, 4096)
        let limit = max(data.count * 4, capacity)
        while capacity <= limit + 4096 {
            var destination = [UInt8](repeating: 0, count: capacity)
            let encodedCount = data.withUnsafeBytes { sourceBuffer in
                compression_encode_buffer(
                    &destination,
                    destination.count,
                    sourceBuffer.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    algorithm
                )
            }

            if encodedCount > 0 {
                return Data(destination.prefix(encodedCount))
            }
            capacity *= 2
        }

        throw ReleaseGeneratorError.missingPayload("Unable to compress payload.")
    }
}
