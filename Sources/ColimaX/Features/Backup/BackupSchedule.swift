import Foundation

/// A recurring backup schedule (G19). Driven by an in-app timer (`BackupScheduler`); runs missed
/// while the app was closed are caught up on the first check after launch.
struct BackupSchedule: Codable, Identifiable, Hashable, Sendable {
    enum Target: Codable, Hashable, Sendable {
        case volume(name: String)
        /// The container is identified by **name**, because its ID changes when compose recreates it.
        case database(container: String, engine: String)

        var source: String {
            switch self {
            case .volume(let name): name
            case .database(let container, _): container
            }
        }

        var engine: DatabaseEngine? {
            if case .database(_, let raw) = self { return DatabaseEngine(rawValue: raw) }
            return nil
        }

        var fileExtension: String { engine?.fileExtension ?? "tar" }

        var manifestKind: BackupManifest.Kind { engine?.manifestKind ?? .volume }

        var title: String {
            switch self {
            case .volume(let name): String(localized: "Volume \(name)")
            case .database(let container, _): "\(engine?.title ?? String(localized: "Database")) \(container)"
            }
        }
    }

    enum Interval: Int, Codable, CaseIterable, Identifiable, Sendable {
        case hourly = 1, every6Hours = 6, every12Hours = 12, daily = 24, weekly = 168
        var id: Int { rawValue }
        var seconds: TimeInterval { TimeInterval(rawValue) * 3600 }
        var title: String {
            switch self {
            case .hourly: String(localized: "Every hour")
            case .every6Hours: String(localized: "Every 6 hours")
            case .every12Hours: String(localized: "Every 12 hours")
            case .daily: String(localized: "Daily")
            case .weekly: String(localized: "Weekly")
            }
        }
    }

    var id = UUID()
    var profile: String
    var target: Target
    var interval: Interval
    var directory: String
    /// Number of backups to keep (>= 1). Older ones are deleted after each successful backup.
    var keep: Int
    var enabled = true
    var lastRun: Date?
    var lastSuccess: Date?
    var lastError: String?

    static let minKeep = 1
    static let maxKeep = 365

    /// A failed run (VM not ready, container not up, ...) is retried after at most 15 minutes.
    static let retryDelay: TimeInterval = 15 * 60

    private var currentDelay: TimeInterval {
        lastError == nil ? interval.seconds : min(interval.seconds, Self.retryDelay)
    }

    func isDue(at now: Date) -> Bool {
        guard enabled else { return false }
        guard let lastRun else { return true }
        return now.timeIntervalSince(lastRun) >= currentDelay
    }

    func nextRun(after now: Date) -> Date {
        guard let lastRun else { return now }
        return max(now, lastRun.addingTimeInterval(currentDelay))
    }

    /// `<source>-YYYYMMDD-HHMMSS.<ext>` in UTC: sortable and unambiguous across time zones.
    func fileName(at date: Date) -> String {
        "\(target.source)-\(Self.stamp(date)).\(target.fileExtension)"
    }

    static func stamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02d-%02d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    /// Whether `name` was produced by this schedule. Retention uses it so other files in the directory are never touched.
    func ownsFileName(_ name: String) -> Bool {
        let prefix = target.source + "-"
        let suffix = "." + target.fileExtension
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        let middle = name.dropFirst(prefix.count).dropLast(suffix.count)
        return middle.range(of: #"^\d{8}-\d{6}$"#, options: .regularExpression) != nil
    }

    var isValid: Bool {
        let nameOK = target.source.range(of: #"^[a-zA-Z0-9][a-zA-Z0-9_.-]*$"#, options: .regularExpression) != nil
        let engineOK = { if case .database = target { return target.engine != nil } else { return true } }()
        return nameOK && engineOK && directory.hasPrefix("/") && (Self.minKeep...Self.maxKeep).contains(keep)
            && ColimaService.isValidProfileName(profile)
    }
}

/// Selects old backups to delete. Only considers files created by the schedule (matching name pattern)
/// **and** with a manifest matching its source and kind; other files in the directory are never touched.
enum BackupRetention {
    struct Entry: Equatable, Sendable {
        let file: URL
        let manifest: BackupManifest
    }

    static func entries(in directory: URL, for schedule: BackupSchedule) -> [Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(schedule.ownsFileName).compactMap { name in
            let file = directory.appendingPathComponent(name)
            guard let manifest = try? BackupManifest.read(for: file) else { return nil }
            return Entry(file: file, manifest: manifest)
        }
    }

    static func expired(_ entries: [Entry], schedule: BackupSchedule) -> [Entry] {
        let matching = entries
            .filter { $0.manifest.source == schedule.target.source && $0.manifest.kind == schedule.target.manifestKind }
            .filter { schedule.ownsFileName($0.file.lastPathComponent) && $0.manifest.fileName == $0.file.lastPathComponent }
            // Tie-break on the file name (which embeds the run timestamp), since manifests store seconds only.
            .sorted { ($0.manifest.createdAt, $0.file.lastPathComponent) > ($1.manifest.createdAt, $1.file.lastPathComponent) }
        return Array(matching.dropFirst(max(BackupSchedule.minKeep, schedule.keep)))
    }

    /// Deletes expired backups and their manifests. Returns the number of backups deleted.
    @discardableResult
    static func apply(in directory: URL, schedule: BackupSchedule) -> Int {
        var removed = 0
        for entry in expired(entries(in: directory, for: schedule), schedule: schedule) {
            do {
                try FileManager.default.removeItem(at: entry.file)
                try? FileManager.default.removeItem(at: BackupManifest.url(for: entry.file))
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }
}

/// Core of a single scheduled run: back up to `<directory>/<fileName(at:)>`, then apply retention.
/// Kept separate from `BackupScheduler` (MainActor, UserDefaults, notifications) so it can be tested against real Docker.
enum ScheduledBackupRunner {
    @discardableResult
    static func run(_ schedule: BackupSchedule, client: any DockerEngine, at date: Date) async throws -> URL {
        let directory = URL(fileURLWithPath: schedule.directory, isDirectory: true)
        let file = directory.appendingPathComponent(schedule.fileName(at: date))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch schedule.target {
        case .volume(let name):
            try await VolumeBackup.backup(volume: name, to: file, client: client)
        case .database(let name, _):
            guard let engine = schedule.target.engine else { throw BackupError.integrity(String(localized: "unknown engine")) }
            let containers = try await client.containers()
            guard let container = containers.first(where: { $0.name == name }) else {
                throw BackupError.containerNotRunning(name)
            }
            try await DatabaseBackup.backup(container: container, engine: engine, to: file, client: client)
        }
        BackupRetention.apply(in: directory, schedule: schedule)
        return file
    }
}
