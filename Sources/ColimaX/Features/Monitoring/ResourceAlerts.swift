import Foundation

/// One container resource sample (taken in the background every minute, G20).
struct ResourceSample: Codable, Equatable, Sendable {
    let date: Date
    let container: String
    /// CPU % of the whole VM (0-100), unlike `docker stats` where 100% = one core.
    let cpu: Double
    let memory: Int64
    let memoryLimit: Int64

    var memoryPercent: Double? {
        memoryLimit > 0 ? Double(memory) / Double(memoryLimit) * 100 : nil
    }
}

extension ContainerStats {
    var cpuPercentOfVM: Double {
        cpuPercent / Double(max(1, cpu_stats.online_cpus ?? 1))
    }
}

struct AlertThresholds: Equatable, Sendable {
    var cpuPercent: Double
    var memoryPercent: Double
    var diskPercent: Double
    /// Consecutive samples over the threshold before alerting (1-minute samples, so 3 = 3 minutes).
    var sustainSamples: Int

    static let `default` = AlertThresholds(cpuPercent: 80, memoryPercent: 90, diskPercent: 85, sustainSamples: 3)
}

struct ResourceAlert: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case cpu, memory, disk }
    var id: String { "\(subject)|\(kind.rawValue)|\(date.timeIntervalSince1970)" }
    let subject: String
    let kind: Kind
    let value: Double
    let threshold: Double
    let date: Date

    var message: String {
        switch kind {
        case .cpu: String(localized: "\(subject): CPU \(Format.percent(value)) of VM (threshold \(Format.percent(threshold)))")
        case .memory: String(localized: "\(subject): memory \(Format.percent(value)) of limit (threshold \(Format.percent(threshold)))")
        case .disk: String(localized: "VM \(subject): disk \(Format.percent(value)) used (threshold \(Format.percent(threshold)))")
        }
    }
}

/// Detects sustained threshold breaches. Each alert fires **once** and re-arms only after the value
/// drops below 90% of the threshold (hysteresis), to avoid spamming when it hovers around the threshold.
struct AlertEvaluator: Sendable {
    private(set) var firing: Set<String> = []

    static func key(_ subject: String, _ kind: ResourceAlert.Kind) -> String { "\(subject)|\(kind.rawValue)" }

    /// `history`: samples per container, oldest first.
    mutating func evaluate(_ history: [String: [ResourceSample]], thresholds: AlertThresholds) -> [ResourceAlert] {
        var fired: [ResourceAlert] = []
        for (container, samples) in history {
            fired += check(container, .cpu, values: samples.map(\.cpu), dates: samples.map(\.date), threshold: thresholds.cpuPercent, sustain: thresholds.sustainSamples)
            let memory = samples.compactMap { sample in sample.memoryPercent.map { ($0, sample.date) } }
            fired += check(container, .memory, values: memory.map(\.0), dates: memory.map(\.1), threshold: thresholds.memoryPercent, sustain: thresholds.sustainSamples)
        }
        // Drop state for containers that are gone (disk alerts are kept).
        let alive = Set(history.keys)
        firing = firing.filter { key in
            let subject = String(key.split(separator: "|").first ?? "")
            return alive.contains(subject) || key.hasSuffix("|disk")
        }
        return fired.sorted { $0.subject < $1.subject }
    }

    /// VM disk: a single sample is enough since it changes slowly.
    mutating func evaluateDisk(profile: String, percent: Double, threshold: Double, date: Date = .now) -> ResourceAlert? {
        check(profile, .disk, values: [percent], dates: [date], threshold: threshold, sustain: 1).first
    }

    private mutating func check(_ subject: String, _ kind: ResourceAlert.Kind, values: [Double], dates: [Date], threshold: Double, sustain: Int) -> [ResourceAlert] {
        let key = Self.key(subject, kind)
        guard threshold > 0, let last = values.last, let date = dates.last else { return [] }
        if firing.contains(key) {
            if last < threshold * 0.9 { firing.remove(key) }
            return []
        }
        let window = values.suffix(max(1, sustain))
        guard window.count >= max(1, sustain), window.allSatisfy({ $0 >= threshold }) else { return [] }
        firing.insert(key)
        return [ResourceAlert(subject: subject, kind: kind, value: last, threshold: threshold, date: date)]
    }
}

/// Sample history on disk: one JSON Lines file per profile in
/// `~/Library/Application Support/ColimaX/metrics/`. `prune` drops samples older than `retention`.
struct MetricsHistory: Sendable {
    let file: URL
    var retention: TimeInterval = 3 * 24 * 3600

    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ColimaX/metrics", isDirectory: true)
    }

    static func forProfile(_ profile: String, in directory: URL = directory()) -> MetricsHistory {
        MetricsHistory(file: directory.appendingPathComponent("\(profile).jsonl"))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    func append(_ samples: [ResourceSample]) throws {
        guard !samples.isEmpty else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for sample in samples {
            data.append(try Self.encoder.encode(sample))
            data.append(0x0A)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            try AtomicFile.write(data, to: file)
            return
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func load(since: Date) -> [ResourceSample] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard let sample = try? Self.decoder.decode(ResourceSample.self, from: Data(line)) else { return nil }
            return sample.date >= since ? sample : nil
        }
    }

    /// Rewrites the file with only the samples still within `retention`.
    func prune(now: Date = .now) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let kept = load(since: now.addingTimeInterval(-retention))
        var data = Data()
        for sample in kept {
            data.append(try Self.encoder.encode(sample))
            data.append(0x0A)
        }
        try AtomicFile.write(data, to: file)
    }
}
