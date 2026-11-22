import Foundation
import Observation

/// A long-running operation (colima start, compose up, pull…) with its progress log.
struct OperationState: Identifiable {
    enum Status: Equatable { case running, succeeded, cancelled, failed(String) }
    let id = UUID()
    let title: String
    var lines: [String] = []
    var status: Status = .running
    var isRunning: Bool { status == .running }
}

/// Feedback and execution of user actions, shared by every screen: the single long-running operation
/// (with its log, cancellation and final state), short actions keyed as "busy", the error banner and
/// the transient flash message.
@MainActor
@Observable
final class OperationCenter {
    static let maxLogLines = 2000

    var operation: OperationState?
    var busy: Set<String> = []
    var errorMessage: String?
    var flashMessage: String?

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?

    var isOperationRunning: Bool { operation?.isRunning ?? false }

    // MARK: - Long operations

    /// Consumes an output stream (colima/compose), logging into `operation`. Returns true on success.
    @discardableResult
    func runOperation(_ title: String, _ stream: AsyncThrowingStream<String, Error>) async -> Bool {
        operation = OperationState(title: title)
        errorMessage = nil
        do {
            for try await line in stream {
                let text = line.contains("msg=") ? ColimaLog.message(of: line) : line
                operation?.lines.append(text)
                if (operation?.lines.count ?? 0) > Self.maxLogLines { operation?.lines.removeFirst(500) }
            }
            if Task.isCancelled {
                operation?.status = .cancelled
                return false
            }
            operation?.status = .succeeded
            return true
        } catch {
            finish(with: error)
            return false
        }
    }

    /// Starts a long operation in a cancellable Task. Ignored while another one is running; returns
    /// whether it started.
    @discardableResult
    func launch(_ body: @escaping @MainActor () async -> Void) -> Bool {
        guard !isOperationRunning else { return false }
        operationTask = Task { await body() }
        return true
    }

    /// Opens an operation whose log the caller fills in itself (e.g. image pull progress).
    func begin(_ title: String) {
        operation = OperationState(title: title)
        errorMessage = nil
    }

    /// Ends the current operation: cancelled if the Task was cancelled, failed (with the error banner) otherwise.
    func finish(with error: Error?) {
        guard let error else {
            operation?.status = Task.isCancelled ? .cancelled : .succeeded
            return
        }
        if Task.isCancelled || error is CancellationError {
            operation?.status = .cancelled
        } else {
            operation?.status = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    /// Waits for the current long operation's Task to finish (used by tests and app termination).
    func waitForOperation() async {
        await operationTask?.value
    }

    /// Cancels the running long operation (terminates the process / shuts down the socket).
    func cancelOperation() {
        operationTask?.cancel()
    }

    func dismissOperation() {
        if operation?.isRunning == false { operation = nil }
    }

    // MARK: - Short actions

    /// Runs a short action, marking `key` as busy while it runs (ignored if already busy).
    /// Returns the Task so callers (and tests) can await it; nil when the key was already busy.
    @discardableResult
    func perform(_ key: String, _ work: @escaping @MainActor () async throws -> Void) -> Task<Void, Never>? {
        guard !busy.contains(key) else { return nil }
        busy.insert(key)
        return Task {
            do {
                try await work()
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
            busy.remove(key)
        }
    }

    // MARK: - Flash message

    func flash(_ message: String) {
        flashMessage = message
        flashTask?.cancel()
        flashTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { flashMessage = nil }
        }
    }
}
