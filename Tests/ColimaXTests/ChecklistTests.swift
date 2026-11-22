import XCTest
#if SWIFT_PACKAGE
@testable import ColimaX
#endif

// Items of the manual pre-release checklist (docs/TESTING.md) that only depend on app logic, moved to
// unit tests. UI wiring of the same items is covered by the XCUITest suite.

/// Pure decisions behind checklist items: runtime change confirmations, Diagnostics filtering,
/// Storage volume cleanup.
final class ChecklistLogicTests: XCTestCase {
    func testRuntimeChangePlanPicksTheRightConfirmation() {
        let original = RuntimeConfig()
        XCTAssertEqual(RuntimeChange.plan(from: original, to: original, isRunning: true), .none)

        var cpus = original
        cpus.cpus += 1
        XCTAssertEqual(RuntimeChange.plan(from: original, to: cpus, isRunning: true), .restart, "running VM: asks to restart")
        XCTAssertEqual(RuntimeChange.plan(from: original, to: cpus, isRunning: false), .apply, "stopped VM: applies without asking")

        var bigger = original
        bigger.diskGiB += 10
        XCTAssertEqual(RuntimeChange.plan(from: original, to: bigger, isRunning: true), .restart, "growing the disk only restarts")

        for change in [\RuntimeConfig.arch, \RuntimeConfig.runtime, \RuntimeConfig.vmType] {
            var draft = original
            draft[keyPath: change] = "other"
            XCTAssertEqual(RuntimeChange.plan(from: original, to: draft, isRunning: false), .recreate, "\(change) needs a new VM")
        }

        var smaller = original
        smaller.diskGiB -= 10
        smaller.arch = "x86_64"
        XCTAssertEqual(RuntimeChange.plan(from: original, to: smaller, isRunning: true), .shrinkDisk,
                       "a smaller disk always takes the typed confirmation, even with other recreate changes")

        XCTAssertTrue(RuntimeChange.shrinkDisk.recreatesVM)
        XCTAssertTrue(RuntimeChange.recreate.recreatesVM)
        XCTAssertFalse(RuntimeChange.restart.recreatesVM)
        XCTAssertFalse(RuntimeChange.apply.recreatesVM)
    }

    func testDiagnosticsGroupFilterHideOKAndOrder() {
        func item(_ category: DiagnosticItem.Category, _ severity: DiagnosticItem.Severity, _ title: String) -> DiagnosticItem {
            DiagnosticItem(category: category, severity: severity, title: title, detail: "")
        }
        let items = [
            item(.runtime, .ok, "B runtime ok"),
            item(.security, .critical, "Privileged"),
            item(.runtime, .warning, "A runtime warning"),
            item(.ports, .info, "Port"),
            item(.runtime, .ok, "A runtime ok"),
        ]
        XCTAssertEqual(DiagnosticItem.visible(items, category: nil, hideOK: false).map(\.title),
                       ["Privileged", "A runtime warning", "Port", "A runtime ok", "B runtime ok"],
                       "most severe first, then by title")
        XCTAssertEqual(DiagnosticItem.visible(items, category: .runtime, hideOK: false).map(\.title),
                       ["A runtime warning", "A runtime ok", "B runtime ok"])
        XCTAssertEqual(DiagnosticItem.visible(items, category: .runtime, hideOK: true).map(\.title), ["A runtime warning"])
        XCTAssertEqual(DiagnosticItem.visible(items, category: nil, hideOK: true).count, 3)
        XCTAssertTrue(DiagnosticItem.visible(items, category: .appleSilicon, hideOK: false).isEmpty)
    }

    func testStorageCleanupRemovesOnlyTickedUnusedVolumes() {
        var report = StorageReport()
        report.unusedVolumes = ["old-a", "old-b", "old-c"].map { StorageReport.Item(id: $0, name: $0, size: 1) }
        // "in-use" was ticked earlier but a container mounts it now, so the refreshed report no longer lists it.
        XCTAssertEqual(report.unusedVolumeNames(selected: ["old-a", "old-c", "in-use"]), ["old-a", "old-c"])
        XCTAssertEqual(report.unusedVolumeNames(selected: []), [])
    }
}

