import Foundation

/// Elasticsearch / OpenSearch snapshots (G25) through the cluster's own snapshot API.
///
/// REST requests run **inside the container** with `curl` against `localhost:9200` (HTTP, then HTTPS),
/// so no port needs to be published to the host. Credentials come from the container's env
/// (`ELASTIC_PASSWORD`, `OPENSEARCH_INITIAL_ADMIN_PASSWORD`) and never pass through the app.
/// Method / path / body are passed as `sh -c` argv, never interpolated into the script.
///
/// The cluster must declare `path.repo`; the app registers an `fs` repository named `colimax`
/// at `<first path.repo, sorted>/colimax`.
enum ElasticsearchSnapshot {
    static let repository = "colimax"

    enum SnapshotError: LocalizedError, Equatable {
        case noPathRepo
        case http(Int, String)
        case unreachable(String)

        var errorDescription: String? {
            switch self {
            case .noPathRepo:
                String(localized: "The cluster has no path.repo. Add the environment variable path.repo=/usr/share/elasticsearch/snapshots (mount a volume there) and recreate the container.")
            case .http(let code, let message): "Elasticsearch \(code): \(message)"
            case .unreachable(let message): String(localized: "Cannot reach Elasticsearch inside the container: \(message)")
            }
        }
    }

    struct Snapshot: Identifiable, Hashable, Sendable {
        var id: String { name }
        let name: String
        let state: String
        let indices: [String]
        let start: Date?
    }

    enum RestoreMode: Sendable, Equatable {
        /// Restores into new indices named `restored-<old name>`; existing data is untouched.
        case renamed
        /// Deletes the snapshot's indices, then restores them under their original names. Destructive.
        case replace
    }

    static func detect(image: String) -> Bool {
        var reference = image.lowercased()
        if let at = reference.firstIndex(of: "@") { reference = String(reference[..<at]) }
        var name = reference.split(separator: "/").last.map(String.init) ?? reference
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        return name == "elasticsearch" || name == "opensearch"
    }

