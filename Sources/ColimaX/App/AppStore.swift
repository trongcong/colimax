import Foundation
import Observation

/// Global app state: the Colima profiles, the selected profile's Docker data and its live connection
/// (events, reloads), and navigation. Actions live in per-screen models (`runtimeModel`,
/// `containersModel`, …) and in `operations`; background work lives in `scheduler`, `resources` and
/// `proxy`. Those depend on narrow protocols (`DockerContext`, `ProfileContext`, `…Host`), not on
/// this class.
@MainActor
@Observable
final class AppStore {
    let settings: AppSettings
    @ObservationIgnored let services: AppServices
    let operations = OperationCenter()
    let scheduler = BackupScheduler()
    let resources = ResourceWatcher()
    let proxy = ProxyStore()

    // Per-screen models. They hold an unowned reference back to this store through a narrow protocol.
    @ObservationIgnored private(set) lazy var runtimeModel = RuntimeModel(context: self)
    @ObservationIgnored private(set) lazy var setupModel = SetupModel(context: self, services: services)
    @ObservationIgnored private(set) lazy var containersModel = ContainersModel(context: self)
    @ObservationIgnored private(set) lazy var composeModel = ComposeModel(context: self)
    @ObservationIgnored private(set) lazy var imagesModel = ImagesModel(context: self)
    @ObservationIgnored private(set) lazy var volumesModel = VolumesModel(context: self)
    @ObservationIgnored private(set) lazy var networksModel = NetworksModel(context: self)
    @ObservationIgnored private(set) lazy var storageModel = StorageModel(context: self)

    // MARK: Colima
    var profiles: [ColimaProfile] = []
    var selectedProfileName: String {
        didSet { UserDefaults.standard.set(selectedProfileName, forKey: "selectedProfile") }
    }
    var profilesLoaded = false

    // MARK: Docker data
    var containers: [DockerContainer] = []
    var images: [DockerImage] = []
    var volumes: [DockerVolume] = []
    var networks: [DockerNetwork] = []
    var volumeUsage: [String: DockerVolume.UsageData] = [:]
    var info: DockerInfo?
    var diskUsage: DiskUsage?
    var vmUsage: VMUsage?
    var vmCPUPercent: Double?
    var dockerConnected = false
    /// `colima status --json` of the running profile; the source of the Docker endpoint.
    var runtimeStatus: ColimaStatus?

    // MARK: Navigation
    var screen: Screen = .dashboard
    /// Container to preselect when the Containers screen opens (e.g. from the menu bar).
    var focusContainerID: String?
    /// Elasticsearch container whose snapshot sheet is open (opened from the container actions menu).
    var snapshotTarget: DockerContainer?

    /// Error message set by `reload`, so it can be cleared after the next successful reload.
    @ObservationIgnored private var reloadErrorMessage: String?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackPollTask: Task<Void, Never>?
    @ObservationIgnored private var pendingReload: Set<String> = []
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var profileRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private var bootstrapped = false
    /// Delay used to coalesce bursts of Docker events into one reload.
    @ObservationIgnored var eventCoalescing: Duration = .milliseconds(300)

    init(settings: AppSettings, services: AppServices = .live) {
        self.settings = settings
        self.services = services
        selectedProfileName = UserDefaults.standard.string(forKey: "selectedProfile") ?? "default"
        scheduler.host = self
        resources.host = self
        proxy.host = self
    }

    // MARK: - Derived

    var colima: any ColimaControlling { services.colima }
    var selectedProfile: ColimaProfile? { profiles.first { $0.name == selectedProfileName } }
    var isRunning: Bool { selectedProfile?.isRunning ?? false }
    var supportsDocker: Bool { (selectedProfile?.runtime ?? "docker") == "docker" }
    var socketPath: String { ColimaService.resolveDockerSocket(selectedProfileName, status: runtimeStatus) }
    /// Docker Engine API of the selected profile (a fake in tests / UI tests).
    var docker: any DockerEngine { services.makeDocker(socketPath) }
    var runningCount: Int { containers.filter(\.isRunning).count }

    func flash(_ message: String) { operations.flash(message) }

