import SwiftUI

/// Network topology and compose dependency graph (G22). Read-only.
struct TopologyView: View {
    @Environment(AppStore.self) private var store

    enum Mode: String, CaseIterable, Identifiable {
        case networks = "Networks", compose = "Compose dependencies"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .networks: String(localized: "Networks")
            case .compose: String(localized: "Compose dependencies")
            }
        }
    }

    @State private var mode = Mode.networks
    @State private var includeStopped = false
    @State private var project = ""
    @State private var graph: ComposeDependencyGraph?
    @State private var error: String?
    @State private var highlighted: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
                Spacer()
                switch mode {
                case .networks:
                    Toggle("Include stopped containers", isOn: $includeStopped)
                case .compose:
                    Picker("Project", selection: $project) {
                        ForEach(store.composeModel.projects.filter(\.canRunUp)) { Text($0.name).tag($0.name) }
                    }
                    .frame(width: 260)
                }
            }
            .padding(12)
            Divider()
            switch mode {
            case .networks: networkGraph.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .compose: composeGraph.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: "\(mode.rawValue)|\(project)") { await loadCompose() }
    }

    // MARK: Networks

    private var topology: NetworkTopology {
        NetworkTopology.build(containers: store.containers, networks: store.networks, includeStopped: includeStopped)
    }

    @ViewBuilder
    private var networkGraph: some View {
        let topology = topology
        if topology.containers.isEmpty {
            ContentUnavailableView("No containers", systemImage: "point.3.connected.trianglepath.dotted")
        } else {
            ScrollView {
                let rowHeight: CGFloat = 34
                let height = CGFloat(max(topology.networks.count, topology.containers.count)) * rowHeight + 24
                GeometryReader { geometry in
                    let leftX = geometry.size.width * 0.22
                    let rightX = geometry.size.width * 0.70
                    let netY = Dictionary(uniqueKeysWithValues: topology.networks.enumerated().map { ($1, CGFloat($0) * rowHeight + 24) })
                    let conY = Dictionary(uniqueKeysWithValues: topology.containers.enumerated().map { ($1.id, CGFloat($0) * rowHeight + 24) })
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for edge in topology.edges {
                                guard let y1 = netY[edge.network], let y2 = conY[edge.container] else { continue }
                                let active = highlighted == nil || highlighted == edge.network || highlighted == edge.container
                                var path = Path()
                                path.move(to: CGPoint(x: leftX + 90, y: y1))
                                path.addCurve(to: CGPoint(x: rightX - 100, y: y2),
                                              control1: CGPoint(x: (leftX + rightX) / 2, y: y1),
                                              control2: CGPoint(x: (leftX + rightX) / 2, y: y2))
                                context.stroke(path, with: .color(active ? .accentColor : .secondary.opacity(0.25)), lineWidth: active ? 1.6 : 1)
                            }
                        }
                        ForEach(topology.networks, id: \.self) { name in
                            node(name, icon: "network", tint: .blue, key: name)
                                .position(x: leftX, y: netY[name] ?? 0)
                        }
                        ForEach(topology.containers, id: \.id) { container in
                            node(container.name, icon: "shippingbox", tint: container.running ? .green : .gray, key: container.id,
                                 caption: container.group)
                                .position(x: rightX, y: conY[container.id] ?? 0)
                        }
                    }
                }
                .frame(height: height)
            }
        }
    }

    private func node(_ title: String, icon: String, tint: Color, key: String, caption: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).lineLimit(1)
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
        }
        .font(.callout)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(width: 190, alignment: .leading)
        .background(highlighted == key ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .onHover { highlighted = $0 ? key : (highlighted == key ? nil : highlighted) }
        .help(title)
    }

    // MARK: Compose

    private func loadCompose() async {
        guard mode == .compose else { return }
        if project.isEmpty, let first = store.composeModel.projects.first(where: \.canRunUp)?.name {
            // Changing the project changes the `.task` id, so SwiftUI cancels this task and starts a new one that loads it.
            project = first
            return
        }
        guard let selected = store.composeModel.projects.first(where: { $0.name == project }) else { graph = nil; return }
        error = nil
        do {
            let result = try await ComposeService.dependencyGraph(project: selected, socketPath: store.socketPath)
            guard !Task.isCancelled else { return }
            graph = result
        } catch {
            // Cancelled (mode / project changed): the new task loads on its own, so don't report an error.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            graph = nil
            self.error = error.localizedDescription
        }
    }

    @ViewBuilder
    private var composeGraph: some View {
        if !ComposeService.isAvailable {
            ContentUnavailableView("docker CLI not found", systemImage: "terminal", description: Text("Compose dependencies need docker compose."))
        } else if let error {
            ContentUnavailableView("Cannot read compose config", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if let graph {
            let levels = graph.levels()
            let depth = (levels.values.max() ?? 0) + 1
            let rows = (0..<depth).map { level in graph.services.filter { levels[$0] == level } }
            let running = Set(store.composeModel.containers(in: project).filter(\.isRunning).compactMap(\.composeService))
            VStack(alignment: .leading, spacing: 8) {
                if graph.hasCycle {
                    Banner(kind: .error, message: String(localized: "depends_on contains a cycle; docker compose will refuse to start this project."))
                }
                Text("Top row starts first. Arrows point from a service to what it depends on.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView([.horizontal, .vertical]) {
                    let columnWidth: CGFloat = 200
                    let rowHeight: CGFloat = 90
                    let width = CGFloat(max(1, rows.map(\.count).max() ?? 1)) * columnWidth
                    let positions = Dictionary(uniqueKeysWithValues: rows.enumerated().flatMap { level, services in
                        services.enumerated().map { index, name in
                            (name, CGPoint(x: CGFloat(index) * columnWidth + columnWidth / 2, y: CGFloat(level) * rowHeight + 30))
                        }
                    })
                    ZStack(alignment: .topLeading) {
                        Canvas { context, _ in
                            for (service, deps) in graph.dependencies {
                                guard let from = positions[service] else { continue }
                                for dep in deps {
                                    guard let to = positions[dep] else { continue }
                                    var path = Path()
                                    path.move(to: CGPoint(x: from.x, y: from.y - 16))
                                    path.addLine(to: CGPoint(x: to.x, y: to.y + 16))
                                    context.stroke(path, with: .color(.secondary), lineWidth: 1.2)
                                    let angle = atan2(from.y - 16 - (to.y + 16), from.x - to.x)
                                    let tip = CGPoint(x: to.x, y: to.y + 16)
                                    var head = Path()
                                    head.move(to: tip)
                                    head.addLine(to: CGPoint(x: tip.x + 8 * cos(angle + 0.4), y: tip.y + 8 * sin(angle + 0.4)))
                                    head.move(to: tip)
                                    head.addLine(to: CGPoint(x: tip.x + 8 * cos(angle - 0.4), y: tip.y + 8 * sin(angle - 0.4)))
                                    context.stroke(head, with: .color(.secondary), lineWidth: 1.2)
                                }
                            }
                        }
                        ForEach(graph.services, id: \.self) { service in
                            HStack(spacing: 6) {
                                StatusDot(color: running.contains(service) ? .green : .gray)
                                Text(service).lineLimit(1)
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .frame(width: 170)
                            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .position(positions[service] ?? .zero)
                        }
                    }
                    .frame(width: width, height: CGFloat(depth) * rowHeight + 20)
                }
            }
            .padding(12)
        } else if store.composeModel.projects.filter(\.canRunUp).isEmpty {
            ContentUnavailableView("No compose projects with files", systemImage: "square.stack.3d.up",
                                   description: Text("Add a project folder in Compose to see its dependencies."))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
