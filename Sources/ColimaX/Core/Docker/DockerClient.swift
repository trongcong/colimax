import Foundation

enum DockerError: LocalizedError {
    case socket(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .socket(let message): message
        case .http(let code, let message): "Docker API \(code): \(message)"
        }
    }
}

/// Docker Engine API client over a unix socket.
/// Uses HTTP/1.0: the server closes the connection when done and normally doesn't chunk,
/// so streams (events, logs follow, stats, pull) just read until EOF. Buffered responses
/// are still de-chunked if the server sends `Transfer-Encoding: chunked`.
///
/// All blocking I/O runs on GCD threads (`BlockingIO` or a global queue for streams) and is
/// cancellable: cancelling the Task or stream calls `shutdown()` on the socket so a pending `recv` returns at once.
struct DockerClient: Sendable {
    let socketPath: String

    /// Result of writing a response body to a file.
    struct FileTransfer: Sendable, Equatable {
        let size: Int64
        let sha256: String
    }

    // MARK: - Buffered requests

    func data(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        timeout: Int = 30
    ) async throws -> Data {
        let request = Self.buildRequest(method, path, query: query, contentType: body == nil ? nil : "application/json", contentLength: body?.count ?? 0)
        return try await connection(timeout: timeout) { fd in
            try Self.write(fd, request)
            if let body { try Self.write(fd, body) }
            let head = try Self.readHead(fd)
            var payload = head.leftover
            try Self.readAll(fd) { payload.append($0) }
            if head.chunked { payload = Self.dechunk(payload) }
            try Self.check(status: head.status, body: payload)
            return payload
        }
    }

    func json<Body: Encodable & Sendable>(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        body: Body,
        timeout: Int = 30
    ) async throws -> Data {
        try await data(method, path, query: query, body: JSONEncoder().encode(body), timeout: timeout)
    }