    // MARK: - Lifecycle

    func bootstrap() {
        guard !bootstrapped else { return }
        bootstrapped = true
        settings.applyAll()
        scheduler.start()
        resources.start()

        if services.watchesColimaDirectory {
            watcher = DirectoryWatcher { [weak self] in
                Task { @MainActor in self?.scheduleProfileRefresh() }
            }
        }

        Task {
            await setupModel.checkAtLaunch()
            await refreshProfiles()
            await setupModel.checkRuntimesAtLaunch()
            if settings.autoStartVM, !isRunning, selectedProfile != nil {
                runtimeModel.startVM()
            }
        }

        // Fallback for changes the watcher misses (e.g. colima was killed). Long interval to keep overhead low.
        fallbackPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                await self?.refreshProfiles()
            }
        }
    }

    private func scheduleProfileRefresh() {
        profileRefreshTask?.cancel()
        profileRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await refreshProfiles()
        }
    }

    func refreshProfiles() async {
        do {
            let list = try await colima.listProfiles()
            let wasRunning = isRunning
            profiles = list
            profilesLoaded = true
            if selectedProfile == nil, let first = list.first { selectedProfileName = first.name }
            updateWatcher()
            if isRunning != wasRunning || (isRunning && !dockerConnected && eventsTask == nil) {
                handleRunningChanged()
            }
        } catch is CancellationError {
            // The refresh was cancelled (superseded by a newer one); not an error.
            return
        } catch {
            profilesLoaded = true
            operations.errorMessage = error.localizedDescription
        }
    }

    private func updateWatcher() {
        guard let watcher else { return }
        let lima = ColimaService.limaDirectory
        let instances = (try? FileManager.default.contentsOfDirectory(at: lima, includingPropertiesForKeys: nil)) ?? []
        watcher.watch([lima] + instances)
    }

    private func handleRunningChanged() {
        disconnectDocker()
        if isRunning && supportsDocker {
            connectDocker()
        } else {
            clearDockerData()
        }
    }

    func select(_ name: String) {
        guard name != selectedProfileName else { return }
        selectedProfileName = name
        runtimeStatus = nil
        vmUsage = nil
        vmCPUPercent = nil
        handleRunningChanged()
    }

    /// Stops listening for events and background polling (tests).
    func shutdown() {
        disconnectDocker()
        fallbackPollTask?.cancel()
        reloadTask?.cancel()
        profileRefreshTask?.cancel()
    }

    // MARK: - Docker connection & events

    private func connectDocker() {
        eventsTask = Task { [weak self] in
            guard let self else { return }
            await self.resolveEndpoint()
            await self.reloadAll()
            await VolumeBackup.cleanupStaleHelpers(client: self.docker)
            while !Task.isCancelled, self.isRunning {
                do {
                    self.dockerConnected = true
                    for try await event in self.docker.events() {
                        self.handle(event)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.dockerConnected = false
                }
                guard !Task.isCancelled else { return }
                // Stream dropped: the VM may have just stopped. Re-check, then try to reconnect.
                try? await Task.sleep(for: .seconds(3))
                await self.refreshProfiles()
                if self.isRunning { await self.reloadAll() }
            }
        }
    }

    /// Gets the actual Docker endpoint from colima instead of guessing the socket path.
    func resolveEndpoint() async {
        let name = selectedProfileName
        let status = try? await colima.status(name)
        guard name == selectedProfileName else { return }
        runtimeStatus = status
    }

    private func disconnectDocker() {
        eventsTask?.cancel()
        eventsTask = nil
        dockerConnected = false
    }

    private func clearDockerData() {
        runtimeStatus = nil
        containers = []
        images = []
        volumes = []
        networks = []
        volumeUsage = [:]
        imagesModel.reset()
        info = nil
        diskUsage = nil
    }

    func handle(_ event: DockerEvent) {
        pendingReload.insert(event.type)
        if event.type == "container", event.action == "destroy" || event.action.hasPrefix("create") {
            pendingReload.insert("volume")
            pendingReload.insert("network")
        }
        if event.type == "container", event.action == "die" {
            notifyContainerExit(event)
        }
        if event.type == "container", event.action == "start", let name = event.actor?.attributes?["name"] {
            proxy.containerStarted(name)
        }
        // Coalesce bursts of events (compose up/down) into a single reload.
        reloadTask?.cancel()
        let delay = eventCoalescing
        reloadTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let types = pendingReload
            pendingReload.removeAll()
            await reload(types)
        }
    }

    /// Waits for a pending coalesced reload (tests).
    func waitForPendingReload() async {
        await reloadTask?.value
    }

    private func notifyContainerExit(_ event: DockerEvent) {
        guard settings.notifyContainerExit,
              let code = event.actor?.attributes?["exitCode"], code != "0",
              let id = event.actor?.id, !operations.busy.contains(id), !operations.isOperationRunning,
              // Integration-test containers (label dev.colimax.test) are killed on purpose.
              event.actor?.attributes?["dev.colimax.test"] == nil
        else { return }
        let name = event.actor?.attributes?["name"] ?? String(id.prefix(12))
        notify(title: String(localized: "Container exited unexpectedly"), body: String(localized: "\(name) exited with code \(code)"))
    }

    func reloadAll() async {
        await reload(["container", "image", "volume", "network"])
    }

    func reload(_ types: Set<String>) async {
        guard isRunning, supportsDocker else { return }
        let client = docker
        var failure: Error?
        // Each type loads independently: one failing endpoint doesn't block the others.
        do { if types.contains("container") { containers = try await client.containers() } } catch { failure = error }
        do { if types.contains("image") { images = try await client.images() } } catch { failure = error }
        do { if types.contains("volume") { volumes = try await client.volumes() } } catch { failure = error }
        do { if types.contains("network") { networks = try await client.networks() } } catch { failure = error }
        if let failure {
            if !(failure is CancellationError) {
                operations.errorMessage = failure.localizedDescription
                reloadErrorMessage = operations.errorMessage
            }
        } else {
            dockerConnected = true
            // Clear an error left by a previous reload (VM restarting…) once a reload succeeds.
            // Compare with the stored message, not a fixed string: messages are localized.
            if let stale = reloadErrorMessage, operations.errorMessage == stale { operations.errorMessage = nil }
            reloadErrorMessage = nil
        }
    }

    /// Overview data (heavier: /system/df computes volume sizes); call only when needed.
    func refreshOverview() async {
        guard isRunning, supportsDocker else { return }
        let client = docker
        info = try? await client.info()
        if let usage = try? await client.diskUsage() {
            diskUsage = usage
            var map: [String: DockerVolume.UsageData] = [:]
            for volume in usage.volumes ?? [] { if let data = volume.usageData { map[volume.name] = data } }
            volumeUsage = map
        }
    }

    func refreshVMUsage() async {
        guard isRunning else { return }
        do {
            let usage = try await colima.vmUsage(selectedProfileName)
            vmCPUPercent = usage.cpuPercent(since: vmUsage)
            vmUsage = usage
        } catch {
            // colima ssh may not be ready right after start; ignore.
        }
    }
}

// MARK: - Narrow protocol conformances

extension AppStore: DockerContext, ProfileContext {
    var notifyVMChanges: Bool { settings.notifyVMChanges }

    /// Posts a user notification through the injected service (Notification Center in the app).
    func notify(title: String, body: String) {
        services.notify(title, body)
    }
}

extension AppStore: BackupSchedulerHost {
    var runningProfileNames: Set<String> { Set(profiles.filter(\.isRunning).map(\.name)) }

    func docker(forProfile profile: String) -> any DockerEngine {
        services.makeDocker(ColimaService.resolveDockerSocket(profile, status: profile == selectedProfileName ? runtimeStatus : nil))
    }

    var notifyBackupFailure: Bool { settings.notifyBackupFailure }
}

extension AppStore: ResourceWatcherHost {
    var canSampleResources: Bool { settings.backgroundMonitoring && isRunning && supportsDocker }
    var alertThresholds: AlertThresholds { settings.alertThresholds }
    var notifyResourceAlerts: Bool { settings.notifyResourceAlerts }
}

extension AppStore: ProxyHost {}
