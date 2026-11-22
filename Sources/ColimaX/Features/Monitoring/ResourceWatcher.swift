import Foundation
import Observation

/// Samples resources in the background every minute (even when the Monitoring screen is closed),
/// stores the history on disk, and alerts on sustained threshold breaches (G20). Only active when
/// "Background monitoring" is enabled.
@MainActor
@Observable
final class ResourceWatcher {
    static let interval: Duration = .seconds(60)
    static let maxRecentAlerts = 50

    private(set) var recentAlerts: [ResourceAlert] = []
    private(set) var lastSample: Date?

    @ObservationIgnored weak var host: (any ResourceWatcherHost)?
    /// Where the per-profile history files live (Application Support; tests use a temporary directory).
    @ObservationIgnored var historyDirectory = MetricsHistory.directory()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var evaluator = AlertEvaluator()
    @ObservationIgnored private var window: [String: [ResourceSample]] = [:]
    @ObservationIgnored private var profile: String?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastPrune: Date?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: Self.interval)
            }
        }
    }

    func clearAlerts() { recentAlerts.removeAll() }

    func history(since: Date) async -> [ResourceSample] {
        guard let host else { return [] }
        let history = MetricsHistory.forProfile(host.selectedProfileName, in: historyDirectory)
        return (try? await BlockingIO.run { history.load(since: since) }) ?? []
    }

    func tick() async {
        guard let host, host.canSampleResources else { return }
        let name = host.selectedProfileName
        if profile != name {
            profile = name
            window = [:]
            evaluator = AlertEvaluator()
        }
        let client = host.docker
        let running = host.containers.filter(\.isRunning)
        let samples = await Self.collect(running, client: client)
        guard host.selectedProfileName == name else { return }
        lastSample = .now

        let history = MetricsHistory.forProfile(name, in: historyDirectory)
        let prune = lastPrune.map { Date().timeIntervalSince($0) > 3600 } ?? true
        if prune { lastPrune = .now }
        _ = try? await BlockingIO.run {
            try history.append(samples)
            if prune { try history.prune() }
        }

        let alive = Set(samples.map(\.container))
        window = window.filter { alive.contains($0.key) }
        for sample in samples {
            window[sample.container, default: []].append(sample)
            if window[sample.container]!.count > 10 { window[sample.container]!.removeFirst() }
        }
        let thresholds = host.alertThresholds
        var fired = evaluator.evaluate(window, thresholds: thresholds)

        // VM disk changes slowly and requires `colima ssh`, so only measure it every 10 ticks (~10 minutes).
        ticks += 1
        if ticks % 10 == 1, let usage = try? await host.colima.vmUsage(name), usage.diskTotal > 0 {
            let percent = Double(usage.diskUsed) / Double(usage.diskTotal) * 100
            if let alert = evaluator.evaluateDisk(profile: name, percent: percent, threshold: thresholds.diskPercent) {
                fired.append(alert)
            }
        }
        guard !fired.isEmpty else { return }
        recentAlerts.insert(contentsOf: fired, at: 0)
        if recentAlerts.count > Self.maxRecentAlerts { recentAlerts.removeLast(recentAlerts.count - Self.maxRecentAlerts) }
        if host.notifyResourceAlerts {
            for alert in fired { host.notify(title: String(localized: "Resource alert"), body: alert.message) }
        }
    }

    /// One-shot stats for each container, at most 6 requests in flight.
    private static func collect(_ containers: [DockerContainer], client: any DockerEngine) async -> [ResourceSample] {
        await withTaskGroup(of: ResourceSample?.self) { group in
            var iterator = containers.makeIterator()
            func next() -> Bool {
                guard let container = iterator.next() else { return false }
                group.addTask {
                    guard let stats = try? await client.stats(container.id) else { return nil }
                    return ResourceSample(date: .now, container: container.name, cpu: stats.cpuPercentOfVM,
                                          memory: stats.memoryUsed, memoryLimit: stats.memoryLimit)
                }
                return true
            }
            for _ in 0..<6 where next() {}
            var result: [ResourceSample] = []
            while let sample = await group.next() {
                if let sample { result.append(sample) }
                _ = next()
            }
            return result
        }
    }
}
