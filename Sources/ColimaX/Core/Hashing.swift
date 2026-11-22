import CryptoKit
import Foundation

/// Incremental SHA-256 plus byte count, used while streaming data to a file.
struct FileHasher {
    private var hasher = SHA256()
    private(set) var size: Int64 = 0

    mutating func update(_ data: Data) {
        hasher.update(data: data)
        size += Int64(data.count)
    }

    func finalize() -> DockerClient.FileTransfer {
        DockerClient.FileTransfer(size: size, sha256: Self.hex(hasher.finalize()))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes a file in 1 MB chunks (never loads the whole file into memory).
    /// Not interruptible: once started, it runs to the end even if the Task is cancelled.
    static func hash(file url: URL) async throws -> DockerClient.FileTransfer {
        try await BlockingIO.run {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = FileHasher()
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(chunk)
            }
            return hasher.finalize()
        }
    }
}
