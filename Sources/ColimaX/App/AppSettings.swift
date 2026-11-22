import AppKit
import Observation

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Interface language (G18). `.system` follows the macOS language order; other choices
/// override `AppleLanguages` in the app's defaults domain and take effect after a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, vi
    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .en: "English"
        case .vi: "Tiếng Việt" // check-strings:allow (language name, not translated)
        }
    }

    /// Value written to `AppleLanguages`; nil removes the key so the system order applies.
    var appleLanguages: [String]? {
        self == .system ? nil : [rawValue]
    }
}

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: "language"); applyLanguage() }
    }
    /// Language at launch; if it differs from `language`, a relaunch is needed.
    let launchLanguage: AppLanguage
    var needsRestartForLanguage: Bool { language != launchLanguage }

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme"); applyTheme() }
    }
    var showDockIcon: Bool {
        didSet { defaults.set(showDockIcon, forKey: "showDockIcon"); applyDockIcon() }
    }
    var autoStartVM: Bool {
        didSet { defaults.set(autoStartVM, forKey: "autoStartVM") }
    }
    var notifyVMChanges: Bool {
        didSet { defaults.set(notifyVMChanges, forKey: "notifyVMChanges"); requestNotificationsIfNeeded() }
    }
    var notifyContainerExit: Bool {
        didSet { defaults.set(notifyContainerExit, forKey: "notifyContainerExit"); requestNotificationsIfNeeded() }
    }
    var notifyBackupFailure: Bool {
        didSet { defaults.set(notifyBackupFailure, forKey: "notifyBackupFailure"); requestNotificationsIfNeeded() }
    }
    /// Sample resources in the background every minute, keep history, and alert on threshold breaches (G20).
    var backgroundMonitoring: Bool {
        didSet { defaults.set(backgroundMonitoring, forKey: "backgroundMonitoring") }
    }
    var notifyResourceAlerts: Bool {
        didSet { defaults.set(notifyResourceAlerts, forKey: "notifyResourceAlerts"); requestNotificationsIfNeeded() }
    }
    var alertThresholds: AlertThresholds {
        didSet {
            defaults.set(alertThresholds.cpuPercent, forKey: "alertCPU")
            defaults.set(alertThresholds.memoryPercent, forKey: "alertMemory")
            defaults.set(alertThresholds.diskPercent, forKey: "alertDisk")
            defaults.set(alertThresholds.sustainSamples, forKey: "alertSustain")
        }
    }
    var launchAtLoginError: String?

    init() {
        let language = AppLanguage(rawValue: defaults.string(forKey: "language") ?? "") ?? .system
        self.language = language
        launchLanguage = language
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        showDockIcon = defaults.object(forKey: "showDockIcon") as? Bool ?? true
        autoStartVM = defaults.bool(forKey: "autoStartVM")
        notifyVMChanges = defaults.object(forKey: "notifyVMChanges") as? Bool ?? true
        notifyContainerExit = defaults.object(forKey: "notifyContainerExit") as? Bool ?? true
        notifyBackupFailure = defaults.object(forKey: "notifyBackupFailure") as? Bool ?? true
        backgroundMonitoring = defaults.object(forKey: "backgroundMonitoring") as? Bool ?? true
        notifyResourceAlerts = defaults.object(forKey: "notifyResourceAlerts") as? Bool ?? true
        let fallback = AlertThresholds.default
        alertThresholds = AlertThresholds(
            cpuPercent: defaults.object(forKey: "alertCPU") as? Double ?? fallback.cpuPercent,
            memoryPercent: defaults.object(forKey: "alertMemory") as? Double ?? fallback.memoryPercent,
            diskPercent: defaults.object(forKey: "alertDisk") as? Double ?? fallback.diskPercent,
            sustainSamples: defaults.object(forKey: "alertSustain") as? Int ?? fallback.sustainSamples
        )
    }

    var launchAtLogin: Bool {
        get { LaunchAtLogin.isEnabled }
        set {
            do {
                try LaunchAtLogin.set(newValue)
                launchAtLoginError = nil
            } catch {
                launchAtLoginError = String(localized: "Could not change it: \(error.localizedDescription). This requires the packaged .app.")
            }
        }
    }

    func applyAll() {
        applyTheme()
        applyDockIcon()
        requestNotificationsIfNeeded()
    }

    private func applyLanguage() {
        if let languages = language.appleLanguages {
            defaults.set(languages, forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Whether the app can relaunch itself (only when running from an .app bundle).
    static var canRelaunch: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Relaunches the app: the current instance fully exits **before** the bundle is reopened,
    /// so two instances never overlap (a new window restored while the old one is closing).
    /// The script is constant; the pid and bundle path are passed via argv, never concatenated.
    static func relaunch() {
        // Ask before spawning the relaunch helper: if the user then declined the quit, the helper
        // would reopen the app at some later, unrelated quit.
        guard AppDelegate.confirmQuit() else { return }
        AppDelegate.quitConfirmed = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$2""#,
            "sh",
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try process.run()
        } catch {
            AppDelegate.quitConfirmed = false
            return
        }
        NSApp.terminate(nil)
    }

    private func applyTheme() {
        // Assign only on change: reassigning while the window is being built can re-layout the titlebar / toolbar.
        if NSApp.appearance?.name != theme.appearance?.name { NSApp.appearance = theme.appearance }
    }

    private func applyDockIcon() {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        // Changing the activation policy while a window is visible makes AppKit rebuild the window
        // frame (the sidebar can end up drawn under the close / minimize buttons). Skip if unchanged.
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
    }

    private func requestNotificationsIfNeeded() {
        if notifyVMChanges || notifyContainerExit || notifyBackupFailure || notifyResourceAlerts { Notifier.requestAuthorization() }
    }
}
