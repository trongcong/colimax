import Charts
import SwiftUI

struct MonitoringView: View {
    @Environment(AppStore.self) private var store
    @State private var monitor = MonitorStore()
    @State private var showHistory = false

    private var running: [DockerContainer] { store.containers.filter(\.isRunning) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                chartCard("Total CPU", value: Format.percent(monitor.totalCPU)) {
                    Chart(monitor.totalHistory) {
                        AreaMark(x: .value("t", $0.date), y: .value("CPU", $0.cpu))
                            .foregroundStyle(.blue.opacity(0.25))
                        LineMark(x: .value("t", $0.date), y: .value("CPU", $0.cpu))
                            .foregroundStyle(.blue)
                    }
                    .chartYAxisLabel("%")
                }
                chartCard("Total RAM", value: Format.bytes(monitor.totalMemory)) {
                    Chart(monitor.totalHistory) {
                        AreaMark(x: .value("t", $0.date), y: .value("RAM", Double($0.memory) / 1_048_576))
                            .foregroundStyle(.purple.opacity(0.25))
                        LineMark(x: .value("t", $0.date), y: .value("RAM", Double($0.memory) / 1_048_576))
                            .foregroundStyle(.purple)
                    }
                    .chartYAxisLabel("MB")
                }
            }
            .padding(16)

            Divider()

            if running.isEmpty {
                ContentUnavailableView("No running containers", systemImage: "chart.xyaxis.line").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(running) {
                    TableColumn("Container") { container in
                        HStack(spacing: 6) {
                            StatusDot(color: container.stateColor)
                            Text(container.name)
                        }
                    }
                    .width(min: 140, ideal: 180)
                    TableColumn("CPU") { container in
                        Text(monitor.stats[container.id].map { Format.percent($0.cpu) } ?? "…").monospacedDigit()
                    }
                    .width(min: 60, ideal: 70)
                    TableColumn("CPU trend") { container in
                        Sparkline(samples: monitor.stats[container.id]?.history ?? [])
                    }
                    .width(min: 100, ideal: 140)
                    TableColumn("RAM") { container in
                        if let stats = monitor.stats[container.id] {
                            Text("\(Format.bytes(stats.memory)) / \(Format.bytes(stats.memoryLimit))").monospacedDigit()
                        } else {
                            Text("…")
                        }
                    }
                    .width(min: 120, ideal: 160)
                    TableColumn("Net I/O") { container in
                        Text(monitor.stats[container.id].map { "↓\(Format.bytes($0.netRx)) ↑\(Format.bytes($0.netTx))" } ?? "…")
                            .monospacedDigit()
                    }
                    .width(min: 120, ideal: 150)
                    TableColumn("Block I/O") { container in
                        Text(monitor.stats[container.id].map { "R \(Format.bytes($0.blockRead)) W \(Format.bytes($0.blockWrite))" } ?? "…")
                            .monospacedDigit()
                    }
                    .width(min: 120, ideal: 150)
                }
            }
        }
        // Open stats streams for running containers; re-sync whenever that set changes.
        .task(id: running.map(\.id).joined()) {
            monitor.sync(containers: store.containers, client: store.docker)
        }
        .onDisappear { monitor.stopAll() }
        .toolbar {
            ToolbarItem {
                Button {
                    showHistory = true
                } label: {
                    Label("History & Alerts", systemImage: store.resources.recentAlerts.isEmpty ? "bell" : "bell.badge")
                }
                .help("Recorded resource history and threshold alerts")
            }
        }
        .sheet(isPresented: $showHistory) { MetricsHistorySheet() }
    }

    private func chartCard<C: View>(_ title: LocalizedStringKey, value: String, @ViewBuilder chart: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
            }
            chart().frame(height: 140)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct Sparkline: View {
    let samples: [StatSample]

    var body: some View {
        Chart(samples) {
            LineMark(x: .value("t", $0.date), y: .value("CPU", $0.cpu))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max(5, samples.map(\.cpu).max() ?? 5))
        .frame(height: 22)
    }
}

/// Stored resource history (sampled in the background every minute) and threshold alerts (G20).
private struct MetricsHistorySheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    enum Range: Int, CaseIterable, Identifiable {
        case hour = 1, sixHours = 6, day = 24, threeDays = 72
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .hour: String(localized: "1 h")
            case .sixHours: String(localized: "6 h")
            case .day: String(localized: "24 h")
            case .threeDays: String(localized: "3 days")
            }
        }
    }

    @State private var range = Range.sixHours
    @State private var container = ""
    @State private var samples: [ResourceSample] = []
    @State private var loading = true

    private var containerNames: [String] { Array(Set(samples.map(\.container))).sorted() }
    private var shown: [ResourceSample] { samples.filter { $0.container == container } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Resource History").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                Picker("Container", selection: $container) {
                    ForEach(containerNames, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 220)
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(12)
            Divider()
            if !store.settings.backgroundMonitoring {
                Banner(kind: .info, message: String(localized: "Background monitoring is off. Turn it on in Settings to record history and get alerts."))
                    .padding(12)
            }
            HStack(alignment: .top, spacing: 16) {
                VStack(spacing: 12) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if shown.isEmpty {
                        SheetMessage(title: String(localized: "No recorded samples"), systemImage: "chart.xyaxis.line",
                                     message: String(localized: "Samples are taken every minute while ColimaX runs."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        historyChart(String(localized: "CPU (% of VM)"), threshold: store.settings.alertThresholds.cpuPercent) { $0.cpu }
                        historyChart(String(localized: "Memory (% of limit)"), threshold: store.settings.alertThresholds.memoryPercent) { $0.memoryPercent ?? 0 }
                    }
                }
                .frame(maxWidth: .infinity)
                alertsList.frame(width: 300)
            }
            .padding(16)
        }
        .frame(minWidth: 900, idealWidth: 940, maxWidth: .infinity, minHeight: 560, idealHeight: 600, maxHeight: .infinity)
        .task(id: range) { await load() }
    }

    private func load() async {
        loading = true
        samples = await store.resources.history(since: Date().addingTimeInterval(-Double(range.rawValue) * 3600))
        if !containerNames.contains(container) { container = containerNames.first ?? "" }
        loading = false
    }

    private func historyChart(_ title: String, threshold: Double, value: @escaping (ResourceSample) -> Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.medium))
            Chart {
                ForEach(shown, id: \.date) { sample in
                    LineMark(x: .value("t", sample.date), y: .value(title, value(sample)))
                        .interpolationMethod(.monotone)
                }
                RuleMark(y: .value("Threshold", threshold))
                    .foregroundStyle(.red.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .chartYScale(domain: 0...max(100, shown.map(value).max() ?? 100))
            .frame(minHeight: 160)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var alertsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Alerts (this session)").font(.subheadline.weight(.medium))
                Spacer()
                Button("Clear") { store.resources.clearAlerts() }
                    .disabled(store.resources.recentAlerts.isEmpty)
            }
            if store.resources.recentAlerts.isEmpty {
                Text("No alerts").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.resources.recentAlerts) { alert in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.message).font(.callout)
                        Text(Format.relative(alert.date)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
    }
}
