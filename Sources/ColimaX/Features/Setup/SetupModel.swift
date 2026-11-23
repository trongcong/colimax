import Foundation
import Observation

/// External tool check and installation (G26): Homebrew, colima, docker CLI, compose plugin.
@MainActor
@Observable
final class SetupModel {
    static let hideAtLaunchKey = "hideSetupAtLaunch"
    /// Context the docker CLI used before ColimaX switched it to Colima (for "Switch Back").
    static let previousContextKey = "runtimeSwitch.previousContext"

    /// Result of the last check; nil until checked.
    var prerequisites: PrerequisiteReport?
    /// Shows the setup assistant (`SetupSheet`).
    var isPresented = false
    /// Other Docker runtimes and the docker CLI setup (G27); nil until checked or when not inspectable.
    var runtimes: RuntimeSwitchReport?
    /// Context to restore with "Switch Back"; set after switching to Colima.
    var previousContext: String? = UserDefaults.standard.string(forKey: SetupModel.previousContextKey)
    /// A runtime change (context, credentials, plugins, quit) is in progress.
    var isSwitching = false

    @ObservationIgnored unowned let context: any ProfileContext
    @ObservationIgnored private let services: AppServices

    init(context: any ProfileContext, services: AppServices) {
        self.context = context
        self.services = services
    }

    /// Checks the tools at launch and opens the assistant when something is missing (unless turned off).
    func checkAtLaunch() async {
        await check()
        if prerequisites?.isComplete == false, !UserDefaults.standard.bool(forKey: Self.hideAtLaunchKey) {
            isPresented = true
        }
    }

    func check() async {
        prerequisites = await services.checkPrerequisites()
        await checkRuntimes()
    }

    // MARK: - Switching from OrbStack / Docker Desktop (G27)

    func checkRuntimes() async {
        runtimes = await services.runtimeSwitcher.inspect(profile: context.selectedProfileName, socketPath: context.socketPath)
    }

    /// After the profiles are known: opens the assistant when another runtime still owns the docker CLI
    /// (unless the assistant is turned off at launch).
    func checkRuntimesAtLaunch() async {
        await checkRuntimes()
        if runtimes?.needsAttention == true, !UserDefaults.standard.bool(forKey: Self.hideAtLaunchKey) {
            isPresented = true
        }
    }

    /// Points the docker CLI at the selected profile's context and remembers the old one.
    func switchContextToColima() async throws {
        guard let report = runtimes, let target = report.colimaContext else { return }
        let previous = report.currentContext.name
        try await perform { try await self.services.runtimeSwitcher.useContext(target.name) }
        rememberPreviousContext(previous == target.name ? nil : previous)
    }

    /// Restores the context used before `switchContextToColima`.
    func switchContextBack() async throws {
        guard let previous = previousContext else { return }
        try await perform { try await self.services.runtimeSwitcher.useContext(previous) }
        rememberPreviousContext(nil)
    }

    func replaceDesktopCredentials() async throws {
        try await perform { try await self.services.runtimeSwitcher.replaceDesktopCredentials() }
    }

    /// Moves broken plugin links aside; returns where they went.
    @discardableResult
    func moveBrokenPlugins() async throws -> [String] {
        let paths = runtimes?.brokenPlugins.map(\.path) ?? []
        guard !paths.isEmpty else { return [] }
        var moved: [String] = []
        try await perform { moved = try await self.services.runtimeSwitcher.moveAside(plugins: paths) }
        prerequisites = await services.checkPrerequisites()
        return moved
    }

    /// Asks the other app to quit; false when it is still running after a few seconds.
    func quit(_ runtime: OtherDockerRuntime) async -> Bool {
        var exited = false
        try? await perform { exited = await self.services.runtimeSwitcher.quit(runtime) }
        return exited
    }

    private func perform(_ change: () async throws -> Void) async throws {
        isSwitching = true
        defer { isSwitching = false }
        do {
            try await change()
        } catch {
            await checkRuntimes()
            throw error
        }
        await checkRuntimes()
    }

    private func rememberPreviousContext(_ name: String?) {
        previousContext = name
        if let name {
            UserDefaults.standard.set(name, forKey: Self.previousContextKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.previousContextKey)
        }
    }

    /// Runs `brew install` for the missing formulae (the caller has already confirmed), then re-checks.
    func install(_ formulae: [String]) {
        guard !formulae.isEmpty else { return }
        let stream = services.installPrerequisites(formulae)
        let operations = context.operations
        operations.launch { [self] in
            await operations.runOperation(String(localized: "Install \(formulae.joined(separator: ", "))"), stream)
            await check()
            if prerequisites?.colimaPath != nil, operations.errorMessage == ShellError.notFound("colima").localizedDescription {
                operations.errorMessage = nil
            }
            await context.refreshProfiles()
        }
    }
}
