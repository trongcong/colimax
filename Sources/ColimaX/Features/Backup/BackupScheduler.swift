import Foundation
import Observation

/// Runs backup schedules (G19) from an in-app timer. Checks every minute and runs one backup at a time.
/// Schedules whose profile is not running stay due and run once the VM is up.
@MainActor
@Observable
final class BackupScheduler {
    private static let defaultsKey = "backupSchedules"

    var schedules: [BackupSchedule] {
        didSet { persist() }
    }
    private(set) var runningID: UUID?

    @ObservationIgnored weak var host: (any BackupSchedulerHost)?
    @ObservationIgnored private var timer: Task<Void, Never>?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([BackupSchedule].self, from: data) {
            schedules = saved
        } else {
            schedules = []
        }
    }

    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            // Give the app time to connect to Docker before catching up on missed runs.
            try? await Task.sleep(for: .seconds(20))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(schedules) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    func add(_ schedule: BackupSchedule) {
        guard schedule.isValid else { return }
        schedules.append(schedule)
    }

    func update(_ schedule: BackupSchedule) {
        guard schedule.isValid, let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        schedules[index] = schedule
    }

    func remove(_ id: UUID) {
        schedules.removeAll { $0.id == id }
    }

    /// Runs a schedule immediately ("Run now" button) regardless of when it is due.
    func runNow(_ id: UUID) {
        guard runningID == nil else { return }
        Task { await run(id) }
    }

    func tick() async {
        guard runningID == nil, let host else { return }
        let now = Date()
        let running = host.runningProfileNames
        for schedule in schedules where schedule.isDue(at: now) && running.contains(schedule.profile) {
            await run(schedule.id)
        }
    }


    private func run(_ id: UUID) async {
        guard runningID == nil, let schedule = schedules.first(where: { $0.id == id }) else { return }
        runningID = id
        defer { runningID = nil }
        let client = host?.docker(forProfile: schedule.profile)
            ?? DockerClient(socketPath: ColimaService.resolveDockerSocket(schedule.profile, status: nil))
        let started = Date()
        var result: String?
        do {
            try await ScheduledBackupRunner.run(schedule, client: client, at: started)
        } catch is CancellationError {
            result = String(localized: "Cancelled")
        } catch {
            result = error.localizedDescription
        }
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return }
        schedules[index].lastRun = started
        schedules[index].lastError = result
        if result == nil {
            schedules[index].lastSuccess = started
        } else if host?.notifyBackupFailure ?? true {
            host?.notify(title: String(localized: "Scheduled backup failed"), body: "\(schedule.target.title): \(result ?? "")")
        }
    }
}
