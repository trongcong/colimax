import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

/// Stores and per-screen models driven by in-memory fakes (no VM, no Docker socket).
@MainActor
final class StoreTests: XCTestCase {
    private var colima: FakeColima!
    private var docker: FakeDocker!

    private func makeStore(running: Bool = true) -> AppStore {
        colima = FakeColima(profiles: [FakeColima.profile("default", running: running), FakeColima.profile("dev", running: false)])
        docker = FakeDocker(
            containers: [
                FakeDocker.container("c1", name: "web"),
                FakeDocker.container("c2", name: "db", image: "postgres:16", labels: ["com.docker.compose.project": "shop"]),
            ],
            images: [FakeDocker.image("sha256:1", tag: "nginx:latest")],
            volumes: [FakeDocker.volume("data")],
            networks: [FakeDocker.network("app-net")]
        )
        let docker = docker!
        let services = AppServices(
            colima: colima, makeDocker: { _ in docker },
            checkPrerequisites: { PrerequisiteReport(composeAvailable: false) },
            installPrerequisites: { _ in AsyncThrowingStream { $0.finish() } },
            watchesColimaDirectory: false
        )
        let store = AppStore(settings: AppSettings(), services: services)
        store.eventCoalescing = .milliseconds(10)
        store.selectedProfileName = "default"
        addTeardownBlock { store.shutdown() }
        return store
    }

    private func waitUntil(_ timeout: Duration = .seconds(3), _ condition: () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { XCTFail("Timed out waiting for condition", file: file, line: line); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Connection and reload

    func testRefreshProfilesConnectsAndLoadsDockerData() async {
        let store = makeStore()
        await store.refreshProfiles()
        XCTAssertTrue(store.isRunning)
        await waitUntil { store.containers.count == 2 && store.dockerConnected }
        XCTAssertEqual(store.images.count, 1)
        XCTAssertEqual(store.volumes.map(\.name), ["data"])
        XCTAssertEqual(store.networks.map(\.name), ["app-net"])
        XCTAssertEqual(store.runningCount, 2)
    }

    func testOneFailingEndpointDoesNotBlockOthersAndErrorClearsAfterRecovery() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.dockerConnected }
        docker.fail("images", "images endpoint down")
        await store.reloadAll()
        XCTAssertEqual(store.operations.errorMessage, "images endpoint down")
        XCTAssertEqual(store.containers.count, 2, "containers still load when images fail")
        docker.fail("images", nil)
        await store.reloadAll()
        XCTAssertNil(store.operations.errorMessage, "the reload error is cleared after a successful reload")
    }

