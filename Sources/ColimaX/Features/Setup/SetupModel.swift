import Foundation
import Observation

/// External tool check and installation (G26): Homebrew, colima, docker CLI, compose plugin.
@MainActor
@Observable
final class SetupModel {
    static let hideAtLaunchKey = "hideSetupAtLaunch"

    /// Result of the last check; nil until checked.
    var prerequisites: PrerequisiteReport?
    /// Shows the setup assistant (`SetupSheet`).
    var isPresented = false

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
