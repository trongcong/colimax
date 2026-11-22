import Foundation

/// Runs blocking work (recv, pipe reads, waitUntilExit) on a dedicated GCD queue.
///
/// `Task.detached` is not used for this: the Swift Concurrency cooperative pool has only about
/// one thread per core, so a few `recv` calls waiting 30 s are enough to stall every other async task.
/// `onCancel` is called when the Task is cancelled; use it to shut down the socket / terminate
/// the process so the blocked thread is released.
enum BlockingIO {
    private static let queue = DispatchQueue(label: "colimax.blocking-io", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(
        onCancel: @escaping @Sendable () -> Void = {},
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                queue.async {
                    do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            onCancel()
        }
    }
}

/// A lock-protected value shared across GCD threads.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}
