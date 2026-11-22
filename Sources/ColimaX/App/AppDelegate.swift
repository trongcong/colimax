import AppKit

/// Handles quitting: every quit path (⌘Q, the menu bar Quit button, the Dock, Restart Now after a
/// language change) goes through `applicationShouldTerminate`. Quitting never stops the VM or
/// containers; it only asks first when a long operation (colima start, brew install, compose up…)
/// is still running, because quitting cancels it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: AppStore?
    /// Set by callers that already asked via `confirmQuit()` before calling `NSApp.terminate`.
    static var quitConfirmed = false

    /// Returns true when it is fine to quit. While an operation runs, asks the user and, if they
    /// agree, cancels the operation (its process receives SIGTERM).
    static func confirmQuit() -> Bool {
        guard let store, let operation = store.operations.operation, operation.isRunning else { return true }
        let confirmed = Confirm.ask(
            String(localized: "Quit while “\(operation.title)” is running?"),
            message: String(localized: "Quitting cancels this operation. A VM that is starting, stopping or being deleted, or a Homebrew install, can be left half-done; run it again after reopening ColimaX. A running VM and its containers keep running."),
            button: String(localized: "Cancel Operation and Quit"),
            destructive: false
        ).confirmed
        if confirmed { store.operations.cancelOperation() }
        return confirmed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store, store.operations.isOperationRunning else { return .terminateNow }
        if !Self.quitConfirmed {
            guard Self.confirmQuit() else { return .terminateCancel }
        }
        // Give the cancelled process a moment to receive SIGTERM before the app exits.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