    func decode<T: Decodable>(_ type: T.Type, _ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await data("GET", path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// `GET /_ping`: quick check that the daemon responds.
    func ping(timeout: Int = 5) async throws {
        let body = try await data("GET", "/_ping", timeout: timeout)
        guard String(decoding: body, as: UTF8.self).trimmed == "OK" else {
            throw DockerError.socket(String(localized: "Docker returned an invalid /_ping response"))
        }
    }

    // MARK: - Streaming

    /// Streams the raw response body chunk by chunk. Cancelling the consumer shuts down the socket.
    func stream(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil) -> AsyncThrowingStream<Data, Error> {
        let request = Self.buildRequest(method, path, query: query, contentType: body == nil ? nil : "application/json", contentLength: body?.count ?? 0)
        let socketPath = socketPath
        return AsyncThrowingStream { continuation in
            let handle = SocketHandle()
            continuation.onTermination = { _ in handle.cancel() }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let fd = try Self.connect(socketPath, timeout: nil)
                    guard handle.attach(fd) else { close(fd); continuation.finish(); return }
                    defer { handle.detach(); close(fd) }
                    try Self.write(fd, request)
                    if let body { try Self.write(fd, body) }
                    let head = try Self.readHead(fd)
                    if !(200..<300).contains(head.status) {
                        var payload = head.leftover
                        try? Self.readAll(fd) { payload.append($0) }
                        try Self.check(status: head.status, body: payload)
                    }
                    if !head.leftover.isEmpty { continuation.yield(head.leftover) }
                    try Self.readAll(fd) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: handle.isCancelled ? CancellationError() : error)
                }
            }
        }
    }

    /// Streams one decoded JSON value per line (events, stats, pull progress); undecodable lines are skipped.
    func jsonLines<T: Decodable & Sendable>(_ type: T.Type, _ method: String, _ path: String, query: [String: String] = [:]) -> AsyncThrowingStream<T, Error> {
        let source = stream(method, path, query: query)
        return AsyncThrowingStream { continuation in
            let task = Task {
                let splitter = LineSplitter()
                let decoder = JSONDecoder()
                do {
                    for try await chunk in source {
                        for line in splitter.feed(chunk) where !line.isEmpty {
                            if let value = try? decoder.decode(T.self, from: Data(line.utf8)) {
                                continuation.yield(value)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - File transfer

    /// Writes the response body to a file (without buffering it in memory), with SHA-256.
    /// Data goes to a temp file in the same directory, which then replaces `destination`, so a
    /// mid-way failure (disk full, connection lost, cancellation) never leaves a partial backup file.
    func download(_ path: String, query: [String: String] = [:], to destination: URL, timeout: Int = 120) async throws -> FileTransfer {
        let request = Self.buildRequest("GET", path, query: query, contentType: nil, contentLength: 0)
        return try await receiveToFile(request: request, body: nil, destination: destination, timeout: timeout) { head, fd, sink in
            if !(200..<300).contains(head.status) {
                var payload = head.leftover
                try? Self.readAll(fd) { payload.append($0) }
                try Self.check(status: head.status, body: payload)
            }
            try sink(head.leftover)
            try Self.readAll(fd, sink)
        }
    }

    /// Sends `request` (plus optional `body`) and writes the response to `destination` via `handler`,
    /// which gets the response head, the socket, and a sink for file bytes (e.g. to extract exec stdout).
    /// Uses the same temp-file-then-replace scheme as `download`.
    func receiveToFile(
        request: Data,
        body: Data?,
        destination: URL,
        timeout: Int,
        _ handler: @escaping @Sendable (Head, Int32, (Data) throws -> Void) throws -> Void
    ) async throws -> FileTransfer {
        let temp = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString.prefix(8))")
        do {
            let result = try await connection(timeout: timeout) { fd -> FileTransfer in
                try Self.write(fd, request)
                if let body { try Self.write(fd, body) }
                let head = try Self.readHead(fd)
                let file = try AtomicFile.createExclusive(temp)
                defer { try? file.close() }
                var hasher = FileHasher()
                try handler(head, fd) { chunk in
                    guard !chunk.isEmpty else { return }
                    try file.write(contentsOf: chunk)
                    hasher.update(chunk)
                }
                try file.synchronize()
                return hasher.finalize()
            }
            try AtomicFile.install(temp, at: destination)
            return result
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Sends a file's contents as the request body (e.g. PUT archive to restore a volume).
    func upload(_ method: String, _ path: String, query: [String: String] = [:], file: URL, contentType: String, timeout: Int = 120) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        let request = Self.buildRequest(method, path, query: query, contentType: contentType, contentLength: size)
        try await connection(timeout: timeout) { fd in
            try Self.write(fd, request)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Self.write(fd, chunk)
            }
            let head = try Self.readHead(fd)
            var payload = head.leftover
            try? Self.readAll(fd) { payload.append($0) }
            try Self.check(status: head.status, body: payload)
        }
    }

    /// Wraps `file` into a single-entry tar on the fly (no temporary tar file) and sends it with
    /// `PUT /containers/{id}/archive?path=<directory>`. Used to copy dumps into a container.
    func uploadAsTar(container id: String, directory: String, file: URL, entryName: String, mode: Int = 0o644, timeout: Int = 600) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let header = try TarWriter.header(name: entryName, size: size, mode: mode)
        let total = TarWriter.archiveSize(contentSize: size)
        let request = Self.buildRequest("PUT", "/containers/\(Self.escape(id))/archive", query: ["path": directory],
                                        contentType: "application/x-tar", contentLength: Int(total))
        try await connection(timeout: timeout) { fd in
            try Self.write(fd, request)
            try Self.write(fd, header)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var sent: Int64 = 0
            while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try Self.write(fd, chunk)
                sent += Int64(chunk.count)
            }
            guard sent == size else { throw DockerError.socket(String(localized: "File \(file.lastPathComponent) changed while uploading")) }
            try Self.write(fd, Data(count: Int(TarWriter.paddedSize(size) - size) + 1024))
            let head = try Self.readHead(fd)
            var payload = head.leftover
            try? Self.readAll(fd) { payload.append($0) }
            try Self.check(status: head.status, body: payload)
        }
    }

    /// Opens a connection and runs `body` on a GCD thread; cancelling the Task shuts down the socket.
    private func connection<T: Sendable>(timeout: Int, _ body: @escaping @Sendable (Int32) throws -> T) async throws -> T {
        let socketPath = socketPath
        let handle = SocketHandle()
        return try await BlockingIO.run(onCancel: { handle.cancel() }) {
            let fd = try Self.connect(socketPath, timeout: timeout)
            guard handle.attach(fd) else { close(fd); throw CancellationError() }
            defer { handle.detach(); close(fd) }
            do {
                return try body(fd)
            } catch {
                throw handle.isCancelled ? CancellationError() : error
            }
        }
    }

    // MARK: - Low level

    struct Head {
        let status: Int
        let chunked: Bool
        let leftover: Data
    }

    static func buildRequest(_ method: String, _ path: String, query: [String: String], contentType: String?, contentLength: Int) -> Data {
        var target = path
        if !query.isEmpty {
            let items = query.sorted { $0.key < $1.key }.map { "\(escape($0.key))=\(escape($0.value))" }
            target += "?" + items.joined(separator: "&")
        }
        var head = "\(method) \(target) HTTP/1.0\r\nHost: docker\r\nUser-Agent: ColimaX\r\n"
        if let contentType { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(contentLength)\r\n\r\n"
        return Data(head.utf8)
    }

    /// Percent-encodes query keys/values and path segments (user-supplied names/IDs).
    static func escape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    static func connect(_ socketPath: String, timeout: Int?) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError.socket(String(localized: "Could not create socket")) }

        if let timeout {
            var tv = timeval(tv_sec: timeout, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw DockerError.socket(String(localized: "Socket path is too long"))
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            switch code {
            case EACCES, EPERM: throw DockerError.socket(String(localized: "No permission to access Docker socket \(socketPath)"))
            case ENOENT: throw DockerError.socket(String(localized: "Docker socket \(socketPath) not found. Is the VM running?"))
            default: throw DockerError.socket(String(localized: "Could not connect to Docker socket (errno \(Format.digits(code))). Is the VM running?"))
            }
        }
        return fd
    }

    static func write(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return }
            var remaining = raw.count
            while remaining > 0 {
                let sent = send(fd, pointer, remaining, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw DockerError.socket(String(localized: "Sending data to Docker failed (errno \(Format.digits(errno)))"))
                }
                remaining -= sent
                pointer = pointer.advanced(by: sent)
            }
        }
    }

    static func readHead(_ fd: Int32) throws -> Head {
        var data = Data()
        let separator = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            if let range = data.range(of: separator) {
                let head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                let parts = lines.first?.split(separator: " ") ?? []
                let status = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
                let chunked = lines.contains {
                    let lower = $0.lowercased()
                    return lower.hasPrefix("transfer-encoding:") && lower.contains("chunked")
                }
                return Head(status: status, chunked: chunked, leftover: Data(data[range.upperBound...]))
            }
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                data.append(buffer, count: n)
            } else if n == 0 {
                throw DockerError.socket(String(localized: "Docker closed the connection before responding"))
            } else if errno != EINTR {
                throw DockerError.socket(String(localized: "Timed out waiting for Docker to respond"))
            }
        }
    }

    static func readAll(_ fd: Int32, _ onChunk: (Data) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n > 0 {
                try onChunk(Data(buffer[0..<n]))
            } else if n == 0 {
                return
            } else if errno == EINTR {
                continue
            } else {
                throw DockerError.socket(String(localized: "Lost connection to Docker (errno \(Format.digits(errno)))"))
            }
        }
    }

    static func check(status: Int, body: Data) throws {
        guard !(200..<400).contains(status) else { return }
        struct APIError: Decodable { let message: String }
        let message = (try? JSONDecoder().decode(APIError.self, from: body).message) ?? String(decoding: body, as: UTF8.self)
        throw DockerError.http(status, message.trimmed)
    }

    static func dechunk(_ data: Data) -> Data {
        var output = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)
        while index < data.endIndex, let lineEnd = data.range(of: crlf, in: index..<data.endIndex) {
            let sizeText = String(decoding: data[index..<lineEnd.lowerBound], as: UTF8.self)
            guard let size = Int(sizeText.split(separator: ";").first ?? "", radix: 16), size > 0 else { break }
            let start = lineEnd.upperBound
            let end = min(start + size, data.endIndex)
            output.append(data[start..<end])
            index = min(end + 2, data.endIndex)
        }
        return output
    }
}