    func testUnrelatedErrorIsNotClearedByReload() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.dockerConnected }
        store.operations.errorMessage = "something else failed"
        await store.reloadAll()
        XCTAssertEqual(store.operations.errorMessage, "something else failed")
    }

    func testDockerEventTriggersCoalescedReload() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.containers.count == 2 && store.dockerConnected }
        // Give the events loop time to subscribe before mutating.
        await waitUntil { self.docker.state.withLock { !$0.eventContinuations.isEmpty } }
        let container = store.containers[0]
        await store.containersModel.remove(container, volumes: false)?.value
        await waitUntil { store.containers.count == 1 }
        XCTAssertEqual(docker.calls, ["remove container c1 volumes=false"])
    }

    func testStoppedProfileClearsDockerData() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.containers.count == 2 }
        store.runtimeModel.stopVM()
        await store.operations.waitForOperation()
        XCTAssertEqual(store.operations.operation?.status, .succeeded)
        XCTAssertTrue(colima.calls.contains("stop default"))
        XCTAssertFalse(store.isRunning)
        XCTAssertTrue(store.containers.isEmpty)
        XCTAssertFalse(store.dockerConnected)
    }

    func testSelectingAStoppedProfileClearsData() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.containers.count == 2 }
        store.select("dev")
        XCTAssertEqual(store.selectedProfileName, "dev")
        XCTAssertTrue(store.containers.isEmpty)
    }

    // MARK: - Runtime model

    func testFailedVMOperationReportsErrorAndRefreshes() async {
        let store = makeStore()
        await store.refreshProfiles()
        colima.state.withLock { $0.failLifecycle = "VM refused to start" }
        store.select("dev")
        store.runtimeModel.startVM()
        await store.operations.waitForOperation()
        XCTAssertEqual(store.operations.operation?.status, .failed("VM refused to start"))
        XCTAssertEqual(store.operations.errorMessage, "VM refused to start")
        XCTAssertEqual(colima.calls.filter { $0 != "list" }, ["start dev"])
    }

    func testRecreateDeletesThenStartsWithConfig() async {
        let store = makeStore()
        await store.refreshProfiles()
        store.runtimeModel.applyRuntimeConfig(RuntimeConfig(), recreate: true, deleteData: true)
        await store.operations.waitForOperation()
        XCTAssertEqual(colima.calls.filter { $0 != "list" }, ["delete default data", "start default"])
    }

    func testApplyWithoutRecreateStopsRunningVMFirst() async {
        let store = makeStore()
        await store.refreshProfiles()
        store.runtimeModel.applyRuntimeConfig(RuntimeConfig(), recreate: false, deleteData: false)
        await store.operations.waitForOperation()
        XCTAssertEqual(colima.calls.filter { $0 != "list" }, ["stop default", "start default"])
    }

    func testCreateProfileRejectsInvalidNameAndSelectsNewProfile() async {
        let store = makeStore()
        await store.refreshProfiles()
        store.runtimeModel.createProfile("bad name/..", config: RuntimeConfig())
        XCTAssertFalse(colima.calls.contains { $0.hasPrefix("start") })
        store.runtimeModel.createProfile("fresh", config: RuntimeConfig())
        await store.operations.waitForOperation()
        XCTAssertEqual(store.selectedProfileName, "fresh")
        XCTAssertTrue(store.isRunning)
    }

    // MARK: - Operation center

    func testSecondLongOperationIsIgnoredWhileOneRuns() async {
        let operations = OperationCenter()
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        XCTAssertTrue(operations.launch { await operations.runOperation("first", stream) })
        await waitUntil { operations.isOperationRunning }
        XCTAssertFalse(operations.launch { await operations.runOperation("second", AsyncThrowingStream { $0.finish() }) })
        continuation.finish()
        await operations.waitForOperation()
        XCTAssertEqual(operations.operation?.title, "first")
        XCTAssertEqual(operations.operation?.status, .succeeded)
    }

    func testCancelOperationMarksCancelled() async {
        let operations = OperationCenter()
        let (stream, _) = AsyncThrowingStream<String, Error>.makeStream()
        operations.launch { await operations.runOperation("hang", stream) }
        await waitUntil { operations.isOperationRunning }
        operations.cancelOperation()
        await operations.waitForOperation()
        XCTAssertEqual(operations.operation?.status, .cancelled)
        XCTAssertNil(operations.errorMessage)
    }

    func testPerformIgnoresDuplicateKeyAndReportsErrors() async {
        let operations = OperationCenter()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let first = operations.perform("k") { for await _ in gate { break } }
        XCTAssertNotNil(first)
        XCTAssertNil(operations.perform("k") {}, "same key while busy is ignored")
        XCTAssertTrue(operations.busy.contains("k"))
        open.yield()
        await first?.value
        XCTAssertFalse(operations.busy.contains("k"))
        await operations.perform("k") { throw FakeError(message: "nope") }?.value
        XCTAssertEqual(operations.errorMessage, "nope")
    }

    func testOperationLogIsBounded() async {
        let operations = OperationCenter()
        let stream = AsyncThrowingStream<String, Error> { c in
            for i in 0..<(OperationCenter.maxLogLines + 100) { c.yield("line \(i)") }
            c.finish()
        }
        await operations.runOperation("big", stream)
        XCTAssertLessThanOrEqual(operations.operation?.lines.count ?? 0, OperationCenter.maxLogLines)
        XCTAssertEqual(operations.operation?.lines.last, "line \(OperationCenter.maxLogLines + 99)")
    }

    // MARK: - Feature models

    func testPullKeepsOneLinePerLayer() async {
        let store = makeStore()
        store.imagesModel.pull("nginx")
        await store.operations.waitForOperation()
        XCTAssertEqual(store.operations.operation?.status, .succeeded)
        XCTAssertEqual(store.operations.operation?.lines.count, 2)
        XCTAssertEqual(docker.calls, ["pull nginx"])
    }

    func testFailedActionSurfacesErrorAndClearsBusy() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.containers.count == 2 }
        docker.fail("containerAction", "cannot stop")
        await store.containersModel.perform("stop", on: store.containers[0])?.value
        XCTAssertEqual(store.operations.errorMessage, "cannot stop")
        XCTAssertTrue(store.operations.busy.isEmpty)
    }

    func testVolumesRemoveManyReportsPartialFailure() async {
        let store = makeStore()
        await store.refreshProfiles()
        await store.volumesModel.remove(names: ["data", "missing"])?.value
        XCTAssertEqual(store.operations.errorMessage?.contains("missing"), true)
        XCTAssertEqual(docker.state.current.volumes.count, 0)
    }

    func testNetworkConnectFlashesMessage() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.containers.count == 2 && store.networks.count == 1 }
        await store.networksModel.connect(store.containers[0], to: store.networks[0])?.value
        XCTAssertEqual(docker.calls, ["connect c1 net-app-net"])
        XCTAssertNotNil(store.operations.flashMessage)
    }

    func testImagePlatformsLoadAndResetWhenDataCleared() async {
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.images.count == 1 }
        await store.imagesModel.loadPlatforms()
        XCTAssertEqual(store.imagesModel.platforms["sha256:1"]?.architecture, "arm64")
        store.select("dev")
        XCTAssertTrue(store.imagesModel.platforms.isEmpty)
    }

    func testComposeProjectsMergeLabelsAndSaved() {
        let saved = [ComposeProject(name: "shop", workingDir: "/srv/shop", configFiles: ["/srv/shop/compose.yaml"]),
                     ComposeProject(name: "only-saved", workingDir: "/x", configFiles: [])]
        let containers = [FakeDocker.container("c2", name: "db", labels: ["com.docker.compose.project": "shop"])]
        let merged = ComposeModel.merge(containers: containers, saved: saved)
        XCTAssertEqual(merged.map(\.name), ["only-saved", "shop"])
        XCTAssertEqual(merged[1].workingDir, "/srv/shop")
        XCTAssertEqual(merged[1].configFiles, ["/srv/shop/compose.yaml"])
    }

    func testSetupModelOpensAssistantWhenToolsMissing() async {
        let store = makeStore()
        UserDefaults.standard.removeObject(forKey: SetupModel.hideAtLaunchKey)
        await store.setupModel.checkAtLaunch()
        XCTAssertEqual(store.setupModel.prerequisites?.isComplete, false)
        XCTAssertTrue(store.setupModel.isPresented)
    }

    // MARK: - Hosts (narrow protocols instead of weak AppStore references)

    func testAppStoreIsHostOfBackgroundStores() async {
        let store = makeStore()
        XCTAssertTrue(store.scheduler.host === store)
        XCTAssertTrue(store.resources.host === store)
        XCTAssertTrue(store.proxy.host === store)
        await store.refreshProfiles()
        XCTAssertEqual(store.runningProfileNames, ["default"])
        store.settings.backgroundMonitoring = false
        XCTAssertFalse(store.canSampleResources)
        store.settings.backgroundMonitoring = true
        XCTAssertTrue(store.canSampleResources)
    }

    func testResourceWatcherSkipsWhenHostCannotSample() async {
        final class Host: ResourceWatcherHost {
            var selectedProfileName = "default"
            var canSampleResources = false
            var docker: any DockerEngine = FakeDocker()
            var colima: any ColimaControlling = FakeColima()
            var containers: [DockerContainer] = []
            var alertThresholds = AlertThresholds.default
            var notifyResourceAlerts = false
            func notify(title: String, body: String) {}
        }
        let host = Host()
        let watcher = ResourceWatcher()
        watcher.host = host
        await watcher.tick()
        XCTAssertNil(watcher.lastSample)
    }

    func testBackupSchedulerSkipsProfilesThatAreNotRunning() async {
        final class Host: BackupSchedulerHost {
            var runningProfileNames: Set<String> = []
            func docker(forProfile profile: String) -> any DockerEngine { FakeDocker() }
            var notifyBackupFailure = false
            func notify(title: String, body: String) {}
        }
        let scheduler = BackupScheduler()
        let saved = scheduler.schedules
        defer { scheduler.schedules = saved }
        let host = Host()
        scheduler.host = host
        scheduler.schedules = [BackupSchedule(profile: "default", target: .volume(name: "data"), interval: .hourly,
                                              directory: TestSupport.tempRoot.path, keep: 1)]
        await scheduler.tick()
        XCTAssertNil(scheduler.schedules[0].lastRun, "a schedule whose profile is stopped stays due")
    }

    // MARK: - UI-test fixtures

    func testUITestFixturesProvideMaskedSecretAndContainers() async throws {
        let services = UITestFixtures.services()
        let docker = services.makeDocker("/unused")
        let containers = try await docker.containers()
        XCTAssertEqual(containers.map(\.name), ["web", "db", "worker"])
        let platform = try await docker.imagePlatform("sha256:ccc")
        XCTAssertEqual(platform.architecture, "amd64", "one non-arm64 image for the Arch column warning")
        let details = try await docker.containerDetails("c-db")
        let secret = try XCTUnwrap(details.environment.first { $0.key == "POSTGRES_PASSWORD" })
        XCTAssertTrue(secret.isSensitive)
        XCTAssertNotEqual(secret.maskedValue, UITestFixtures.databasePassword)
        XCTAssertEqual(services.colima.readConfig("default"), RuntimeConfig())
    }

    func testDemoFixturesHaveMovingStatsAndRealisticData() async throws {
        let services = UITestFixtures.services(scenario: .demo)
        let docker = services.makeDocker("/unused")
        let containers = try await docker.containers()
        XCTAssertEqual(Set(containers.compactMap(\.composeProject)), ["shop", "blog"])
        XCTAssertGreaterThanOrEqual(containers.filter(\.isRunning).count, 8)
        let info = try await docker.info()
        XCTAssertEqual(info.serverVersion, "27.3.1")
        let usage = try await docker.diskUsage()
        XCTAssertGreaterThan(usage.buildCacheSize, 0)

        // Two VM readings give a CPU %.
        let first = try await services.colima.vmUsage("default")
        let second = try await services.colima.vmUsage("default")
        let cpu = try XCTUnwrap(second.cpuPercent(since: first))
        XCTAssertGreaterThan(cpu, 0)
        XCTAssertLessThan(cpu, 100)

        // A running container streams samples; the stopped one streams nothing.
        let api = try XCTUnwrap(containers.first { $0.name == "shop-api-1" })
        var iterator = docker.statsStream(api.id).makeAsyncIterator()
        let sample = try await iterator.next()
        XCTAssertGreaterThan(try XCTUnwrap(sample).cpuPercent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(sample).memoryUsed, 0)

        // Secrets in the demo environment are masked like the real ones.
        let details = try await docker.containerDetails(api.id)
        XCTAssertTrue(try XCTUnwrap(details.environment.first { $0.key == "STRIPE_SECRET_KEY" }).isSensitive)
    }
}
