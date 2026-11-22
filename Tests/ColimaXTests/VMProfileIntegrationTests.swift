import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

/// Real VM / profile lifecycle (Runtime checklist). Slow (several minutes) and resource-heavy, so it runs only
/// when both `COLIMAX_INTEGRATION=1` and `COLIMAX_INTEGRATION_VM=1` are set. Creates / deletes only its own
/// `colimax-test-<id>` profile; never touches the user's other profiles.
final class VMProfileIntegrationTests: XCTestCase {
    private let profile = "colimax-test-\(UUID().uuidString.prefix(6).lowercased())"
    private var created = false

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["COLIMAX_INTEGRATION"] == "1", env["COLIMAX_INTEGRATION_VM"] == "1" else {
            throw XCTSkip("Set COLIMAX_INTEGRATION=1 and COLIMAX_INTEGRATION_VM=1 to run (creates a test VM, takes several minutes)")
        }
        guard Shell.which("colima") != nil else { throw XCTSkip("colima is not installed") }
        XCTAssertTrue(ColimaService.isValidProfileName(profile))
    }

    override func tearDown() async throws {
        // Safety: delete only the profile this test created.
        guard created, profile.hasPrefix("colimax-test-") else { return }
        if (try? await ColimaService.listProfiles())?.contains(where: { $0.name == profile }) == true {
            for try await _ in ColimaService.delete(profile, deleteData: true) {}
        }
    }

    private func drain(_ stream: AsyncThrowingStream<String, Error>) async throws {
        for try await _ in stream {}
    }

    private func current() async throws -> ColimaProfile? {
        try await ColimaService.listProfiles().first { $0.name == profile }
    }

    private func diskGiB(_ p: ColimaProfile?) -> Double {
        Double(p?.disk ?? 0) / 1_073_741_824
    }

    /// Create a small profile -> start -> Docker responds -> stop -> shrink disk (delete VM + data and recreate,
    /// like `AppStore.applyRuntimeConfig(recreate: true, deleteData: true)`) -> delete the profile.
    func testProfileLifecycleAndDiskShrink() async throws {
        let existing = try await ColimaService.listProfiles()
        XCTAssertFalse(existing.contains { $0.name == profile })

        var config = RuntimeConfig()
        config.cpus = 1
        config.memoryGiB = 1
        config.diskGiB = 12
        created = true
        try await drain(ColimaService.start(profile, config: config))

        var listed = try await current()
        var info = try XCTUnwrap(listed, "new profile should appear in colima list")
        XCTAssertTrue(info.isRunning, info.status)
        XCTAssertEqual(info.cpus, 1)
        XCTAssertEqual(diskGiB(info), 12, accuracy: 1)
        XCTAssertEqual(ColimaService.readConfig(profile)?.diskGiB, 12)

        let status = try await ColimaService.status(profile)
        let client = DockerClient(socketPath: ColimaService.resolveDockerSocket(profile, status: status))
        try await client.ping()

        try await drain(ColimaService.stop(profile))
        listed = try await current()
        info = try XCTUnwrap(listed)
        XCTAssertFalse(info.isRunning, info.status)

        // Shrinking the disk is only possible by recreating the VM and deleting its data.
        config.diskGiB = 10
        try await drain(ColimaService.delete(profile, deleteData: true))
        try await drain(ColimaService.start(profile, config: config))
        listed = try await current()
        info = try XCTUnwrap(listed)
        XCTAssertTrue(info.isRunning, info.status)
        XCTAssertEqual(diskGiB(info), 10, accuracy: 1)
        XCTAssertEqual(ColimaService.readConfig(profile)?.diskGiB, 10)

        try await drain(ColimaService.delete(profile, deleteData: true))
        let after = try await current()
        XCTAssertNil(after, "profile should be deleted")
        created = after != nil

        // The user's other profiles are unaffected.
        let remaining = Set(try await ColimaService.listProfiles().map(\.name))
        XCTAssertTrue(remaining.isSuperset(of: existing.map(\.name)))
    }
}
