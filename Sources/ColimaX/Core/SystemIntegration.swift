import AppKit
import Foundation
import ServiceManagement
import UserNotifications

/// macOS notifications. Only work when running as an .app (a bundle identifier is required).
enum Notifier {
    static var isSupported: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isSupported else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isSupported else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

/// Launch at login via SMAppService (macOS 13+), without a hand-written LaunchAgent.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Opens Terminal with a shell inside the container via the docker CLI.
/// The container ID is validated as hex-only; paths are single-quoted safely.
enum TerminalLauncher {
    static func openShell(containerID: String, socketPath: String) throws {
        guard containerID.allSatisfy(\.isHexDigit), !containerID.isEmpty else {
            throw ShellError.failed(String(localized: "Invalid container ID"))
        }
        guard let docker = Shell.which("docker") else { throw ShellError.notFound("docker") }

        let script = """
        #!/bin/sh
        export DOCKER_HOST=\(quote("unix://" + socketPath))
        clear
        \(quote(docker)) exec -it \(containerID) sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("colimax-exec-\(containerID.prefix(12)).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        NSWorkspace.shared.open(url)
    }

    /// Single-quotes a value for sh: ' → '\''
    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Watches directories for changes (write, delete, rename) via kqueue, so VM start/stop is
/// detected without constantly polling `colima list`.
final class DirectoryWatcher: @unchecked Sendable {
    private var sources: [DispatchSourceFileSystemObject] = []
    private let queue = DispatchQueue(label: "colimax.dirwatch")
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func watch(_ urls: [URL]) {
        queue.sync {
            sources.forEach { $0.cancel() }
            sources = urls.compactMap { url in
                let fd = open(url.path, O_EVTONLY)
                guard fd >= 0 else { return nil }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: queue)
                source.setEventHandler { [onChange] in onChange() }
                source.setCancelHandler { close(fd) }
                source.resume()
                return source
            }
        }
    }

    deinit { sources.forEach { $0.cancel() } }
}

/// Whether the main window can currently be seen, used to pause periodic sampling
/// (each Dashboard sample runs `colima ssh`) while the window is minimized, hidden or covered.
@MainActor
enum WindowVisibility {
    static var isMainWindowVisible: Bool {
        let windows = NSApp.windows.filter { !($0 is NSPanel) }
        // SwiftUI names the window after the scene id ("main"); fall back to any regular window.
        let main = windows.filter { $0.identifier?.rawValue.hasPrefix("main") ?? false }
        return (main.isEmpty ? windows : main).contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }
}
