import Foundation
import Observation

/// State and actions for the local-domain reverse proxy (G23).
@MainActor
@Observable
final class ProxyStore {
    var routes: [ProxyRoute] {
        didSet { save(routes, key: "proxyRoutes") }
    }
    var settings: ProxySettings {
        didSet { save(settings, key: "proxySettings") }
    }
    private(set) var status: LocalProxy.Status?
    private(set) var skipped: [String] = []
    private(set) var busy = false
    var error: String?

    @ObservationIgnored weak var host: (any ProxyHost)?
    @ObservationIgnored private var pendingApply: Task<Void, Never>?

    init() {
        routes = Self.load([ProxyRoute].self, key: "proxyRoutes") ?? []
        settings = Self.load(ProxySettings.self, key: "proxySettings") ?? ProxySettings()
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    var isRunning: Bool { status?.running == true }

    private var client: (any DockerEngine)? { host?.docker }

    private func run(_ work: @escaping @MainActor (any DockerEngine) async throws -> Void) async {
        guard let client, !busy else { return }
        busy = true
        error = nil
        do { try await work(client) } catch { self.error = error.localizedDescription }
        busy = false
    }

    func refresh() async {
        guard let client else { return }
        status = try? await LocalProxy.status(client: client)
    }

    func start() async {
        await run { client in
            var current = try await LocalProxy.status(client: client)
            if !current.exists {
                for port in [self.settings.httpPort, self.settings.httpsPort] where PortProbe.isInUse(port) {
                    throw LocalProxy.ProxyError.invalid(String(localized: "Port \(Format.digits(port)) on this Mac is already in use. Choose other ports."))
                }
                _ = try await LocalProxy.create(settings: self.settings, client: client)
            } else if !current.running, let id = current.id {
                try await client.containerAction(id, "start")
            }
            current = try await LocalProxy.status(client: client)
            self.status = current
            if let id = current.id {
                self.skipped = try await LocalProxy.apply(routes: self.routes, settings: self.settings, proxyID: id, client: client)
            }
        }
    }

    func stop() async {
        await run { client in
            if let id = try await LocalProxy.status(client: client).id { try await client.containerAction(id, "stop") }
            self.status = try await LocalProxy.status(client: client)
        }
    }

    /// Removes the proxy container. The CA volume is kept.
    func remove() async {
        await run { client in
            try await LocalProxy.remove(client: client)
            self.status = try await LocalProxy.status(client: client)
        }
    }

    func apply() async {
        await run { client in
            let current = try await LocalProxy.status(client: client)
            self.status = current
            guard current.running, let id = current.id else { return }
            self.skipped = try await LocalProxy.apply(routes: self.routes, settings: self.settings, proxyID: id, client: client)
        }
    }

    /// A target container just started (its IP may have changed): re-apply the config, debounced by 2 s.
    func containerStarted(_ name: String) {
        guard isRunning, routes.contains(where: { $0.container == name }) else { return }
        pendingApply?.cancel()
        pendingApply = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await apply()
        }
    }

    func add(_ route: ProxyRoute) async {
        guard route.isValid else { return }
        routes.removeAll { $0.subdomain == route.subdomain }
        routes.append(route)
        await apply()
    }

    func remove(_ id: UUID) async {
        routes.removeAll { $0.id == id }
        await apply()
    }

    func trustCertificate() async {
        await run { client in
            guard let id = try await LocalProxy.status(client: client).id else {
                throw LocalProxy.ProxyError.invalid(String(localized: "Start the proxy first."))
            }
            let pem = try await LocalProxy.rootCertificate(proxyID: id, client: client)
            try await LocalProxy.trustRootCertificate(pem)
            self.host?.flash(String(localized: "Caddy local CA is now trusted in your login keychain"))
        }
    }

    func untrustCertificate() async {
        busy = true
        do {
            try await LocalProxy.untrustRootCertificate()
            host?.flash(String(localized: "Removed trust for the Caddy local CA"))
        } catch {
            self.error = error.localizedDescription
        }
        busy = false
    }
}
