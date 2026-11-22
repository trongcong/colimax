import Foundation
import Observation

struct StatSample: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let cpu: Double
    let memory: Int64
}

struct ContainerLiveStats: Sendable {
    var cpu: Double = 0
    var memory: Int64 = 0
    var memoryLimit: Int64 = 0
    var netRx: Int64 = 0
    var netTx: Int64 = 0
    var blockRead: Int64 = 0
    var blockWrite: Int64 = 0
    var history: [StatSample] = []
}

/// Streams `/containers/{id}/stats` for every running container, only while the Monitoring screen is open.
@MainActor
@Observable
final class MonitorStore {
    static let historyLength = 90

    var stats: [String: ContainerLiveStats] = [:]
    var totalHistory: [StatSample] = []

    private var tasks: [String: Task<Void, Never>] = [:]
    private var aggregateTask: Task<Void, Never>?

    var totalCPU: Double { stats.values.reduce(0) { $0 + $1.cpu } }
    var totalMemory: Int64 { stats.values.reduce(0) { $0 + $1.memory } }

    /// Reconciles the open streams with the currently running containers.
    func sync(containers: [DockerContainer], client: any DockerEngine) {
        let running = Set(containers.filter(\.isRunning).map(\.id))
        for (id, task) in tasks where !running.contains(id) {
            task.cancel()
            tasks[id] = nil
            stats[id] = nil
        }
        for id in running where tasks[id] == nil {
            tasks[id] = Task { [weak self] in
                do {
                    for try await sample in client.statsStream(id) {
                        self?.record(id, sample)
                    }
                } catch {}
            }
        }
        if aggregateTask == nil {
            aggregateTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.recordTotal()
                }
            }
        }
    }

    func stopAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        aggregateTask?.cancel()
        aggregateTask = nil
        stats.removeAll()
        totalHistory.removeAll()
    }

    private func record(_ id: String, _ sample: ContainerStats) {
        var entry = stats[id] ?? ContainerLiveStats()
        entry.cpu = sample.cpuPercent
        entry.memory = sample.memoryUsed
        entry.memoryLimit = sample.memoryLimit
        entry.netRx = sample.networkRx
        entry.netTx = sample.networkTx
        entry.blockRead = sample.blockRead
        entry.blockWrite = sample.blockWrite
        entry.history.append(StatSample(date: .now, cpu: entry.cpu, memory: entry.memory))
        if entry.history.count > Self.historyLength { entry.history.removeFirst(entry.history.count - Self.historyLength) }
        stats[id] = entry
    }

    private func recordTotal() {
        guard !stats.isEmpty else { return }
        totalHistory.append(StatSample(date: .now, cpu: totalCPU, memory: totalMemory))
        if totalHistory.count > Self.historyLength { totalHistory.removeFirst(totalHistory.count - Self.historyLength) }
    }
}
