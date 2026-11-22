import Foundation

/// The Colima operations the stores use. `LiveColima` runs the real `colima` CLI through `ColimaService`;
/// tests and the UI-test build substitute a fake.
protocol ColimaControlling: Sendable {
    func listProfiles() async throws -> [ColimaProfile]
    func status(_ profile: String) async throws -> ColimaStatus
    func start(_ profile: String, config: RuntimeConfig?) -> AsyncThrowingStream<String, Error>
    func stop(_ profile: String) -> AsyncThrowingStream<String, Error>
    func restart(_ profile: String) -> AsyncThrowingStream<String, Error>
    func delete(_ profile: String, deleteData: Bool) -> AsyncThrowingStream<String, Error>
    func vmUsage(_ profile: String) async throws -> VMUsage
    func readConfig(_ profile: String) -> RuntimeConfig?
}

/// The real Colima CLI.
struct LiveColima: ColimaControlling {
    func listProfiles() async throws -> [ColimaProfile] { try await ColimaService.listProfiles() }
    func status(_ profile: String) async throws -> ColimaStatus { try await ColimaService.status(profile) }
    func start(_ profile: String, config: RuntimeConfig?) -> AsyncThrowingStream<String, Error> { ColimaService.start(profile, config: config) }
    func stop(_ profile: String) -> AsyncThrowingStream<String, Error> { ColimaService.stop(profile) }
    func restart(_ profile: String) -> AsyncThrowingStream<String, Error> { ColimaService.restart(profile) }
    func delete(_ profile: String, deleteData: Bool) -> AsyncThrowingStream<String, Error> { ColimaService.delete(profile, deleteData: deleteData) }
    func vmUsage(_ profile: String) async throws -> VMUsage { try await ColimaService.vmUsage(profile) }
    func readConfig(_ profile: String) -> RuntimeConfig? { ColimaService.readConfig(profile) }
}