/// Lets another thread cancel a blocking recv() via shutdown().
final class SocketHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32?
    private(set) var isCancelled = false

    /// Returns false if cancelled before the socket was attached.
    func attach(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !isCancelled else { return false }
        self.fd = fd
        return true
    }

    /// Call before close() so cancel() can't shut down an fd number that has been reused.
    func detach() {
        lock.lock(); defer { lock.unlock() }
        fd = nil
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        isCancelled = true
        if let fd { shutdown(fd, SHUT_RDWR) }
    }
}

/// Parses Docker's multiplexed stream (containers/execs without a TTY).
/// Frame: [stream(1), 0, 0, 0, size(4 bytes big-endian)] + payload. stream: 0 stdin, 1 stdout, 2 stderr.
struct MultiplexedStreamParser: Sendable {
    struct Frame: Equatable, Sendable {
        let stream: UInt8
        let payload: Data
    }

    private var buffer = Data()

    mutating func feed(_ data: Data) -> [Frame] {
        buffer.append(data)
        var frames: [Frame] = []
        var index = buffer.startIndex
        while buffer.endIndex - index >= 8 {
            let b = buffer
            let size = Int(b[index + 4]) << 24 | Int(b[index + 5]) << 16 | Int(b[index + 6]) << 8 | Int(b[index + 7])
            guard buffer.endIndex - index - 8 >= size else { break }
            frames.append(Frame(stream: b[index], payload: Data(b[(index + 8)..<(index + 8 + size)])))
            index += 8 + size
        }
        buffer = Data(buffer[index...])
        return frames
    }

    /// Buffered bytes that don't yet form a complete frame.
    var pendingCount: Int { buffer.count }
}

/// Merges stdout + stderr of container logs or exec output into text (TTY streams are not multiplexed).
struct LogDemuxer {
    private var parser = MultiplexedStreamParser()
    let tty: Bool

    init(tty: Bool) { self.tty = tty }

    mutating func feed(_ data: Data) -> String {
        if tty { return String(decoding: data, as: UTF8.self) }
        var output = Data()
        for frame in parser.feed(data) { output.append(frame.payload) }
        return String(decoding: output, as: UTF8.self)
    }
}