/// Checklist items that involve the stores, run against `FakeColima` / `FakeDocker`.
@MainActor
final class ChecklistStoreTests: XCTestCase {
    private var colima: FakeColima!
    private var docker: FakeDocker!
    /// Notifications posted through `AppServices.notify`, as "title|body".
    private let notifications = Locked<[String]>([])

    private func makeStore(containersRunning: Bool = true, prerequisites: FakePrerequisites? = nil) -> AppStore {
        colima = FakeColima(profiles: [FakeColima.profile("default", running: true), FakeColima.profile("dev", running: false)])
        let state = containersRunning ? "running" : "exited"
        docker = FakeDocker(containers: [
            FakeDocker.container("c1", name: "web", state: state),
            FakeDocker.container("c2", name: "db", image: "postgres:16", state: state),
        ])
        let docker = docker!
        let tools = prerequisites ?? FakePrerequisites(brew: "/opt/homebrew/bin/brew", colima: "/opt/homebrew/bin/colima",
                                                       docker: "/opt/homebrew/bin/docker", compose: true)
        let notifications = notifications
        let services = AppServices(
            colima: colima, makeDocker: { _ in docker },
            checkPrerequisites: { tools.report() },
            installPrerequisites: { tools.install($0) },
            watchesColimaDirectory: false,
            notify: { title, body in notifications.withLock { $0.append("\(title)|\(body)") } },
            scannerTools: { [] }
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

    /// Runs `body` with a UserDefaults key temporarily set, restoring the previous value afterwards.
    private func withDefault(_ key: String, _ value: Any?, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: key)
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        defer { if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) } }
        try await body()
    }

    private func makeTempDirectory() throws -> URL {
        let url = TestSupport.tempRoot.appendingPathComponent("colimax-checklist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - Setup Assistant (G26)

    func testSetupAssistantStaysClosedWhenAllToolsAreInstalled() async {
        let store = makeStore()
        await withDefault(SetupModel.hideAtLaunchKey, nil) {
            await store.setupModel.checkAtLaunch()
        }
        XCTAssertEqual(store.setupModel.prerequisites?.isComplete, true)
        XCTAssertFalse(store.setupModel.isPresented, "nothing missing: the assistant does not open by itself")
    }

    func testTurningOffShowAtLaunchKeepsTheAssistantClosed() async {
        let store = makeStore(prerequisites: FakePrerequisites(brew: nil, colima: nil, docker: nil, compose: false))
        await withDefault(SetupModel.hideAtLaunchKey, true) {
            await store.setupModel.checkAtLaunch()
        }
        XCTAssertEqual(store.setupModel.prerequisites?.isComplete, false)
        XCTAssertFalse(store.setupModel.isPresented, "turned off: tools are missing but the sheet stays closed")
    }

    func testSetupInstallStreamsLogThenRechecksAndRefreshesProfiles() async {
        let tools = FakePrerequisites(brew: "/opt/homebrew/bin/brew", colima: "/opt/homebrew/bin/colima", docker: nil, compose: false)
        let store = makeStore(prerequisites: tools)
        await store.setupModel.check()
        XCTAssertEqual(store.setupModel.prerequisites?.missingFormulae, ["docker", "docker-compose"])

        store.setupModel.install(["docker-compose", "docker", "rm -rf"])
        await store.operations.waitForOperation()
        await waitUntil { store.setupModel.prerequisites?.isComplete == true }

        XCTAssertEqual(store.operations.operation?.status, .succeeded)
        XCTAssertEqual(store.operations.operation?.title, "Install docker-compose, docker, rm -rf")
        XCTAssertEqual(store.operations.operation?.lines.filter { $0.hasPrefix("==> Installing") },
                       ["==> Installing docker", "==> Installing docker-compose"], "only allowlisted formulae, in a fixed order")
        XCTAssertTrue(colima.calls.contains("list"), "profiles are refreshed after installing")
    }

    func testCancellingSetupInstallMarksCancelledAndInstallsNothing() async {
        let tools = FakePrerequisites(brew: "/opt/homebrew/bin/brew", colima: nil, docker: nil, compose: false)
        let store = makeStore(prerequisites: tools)
        store.setupModel.install(["colima", "docker", "docker-compose"])
        await waitUntil { store.operations.isOperationRunning }
        store.operations.cancelOperation()
        await store.operations.waitForOperation()
        XCTAssertEqual(store.operations.operation?.status, .cancelled)
        XCTAssertNil(store.operations.errorMessage)
        await store.setupModel.check()
        XCTAssertEqual(store.setupModel.prerequisites?.colimaPath, nil, "a cancelled install leaves the tools missing")
    }

    // MARK: - VM stop / restart confirmation

    func testStopAndRestartAskOnlyWhileContainersRun() async {
        var asked: [String] = []
        let store = makeStore()
        await store.refreshProfiles()
        await waitUntil { store.runningCount == 2 }

        VMControl.stop(store) { title, message, _ in asked.append("\(title) \(message)"); return false }
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].hasPrefix("Stop default?"), asked[0])
        XCTAssertTrue(asked[0].contains("(2)"), "the message shows how many containers will stop: \(asked[0])")
        XCTAssertFalse(colima.calls.contains("stop default"), "Cancel keeps the VM running")

        VMControl.restart(store) { _, _, _ in true }
        await store.operations.waitForOperation()
        XCTAssertTrue(colima.calls.contains("restart default"), "confirming restarts the VM")
    }

    func testStopWithoutRunningContainersActsImmediately() async {
        let store = makeStore(containersRunning: false)
        await store.refreshProfiles()
        await waitUntil { store.containers.count == 2 }
        XCTAssertEqual(store.runningCount, 0)
        VMControl.stop(store) { _, _, _ in XCTFail("must not ask when no container runs"); return false }
        await store.operations.waitForOperation()
        XCTAssertTrue(colima.calls.contains("stop default"))
    }

    // MARK: - Compose

    func testAddingAComposeProjectFromAFolderDoesNotStartIt() async throws {
        let directory = try makeTempDirectory().appendingPathComponent("my-app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("services:\n  web:\n    image: nginx\n".utf8).write(to: directory.appendingPathComponent("compose.yaml"))
        let found = try XCTUnwrap(ComposeDiscovery.scan(directory))

        let store = makeStore()
        let saved = store.composeModel.savedProjects
        defer { store.composeModel.savedProjects = saved }
        store.composeModel.add(ComposeProject(name: ComposeProject.defaultName(for: directory), workingDir: directory.path,
                                              configFiles: found.files.map(\.path)))

        XCTAssertTrue(store.composeModel.projects.contains { $0.name == "my-app" })
        XCTAssertNil(store.operations.operation, "adding a project starts no compose command")
        XCTAssertTrue(docker.calls.isEmpty)
    }

    // MARK: - Notifications

    func testContainerExitNotifiesOnlyForUnexpectedNonZeroExits() async {
        let store = makeStore()
        let previous = store.settings.notifyContainerExit
        defer { store.settings.notifyContainerExit = previous }
        store.settings.notifyContainerExit = true
        await store.refreshProfiles()
        await waitUntil { store.dockerConnected && self.docker.state.withLock { !$0.eventContinuations.isEmpty } }

        docker.emit("container", "die", id: "c1", attributes: ["name": "web", "exitCode": "137"])
        docker.emit("container", "die", id: "c2", attributes: ["name": "db", "exitCode": "0"])
        docker.emit("container", "die", id: "c3", attributes: ["name": "colimax-test-x", "exitCode": "1", "dev.colimax.test": "1"])
        await waitUntil { !self.notifications.current.isEmpty }
        await store.waitForPendingReload()
        XCTAssertEqual(notifications.current, ["Container exited unexpectedly|web exited with code 137"],
                       "exit 0 and integration-test containers do not notify")

        store.settings.notifyContainerExit = false
        docker.emit("container", "die", id: "c1", attributes: ["name": "web", "exitCode": "1"])
        await store.waitForPendingReload()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(notifications.current.count, 1, "turned off in Preferences: no notification")
    }

    func testVMStartNotifiesWhenEnabled() async {
        let store = makeStore()
        let previous = store.settings.notifyVMChanges
        defer { store.settings.notifyVMChanges = previous }
        await store.refreshProfiles()

        store.settings.notifyVMChanges = true
        store.select("dev")
        store.runtimeModel.startVM()
        await store.operations.waitForOperation()
        XCTAssertEqual(notifications.current, ["Colima|Profile dev is running"])

        store.settings.notifyVMChanges = false
        store.runtimeModel.stopVM()
        await store.operations.waitForOperation()
        XCTAssertEqual(notifications.current.count, 1, "turned off: stopping does not notify")
    }

    func testScheduledBackupFailureShowsErrorAndNotifies() async throws {
        final class Host: BackupSchedulerHost {
            let engine: FakeDocker
            var notified: [String] = []
            init(engine: FakeDocker) { self.engine = engine }
            var runningProfileNames: Set<String> = ["default"]
            func docker(forProfile profile: String) -> any DockerEngine { engine }
            var notifyBackupFailure = true
            func notify(title: String, body: String) { notified.append("\(title)|\(body)") }
        }
        // A stopped VM shows up as an unreachable Docker socket.
        let engine = FakeDocker(volumes: [FakeDocker.volume("data")])
        engine.fail("createContainer", "Cannot connect to the Docker daemon")
        let host = Host(engine: engine)
        let scheduler = BackupScheduler()
        let saved = scheduler.schedules
        defer { scheduler.schedules = saved }
        scheduler.host = host
        scheduler.schedules = [BackupSchedule(profile: "default", target: .volume(name: "data"), interval: .hourly,
                                              directory: try makeTempDirectory().path, keep: 1)]
        await scheduler.tick()

        XCTAssertNotNil(scheduler.schedules[0].lastRun)
        XCTAssertEqual(scheduler.schedules[0].lastError?.contains("Cannot connect to the Docker daemon"), true,
                       "the Backups screen shows the last error")
        XCTAssertNil(scheduler.schedules[0].lastSuccess)
        XCTAssertEqual(host.notified.count, 1)
        XCTAssertTrue(host.notified[0].hasPrefix("Scheduled backup failed|"), host.notified[0])
    }

    func testResourceAlertNotifiesOnceUntilRecovery() async throws {
        final class Host: ResourceWatcherHost {
            var notified: [String] = []
            var selectedProfileName = "colimax-test-alerts"
            var canSampleResources = true
            var docker: any DockerEngine = FakeDocker()
            var colima: any ColimaControlling = FakeColima()
            var containers = [FakeDocker.container("c1", name: "busy")]
            // FakeDocker.stats: 20 % of the VM's CPU, about 10 % of the memory limit.
            var alertThresholds = AlertThresholds(cpuPercent: 10, memoryPercent: 99, diskPercent: 99, sustainSamples: 1)
            var notifyResourceAlerts = true
            func notify(title: String, body: String) { notified.append(title) }
        }
        let host = Host()
        let watcher = ResourceWatcher()
        watcher.historyDirectory = try makeTempDirectory()
        watcher.host = host

        await watcher.tick()
        await watcher.tick()
        await watcher.tick()
        XCTAssertEqual(host.notified, ["Resource alert"], "a sustained breach alerts once, not on every sample")
        XCTAssertEqual(watcher.recentAlerts.count, 1)

        host.notifyResourceAlerts = false
        host.containers = [FakeDocker.container("c2", name: "other-busy")]
        await watcher.tick()
        XCTAssertEqual(watcher.recentAlerts.count, 2, "the alert is still recorded")
        XCTAssertEqual(host.notified.count, 1, "but no notification when turned off")
    }
}
