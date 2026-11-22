import Foundation

/// External systems the stores talk to. `live` is the real Colima CLI / Docker socket; tests and the
/// UI-test build (`-D COLIMAX_UI_TESTING`) inject fakes.
struct AppServices: Sendable {
    var colima: any ColimaControlling
    /// Creates a Docker Engine client for a socket path.
    var makeDocker: @Sendable (String) -> any DockerEngine
    var checkPrerequisites: @Sendable () async -> PrerequisiteReport
    var installPrerequisites: @Sendable ([String]) -> AsyncThrowingStream<String, Error>
    /// Watch `~/.colima/_lima` with kqueue for profile changes (off for fakes).
    var watchesColimaDirectory: Bool
    /// Posts a user notification (title, body). Live: macOS Notification Center; fakes record it.
    var notify: @Sendable (String, String) -> Void = { Notifier.post(title: $0, body: $1) }
    /// Vulnerability scanners installed on this Mac (Trivy, Docker Scout).
    var scannerTools: @Sendable () async -> [ScannerTool] = { await ScannerTool.available() }
    /// The docker CLI's current context (Diagnostics). Live: read from `~/.docker`.
    var dockerContext: @Sendable () -> DockerContextInfo? = { DockerContextReader.current() }

    static let live = AppServices(
        colima: LiveColima(),
        makeDocker: { DockerClient(socketPath: $0) },
        checkPrerequisites: { await Prerequisites.check() },
        installPrerequisites: { Prerequisites.install($0) },
        watchesColimaDirectory: true
    )

    /// Services for this launch: the live ones, or the UI-test fixtures when the app was built with
    /// `-D COLIMAX_UI_TESTING` and launched with `COLIMAX_UI_TEST_FIXTURES=1`. Release builds never
    /// contain the fixtures.
    /// UI-test launch with fixtures: animations off, optional start screen (`COLIMAX_UI_TEST_SCREEN`).
    static var isUITestLaunch: Bool {
        #if COLIMAX_UI_TESTING
        ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_FIXTURES"] == "1"
        #else
        false
        #endif
    }

    static func forLaunch() -> AppServices {
        #if COLIMAX_UI_TESTING
        if ProcessInfo.processInfo.environment["COLIMAX_UI_TEST_FIXTURES"] == "1" {
            return UITestFixtures.services()
        }
        #endif
        return .live
    }
}

// MARK: - Narrow dependencies
//
// Feature models and background stores depend on these protocols instead of on `AppStore`, so each
// sees only what it uses and can be tested with a small fake. `AppStore` conforms to all of them.

/// What a Docker screen model (containers, images, volumes, networks, compose, storage) needs.
@MainActor
protocol DockerContext: AnyObject {
    var operations: OperationCenter { get }
    var docker: any DockerEngine { get }
    var socketPath: String { get }
    var containers: [DockerContainer] { get }
    var images: [DockerImage] { get }
    var isRunning: Bool { get }
    var supportsDocker: Bool { get }
    func refreshOverview() async
}

/// What the VM / profile model and the setup model need.
@MainActor
protocol ProfileContext: AnyObject {
    var operations: OperationCenter { get }
    var colima: any ColimaControlling { get }
    var selectedProfileName: String { get }
    var isRunning: Bool { get }
    var notifyVMChanges: Bool { get }
    func notify(title: String, body: String)
    func refreshProfiles() async
    func select(_ name: String)
}

/// What `BackupScheduler` needs from the app.
@MainActor
protocol BackupSchedulerHost: AnyObject {
    var runningProfileNames: Set<String> { get }
    /// Docker Engine of any profile (schedules may target a profile that is not selected).
    func docker(forProfile profile: String) -> any DockerEngine
    var notifyBackupFailure: Bool { get }
    func notify(title: String, body: String)
}

/// What `ResourceWatcher` needs from the app.
@MainActor
protocol ResourceWatcherHost: AnyObject {
    var selectedProfileName: String { get }
    /// Background monitoring is enabled and the selected profile runs Docker.
    var canSampleResources: Bool { get }
    var docker: any DockerEngine { get }
    var colima: any ColimaControlling { get }
    var containers: [DockerContainer] { get }
    var alertThresholds: AlertThresholds { get }
    var notifyResourceAlerts: Bool { get }
    func notify(title: String, body: String)
}

/// What `ProxyStore` needs from the app.
@MainActor
protocol ProxyHost: AnyObject {
    var docker: any DockerEngine { get }
    func flash(_ message: String)
}
