import Foundation

struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { status == 0 }
}

enum ShellError: LocalizedError, Equatable {
    case notFound(String)
    case failed(String)
    case timedOut(String, TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notFound(let name): String(localized: "`\(name)` not found. Install with: brew install \(name)")
        case .failed(let message): message
        case .timedOut(let name, let seconds): String(localized: "`\(name)` did not respond after \(Int(seconds)) seconds")
        }
    }
}

/// Runs executables via `Process` with an argument array, never through `/bin/sh`,
/// so user input can never be interpreted as shell commands.
/// GUI apps don't inherit the shell's PATH, so Homebrew paths are added explicitly.
enum Shell {
    static let searchPaths = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    /// `searchPaths` (Homebrew first), then the rest of the process PATH (MacPorts, Nix…).
    static var mergedPaths: [String] {
        var merged = searchPaths
        let current = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for path in current where !path.isEmpty && !merged.contains(path) { merged.append(path) }
        return merged
    }

    static func environment(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = mergedPaths.joined(separator: ":")
        env.merge(extra) { _, new in new }
        return env
    }

    static func which(_ name: String) -> String? {
        // Command names are constants in code; reject paths anyway as defense against traversal.
        guard !name.isEmpty, !name.contains("/") else { return nil }
        for dir in mergedPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Runs a command and returns its full output. Has a timeout; cancelling the Task terminates the process.
    static func run(
        _ name: String,
        _ arguments: [String],
        env: [String: String] = [:],
        timeout: TimeInterval = 120
    ) async throws -> ShellResult {
        guard let executable = which(name) else { throw ShellError.notFound(name) }
        let execution = ProcessExecution(
            name: name,
            executable: executable,
            arguments: arguments,
            environment: environment(extra: env)
        )
        return try await withTaskCancellationHandler {
            try await execution.run(timeout: timeout)
        } onCancel: {
            execution.stop(.cancelled)
        }
    }

    /// Runs a command and streams its output line by line (stdout and stderr merged).
    /// Finishes with an error on a non-zero exit code or a signal. Cancelling the stream terminates the process.
    static func stream(_ name: String, _ arguments: [String], env: [String: String] = [:]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard let executable = which(name) else {
                continuation.finish(throwing: ShellError.notFound(name))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment(extra: env)
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let splitter = LineSplitter()
            let tail = TailBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                for line in splitter.feed(data) {
                    tail.append(line)
                    continuation.yield(line)
                }
            }
            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                for line in splitter.feed(rest) + splitter.flush() {
                    tail.append(line)
                    continuation.yield(line)
                }
                if proc.terminationReason == .exit, proc.terminationStatus == 0 {
                    continuation.finish()
                } else if proc.terminationReason == .uncaughtSignal {
                    // If the consumer cancelled, the continuation has already finished and this error is dropped.
                    continuation.finish(throwing: ShellError.failed(String(localized: "\(name) was stopped by signal \(Format.digits(proc.terminationStatus))")))
                } else {
                    let message = ColimaLog.errorMessage(in: tail.lines)
                        ?? String(localized: "\(name) \(arguments.first ?? "") exited with code \(Format.digits(proc.terminationStatus))")
                    continuation.finish(throwing: ShellError.failed(message))
                }
            }
            continuation.onTermination = { reason in
                if case .cancelled = reason, process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// A single process run: reads stdout/stderr on GCD threads (off the cooperative pool),
/// waits for exit via `terminationHandler`, and supports timeout and cancellation.
final class ProcessExecution: @unchecked Sendable {
    enum StopReason: Sendable { case cancelled, timedOut }

    private let name: String
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let readers = DispatchGroup()
    private let state = Locked<(out: Data, err: Data, stop: StopReason?, started: Bool)>((Data(), Data(), nil, false))

    init(name: String, executable: String, arguments: [String], environment: [String: String]) {
        self.name = name
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    func run(timeout: TimeInterval) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ShellResult, Error>) in
            process.terminationHandler = { [self] proc in
                // Child processes (e.g. the ssh spawned by `colima ssh`) may keep the pipe open: wait at most 2 s for the readers.
                _ = readers.wait(timeout: .now() + 2)
                proc.terminationHandler = nil // break the process ↔ handler retain cycle
                let snapshot = state.current
                switch snapshot.stop {
                case .cancelled:
                    continuation.resume(throwing: CancellationError())
                case .timedOut:
                    continuation.resume(throwing: ShellError.timedOut(name, timeout))
                case nil:
                    continuation.resume(returning: ShellResult(
                        status: proc.terminationStatus,
                        stdout: String(decoding: snapshot.out, as: UTF8.self),
                        stderr: String(decoding: snapshot.err, as: UTF8.self)
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
                return
            }
            startReader(outPipe, isError: false)
            startReader(errPipe, isError: true)
            let cancelledEarly = state.withLock { value -> Bool in
                value.started = true
                return value.stop != nil
            }
            if cancelledEarly { process.terminate() }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.stop(.timedOut)
            }
        }
    }

    func stop(_ reason: StopReason) {
        let shouldTerminate = state.withLock { value -> Bool in
            guard value.stop == nil else { return false }
            value.stop = reason
            return value.started
        }
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    private func startReader(_ pipe: Pipe, isError: Bool) {
        readers.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [state, readers] in
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                state.withLock { value in
                    if isError { value.err.append(data) } else { value.out.append(data) }
                }
            }
            readers.leave()
        }
    }
}

/// Splits Data into UTF-8 lines (dropping a trailing CR), keeping the incomplete tail between reads.
final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let lock = NSLock()

    func feed(_ data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let index = buffer.firstIndex(of: 0x0A) {
            var lineData = buffer[buffer.startIndex..<index]
            if lineData.last == 0x0D { lineData = lineData.dropLast() }
            lines.append(String(decoding: lineData, as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...index)
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll()
        return [line]
    }
}

/// Keeps the last 50 lines for extracting an error message.
private final class TailBuffer: @unchecked Sendable {
    private var storage: [String] = []
    private let lock = NSLock()

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        storage.append(line)
        if storage.count > 50 { storage.removeFirst(storage.count - 50) }
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Colima logs use the logrus format: `time=... level=fatal msg="..."`.
enum ColimaLog {
    static func errorMessage(in lines: [String]) -> String? {
        guard let line = lines.last(where: { $0.contains("level=fatal") || $0.contains("level=error") }) ?? lines.last(where: { !$0.trimmed.isEmpty })
        else { return nil }
        return message(of: line)
    }

    static func message(of line: String) -> String {
        guard let range = line.range(of: "msg=") else { return line.trimmed }
        return String(line[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
}

extension StringProtocol {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