    /// Snapshot name allowed by Elasticsearch rules (lowercase, no special characters).
    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9._-]{0,200}$"#, options: .regularExpression) != nil
    }

    static func defaultName(at date: Date = .now) -> String {
        "snapshot-" + BackupSchedule.stamp(date).lowercased()
    }

    /// Constant script: `$1` method, `$2` path, `$3` body. Prints the body, then the HTTP status as the last line.
    static let requestScript = #"""
    M="$1"; P="$2"; B="$3"
    if ! command -v curl >/dev/null 2>&1; then echo "curl not found in container" >&2; exit 127; fi
    USER_PW=""
    if [ -n "${ELASTIC_PASSWORD:-}" ]; then USER_PW="elastic:${ELASTIC_PASSWORD}";
    elif [ -n "${OPENSEARCH_INITIAL_ADMIN_PASSWORD:-}" ]; then USER_PW="admin:${OPENSEARCH_INITIAL_ADMIN_PASSWORD}"; fi
    for BASE in http://localhost:9200 https://localhost:9200; do
      if [ -n "$USER_PW" ]; then
        OUT="$(curl -sS -k --max-time 3600 -u "$USER_PW" -X "$M" -H 'Content-Type: application/json' --data-binary "$B" -w '\n%{http_code}' "$BASE$P" 2>&1)" || continue
      else
        OUT="$(curl -sS -k --max-time 3600 -X "$M" -H 'Content-Type: application/json' --data-binary "$B" -w '\n%{http_code}' "$BASE$P" 2>&1)" || continue
      fi
      CODE="$(printf '%s' "$OUT" | tail -n 1)"
      if [ "$CODE" = "000" ]; then continue; fi
      printf '%s' "$OUT"
      exit 0
    done
    echo "no response from localhost:9200" >&2
    exit 7
    """#

    /// Splits the output into body and status (the last line).
    static func parseResponse(_ output: String) -> (status: Int, body: String)? {
        guard let newline = output.lastIndex(of: "\n") else {
            return Int(output.trimmed).map { ($0, "") }
        }
        guard let status = Int(output[output.index(after: newline)...].trimmed) else { return nil }
        return (status, String(output[..<newline]))
    }

    static func request(_ method: String, _ path: String, body: String = "", container: String, client: any DockerEngine, timeout: Int = 120) async throws -> String {
        let result = try await client.exec(container, argv: ["sh", "-c", requestScript, "sh", method, path, body], timeout: timeout)
        guard result.exitCode == 0, let response = parseResponse(result.output) else {
            throw SnapshotError.unreachable(result.output.trimmed.isEmpty ? "exit \(result.exitCode)" : String(result.output.trimmed.suffix(400)))
        }
        guard (200..<300).contains(response.status) else {
            throw SnapshotError.http(response.status, errorReason(response.body))
        }
        return response.body
    }

    static func errorReason(_ body: String) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { let reason: String? }
            let error: Inner?
        }
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(body.utf8)), let reason = envelope.error?.reason {
            return reason
        }
        return String(body.prefix(400))
    }

    // MARK: Parsing (pure, testable)

    /// Parses `GET _nodes/settings?filter_path=nodes.*.settings.path.repo` into the `path.repo` list.
    /// The value may be an array or a comma-separated string (when set through an environment variable).
    static func parsePathRepo(_ body: String) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
              let nodes = root["nodes"] as? [String: Any] else { return [] }
        var result: [String] = []
        for case let node as [String: Any] in nodes.values {
            let repo = ((node["settings"] as? [String: Any])?["path"] as? [String: Any])?["repo"]
                ?? (node["settings"] as? [String: Any])?["path.repo"]
            if let list = repo as? [String] { result += list }
            if let single = repo as? String { result += single.split(separator: ",").map { String($0).trimmed } }
        }
        return Array(Set(result.filter { $0.hasPrefix("/") })).sorted()
    }

    static func parseSnapshots(_ body: String) throws -> [Snapshot] {
        struct Response: Decodable {
            struct Item: Decodable {
                let snapshot: String
                let state: String?
                let indices: [String]?
                let start_time_in_millis: Double?
            }
            let snapshots: [Item]?
        }
        let response = try JSONDecoder().decode(Response.self, from: Data(body.utf8))
        return (response.snapshots ?? []).map {
            Snapshot(name: $0.snapshot, state: $0.state ?? "UNKNOWN", indices: ($0.indices ?? []).sorted(),
                     start: $0.start_time_in_millis.map { Date(timeIntervalSince1970: $0 / 1000) })
        }
        .sorted { ($0.start ?? .distantPast) > ($1.start ?? .distantPast) }
    }

    /// User indices (excludes system indices starting with `.`).
    static func userIndices(_ indices: [String]) -> [String] {
        indices.filter { !$0.hasPrefix(".") }
    }

    static func restoreBody(_ snapshot: Snapshot, mode: RestoreMode) throws -> String {
        var body: [String: Any] = [
            "indices": userIndices(snapshot.indices).joined(separator: ","),
            "include_global_state": false,
        ]
        if mode == .renamed {
            body["rename_pattern"] = "(.+)"
            body["rename_replacement"] = "restored-$1"
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
    }

    // MARK: Operations

    /// Registers (or updates) the `colimax` repository; returns its location inside the container.
    static func ensureRepository(container: String, client: any DockerEngine) async throws -> String {
        let settings = try await request("GET", "/_nodes/settings?filter_path=nodes.*.settings.path.repo", container: container, client: client)
        guard let root = parsePathRepo(settings).first else { throw SnapshotError.noPathRepo }
        let location = root.hasSuffix("/") ? root + repository : root + "/" + repository
        let body = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "fs", "settings": ["location": location]], options: [.sortedKeys]), as: UTF8.self)
        _ = try await request("PUT", "/_snapshot/\(repository)", body: body, container: container, client: client)
        return location
    }

    static func list(container: String, client: any DockerEngine) async throws -> [Snapshot] {
        try parseSnapshots(try await request("GET", "/_snapshot/\(repository)/_all", container: container, client: client))
    }

    static func create(_ name: String, container: String, client: any DockerEngine) async throws {
        guard isValidName(name) else { throw SnapshotError.http(400, String(localized: "invalid snapshot name")) }
        let body = #"{"include_global_state":false,"indices":"*,-.*"}"#
        _ = try await request("PUT", "/_snapshot/\(repository)/\(name)?wait_for_completion=true", body: body, container: container, client: client, timeout: 3600)
    }

    static func delete(_ name: String, container: String, client: any DockerEngine) async throws {
        guard isValidName(name) else { throw SnapshotError.http(400, String(localized: "invalid snapshot name")) }
        _ = try await request("DELETE", "/_snapshot/\(repository)/\(name)", container: container, client: client, timeout: 600)
    }

    static func restore(_ snapshot: Snapshot, mode: RestoreMode, container: String, client: any DockerEngine) async throws {
        guard isValidName(snapshot.name) else { throw SnapshotError.http(400, String(localized: "invalid snapshot name")) }
        let indices = userIndices(snapshot.indices)
        if mode == .replace {
            for index in indices where index.range(of: #"^[a-z0-9][a-z0-9._+-]*$"#, options: .regularExpression) != nil {
                do {
                    _ = try await request("DELETE", "/\(index)", container: container, client: client)
                } catch SnapshotError.http(404, _) {
                    continue
                }
            }
        }
        _ = try await request("POST", "/_snapshot/\(repository)/\(snapshot.name)/_restore?wait_for_completion=true",
                              body: try restoreBody(snapshot, mode: mode), container: container, client: client, timeout: 3600)
    }

    /// Downloads the repository directory to a `.tar` on the host, with a SHA-256 manifest.
    @discardableResult
    static func export(location: String, container: DockerContainer, to file: URL, client: any DockerEngine) async throws -> BackupManifest {
        let transfer = try await client.downloadArchive(container: container.id, path: location, to: file, timeout: 3600)
        let manifest = BackupManifest(kind: .elasticsearch, source: container.name, image: container.image, createdAt: .now,
                                      fileName: file.lastPathComponent, size: transfer.size, sha256: transfer.sha256)
        try manifest.write(for: file)
        return manifest
    }
}
