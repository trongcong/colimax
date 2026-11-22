import Foundation

// MARK: - Atomic write

enum AtomicFile {
    /// Writes to a temporary file in the **same directory**, then `rename(2)`s it into place
    /// (atomic on the same volume). Avoids `Data.write(options: .atomic)`, which may place its
    /// temporary file in a different directory.
    static func write(_ data: Data, to url: URL, permissions: Int = 0o600) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString.prefix(8))")
        do {
            let handle = try createExclusive(temp, permissions: permissions)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Moves a finished temporary file over `destination`, replacing any existing file.
    /// The new file's metadata wins, so a previous 0644 file does not loosen the 0600 permissions.
    static func install(_ temp: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temp, options: .usingNewMetadataOnly)
        } else {
            try FileManager.default.moveItem(at: temp, to: destination)
        }
    }

    /// Creates a new file (fails if it already exists) with `permissions` (owner-only by default)
    /// and returns a handle for writing. Uses `open(2)` directly because `FileManager.createFile`
    /// writes atomically through a temporary file in another directory.
    static func createExclusive(_ url: URL, permissions: Int = 0o600) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(permissions))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

// MARK: - Manifest

/// The `<backup>.manifest.json` sidecar written next to every backup: source, timestamp, size, SHA-256.
/// Used to verify integrity before restoring.
struct BackupManifest: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case volume, mysql, mariadb, postgres, redis, elasticsearch
    }

    static let currentFormat = 1
    static let suffix = ".manifest.json"

    var format: Int = BackupManifest.currentFormat
    var kind: Kind
    var source: String
    var image: String?
    var createdAt: Date
    var fileName: String
    var size: Int64
    var sha256: String
    var tool: String = BackupManifest.toolName

    static var toolName: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "ColimaX \(version)"
    }

    static func url(for backup: URL) -> URL {
        URL(fileURLWithPath: backup.path + suffix)
    }

    func write(for backup: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try AtomicFile.write(encoder.encode(self), to: Self.url(for: backup))
    }

    /// Returns nil when there is no manifest; throws when the manifest is unreadable.
    static func read(for backup: URL) throws -> BackupManifest? {
        let url = url(for: backup)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(BackupManifest.self, from: Data(contentsOf: url))
        } catch {
            throw BackupError.integrity(String(localized: "Manifest \(url.lastPathComponent) cannot be read: \(error.localizedDescription)"))
        }
    }
}

enum BackupError: LocalizedError, Equatable {
    case integrity(String)
    case invalidArchive(String)
    case containerNotRunning(String)
    case dumpFailed(exitCode: Int, message: String)
    case incompleteDump(String)
    case restoreFailed(exitCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .integrity(let message): String(localized: "Backup integrity check failed: \(message)")
        case .invalidArchive(let message): String(localized: "Not a valid volume backup file: \(message)")
        case .containerNotRunning(let name): String(localized: "Container \(name) is not running. Start it before backing up the database.")
        case .dumpFailed(let code, let message):
            message.isEmpty
                ? String(localized: "Dump command exited with code \(Format.digits(code))")
                : String(localized: "Dump command exited with code \(Format.digits(code)): \(message)")
        case .incompleteDump(let message): String(localized: "Incomplete dump: \(message)")
        case .restoreFailed(let code, let message):
            switch (code == 0, message.isEmpty) {
            case (true, true): String(localized: "Restore failed")
            case (true, false): String(localized: "Restore failed: \(message)")
            case (false, true): String(localized: "Restore failed (exit \(Format.digits(code)))")
            case (false, false): String(localized: "Restore failed (exit \(Format.digits(code))): \(message)")
            }
        }
    }
}

/// Result of verifying a backup file.
enum BackupVerification: Equatable, Sendable {
    /// Matches the manifest (size and SHA-256).
    case verified(BackupManifest)
    /// No manifest; only the current hash is known.
    case noManifest(DockerClient.FileTransfer)

    var summary: String {
        switch self {
        case .verified(let manifest):
            String(localized: "Matches manifest: \(manifest.kind.rawValue) “\(manifest.source)”, \(Format.bytes(manifest.size)), SHA-256 \(String(manifest.sha256.prefix(12)))…, created \(manifest.createdAt.formatted(date: .abbreviated, time: .shortened))")
        case .noManifest(let transfer):
            String(localized: "No manifest — origin cannot be verified. SHA-256 \(String(transfer.sha256.prefix(12)))…, \(Format.bytes(transfer.size))")
        }
    }
}

enum BackupVerifier {
    /// Compares the file against its manifest. Throws `BackupError.integrity` on any mismatch.
    static func verify(_ file: URL) async throws -> BackupVerification {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw BackupError.integrity(String(localized: "file \(file.lastPathComponent) not found"))
        }
        let manifest = try BackupManifest.read(for: file)
        let actual = try await FileHasher.hash(file: file)
        guard let manifest else { return .noManifest(actual) }
        guard manifest.format <= BackupManifest.currentFormat else {
            throw BackupError.integrity(String(localized: "manifest format \(manifest.format) is newer than this app supports"))
        }
        guard actual.size == manifest.size else {
            throw BackupError.integrity(String(localized: "size is \(actual.size) bytes, manifest says \(manifest.size) bytes"))
        }
        guard actual.sha256 == manifest.sha256 else {
            throw BackupError.integrity(String(localized: "SHA-256 does not match the manifest (file was modified or corrupted)"))
        }
        return .verified(manifest)
    }
}

// MARK: - Tar

enum TarInspector {
    /// Checks that the first tar header is the `volume/` directory written by `VolumeBackup.backup`.
    static func validateVolumeArchive(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 512) ?? Data()
        try validateVolumeHeader(header)
    }

    static func validateVolumeHeader(_ header: Data) throws {
        guard header.count == 512 else { throw BackupError.invalidArchive(String(localized: "file is too short")) }
        let bytes = [UInt8](header)
        let magic = String(decoding: bytes[257..<262], as: UTF8.self)
        guard magic == "ustar" else { throw BackupError.invalidArchive(String(localized: "no tar (ustar) header")) }
        let nameBytes = bytes[0..<100].prefix { $0 != 0 }
        let name = String(decoding: nameBytes, as: UTF8.self)
        guard name == "volume" || name.hasPrefix("volume/") else {
            throw BackupError.invalidArchive(String(localized: "root folder is “\(name)”, expected “volume/”"))
        }
    }
}

// MARK: - Volume backup

/// Backs up and restores volumes purely through the Docker API (no docker CLI): creates a
/// temporary, never-started container that mounts the volume, then uses the `/archive`
/// endpoint to download a tar or extract one into it.
enum VolumeBackup {
    static let helperImage = "busybox:latest"
    static let helperLabel = "dev.colimax.helper"

    @discardableResult
    static func backup(volume: String, to file: URL, client: any DockerEngine) async throws -> BackupManifest {
        let id = try await createHelper(volume: volume, readOnly: true, client: client)
        let transfer: DockerClient.FileTransfer
        do {
            transfer = try await client.downloadArchive(container: id, path: "/volume", to: file, timeout: 300)
        } catch {
            try? await client.removeContainer(id, force: true, volumes: false)
            throw error
        }
        try? await client.removeContainer(id, force: true, volumes: false)
        let manifest = BackupManifest(
            kind: .volume,
            source: volume,
            image: nil,
            createdAt: .now,
            fileName: file.lastPathComponent,
            size: transfer.size,
            sha256: transfer.sha256
        )
        try manifest.write(for: file)
        return manifest
    }

    /// Extracts a tar created by `backup` (rooted at `volume/`) into the volume.
    /// Verifies the manifest (if any) and the tar structure **before** touching Docker.
    /// Creates the volume if it does not exist.
    @discardableResult
    static func restore(volume: String, from file: URL, client: any DockerEngine) async throws -> BackupVerification {
        let verification = try await BackupVerifier.verify(file)
        if case .verified(let manifest) = verification, manifest.kind != .volume {
            throw BackupError.invalidArchive(String(localized: "manifest says type \(manifest.kind.rawValue), not volume"))
        }
        try TarInspector.validateVolumeArchive(file)

        let existing = try await client.volumes().map(\.name)
        if !existing.contains(volume) { try await client.createVolume(name: volume, labels: [:]) }

        let id = try await createHelper(volume: volume, readOnly: false, client: client)
        do {
            try await client.uploadArchive(container: id, path: "/", tarFile: file, timeout: 300)
        } catch {
            try? await client.removeContainer(id, force: true, volumes: false)
            throw error
        }
        try? await client.removeContainer(id, force: true, volumes: false)
        return verification
    }

    /// Removes helper containers (the app's own, labelled, never started) left behind when the app
    /// quit mid-operation. `requiredLabel` restricts cleanup to helpers that also carry that label
    /// (integration tests use it to avoid touching real helpers). Returns the removed IDs.
    @discardableResult
    static func cleanupStaleHelpers(client: any DockerEngine, olderThan age: TimeInterval = 600, requiredLabel: String? = nil) async -> [String] {
        guard let containers = try? await client.containers() else { return [] }
        var removed: [String] = []
        for container in staleHelpers(containers, now: Date(), olderThan: age, requiredLabel: requiredLabel) {
            if (try? await client.removeContainer(container.id, force: false, volumes: false)) != nil { removed.append(container.id) }
        }
        return removed
    }

    /// Helpers to clean up: labelled `helperLabel` (and `requiredLabel` if given), state `created`, created before `now - age`.
    static func staleHelpers(_ containers: [DockerContainer], now: Date, olderThan age: TimeInterval, requiredLabel: String? = nil) -> [DockerContainer] {
        let cutoff = now.addingTimeInterval(-age)
        return containers.filter { container in
            container.labels?[helperLabel] != nil && container.state == "created" && container.createdDate < cutoff
                && (requiredLabel.map { container.labels?[$0] != nil } ?? true)
        }
    }

    private static func createHelper(volume: String, readOnly: Bool, client: any DockerEngine) async throws -> String {
        if !(await client.imageExists(helperImage)) {
            for try await progress in client.pull(helperImage) {
                if let error = progress.error { throw DockerError.socket(error) }
            }
        }
        struct HostConfig: Encodable, Sendable { let Binds: [String] }
        struct Body: Encodable, Sendable {
            let Image: String
            let Cmd: [String]
            let Labels: [String: String]
            let HostConfig: HostConfig
        }
        let bind = "\(volume):/volume" + (readOnly ? ":ro" : "")
        let body = Body(
            Image: helperImage,
            Cmd: ["true"],
            Labels: [helperLabel: "volume-backup"],
            HostConfig: HostConfig(Binds: [bind])
        )
        return try await client.createContainer(name: nil, body: body)
    }
}

// MARK: - Database logical backup

/// Databases that support logical backup: a consistent dump through the database's own tooling
/// instead of copying the live data directory.
enum DatabaseEngine: String, CaseIterable, Sendable {
    case mysql, mariadb, postgres, redis

    var title: String {
        switch self {
        case .mysql: "MySQL"
        case .mariadb: "MariaDB"
        case .postgres: "PostgreSQL"
        case .redis: "Redis / Valkey"
        }
    }

    var fileExtension: String { self == .redis ? "rdb" : "sql" }

    var manifestKind: BackupManifest.Kind {
        switch self {
        case .mysql: .mysql
        case .mariadb: .mariadb
        case .postgres: .postgres
        case .redis: .redis
        }
    }

    /// Detects the engine from the image repository name (ignoring registry, tag and digest), e.g.
    /// `mysql:8`, `bitnami/mariadb`, `docker.io/library/postgres:16-alpine`, `valkey/valkey`.
    static func detect(image: String) -> DatabaseEngine? {
        var reference = image.lowercased()
        if let at = reference.firstIndex(of: "@") { reference = String(reference[..<at]) }
        var name = reference.split(separator: "/").last.map(String.init) ?? reference
        if let colon = name.firstIndex(of: ":") { name = String(name[..<colon]) }
        switch name {
        case "mysql", "percona", "percona-server": return .mysql
        case "mariadb": return .mariadb
        case "postgres", "postgresql", "postgis", "timescaledb", "timescaledb-ha": return .postgres
        case "redis", "valkey", "redis-stack-server", "keydb": return .redis
        default: return nil
        }
    }

    /// Script run **inside the container** via `sh -c`. Constant: contains no user input.
    /// Passwords come from the container's own environment and never pass through the app or logs.
    /// stdout carries only dump data; all messages go to stderr.
    var script: String {
        switch self {
        case .mysql, .mariadb:
            #"""
            set -e
            if command -v mariadb-dump >/dev/null 2>&1; then DUMP=mariadb-dump; else DUMP=mysqldump; fi
            PW="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
            PWFILE="${MARIADB_ROOT_PASSWORD_FILE:-${MYSQL_ROOT_PASSWORD_FILE:-}}"
            if [ -z "$PW" ] && [ -n "$PWFILE" ] && [ -r "$PWFILE" ]; then PW="$(cat "$PWFILE")"; fi
            export MYSQL_PWD="$PW"
            exec "$DUMP" -uroot --all-databases --single-transaction --quick --routines --events --triggers
            """#
        case .postgres:
            #"""
            set -e
            exec pg_dumpall --clean --if-exists -U "${POSTGRES_USER:-postgres}"
            """#
        case .redis:
            #"""
            set -e
            CLI="$(command -v redis-cli || command -v valkey-cli || command -v keydb-cli || true)"
            if [ -z "$CLI" ]; then echo "redis-cli not found in container" >&2; exit 127; fi
            if [ -n "${REDIS_PASSWORD:-}" ]; then export REDISCLI_AUTH="$REDIS_PASSWORD"; fi
            F="$(mktemp 2>/dev/null || echo /tmp/colimax-$$.rdb)"
            "$CLI" --rdb "$F" 1>&2
            cat "$F"
            rm -f "$F"
            """#
        }
    }

    /// Checks the start and end of the dump to detect a truncated dump.
    func validate(head: Data, tail: String) throws {
        switch self {
        case .mysql, .mariadb:
            guard tail.contains("Dump completed") else {
                throw BackupError.incompleteDump(String(localized: "missing “Dump completed” line at end of file"))
            }
        case .postgres:
            guard tail.contains("PostgreSQL database cluster dump complete") else {
                throw BackupError.incompleteDump(String(localized: "missing “database cluster dump complete” line at end of file"))
            }
        case .redis:
            guard head.starts(with: Data("REDIS".utf8)) else {
                throw BackupError.incompleteDump(String(localized: "RDB file does not start with “REDIS”"))
            }
        }
    }
}

enum DatabaseBackup {
    /// Runs the dump inside the container, streaming stdout straight to the file (stderr captured
    /// separately), checks the exit code and content, then writes the manifest. Deletes the file on failure.
    @discardableResult
    static func backup(
        container: DockerContainer,
        engine: DatabaseEngine,
        to file: URL,
        client: any DockerEngine
    ) async throws -> BackupManifest {
        guard container.isRunning else { throw BackupError.containerNotRunning(container.name) }

        let execID = try await client.createExec(container.id, command: ["sh", "-c", engine.script])
        let stderr = Locked(Data())
        let transfer = try await client.execToFile(execID, to: file, timeout: 600) { chunk in
            stderr.withLock { buffer in
                if buffer.count < 16_384 { buffer.append(chunk.prefix(16_384 - buffer.count)) }
            }
        }

        do {
            let exitCode = try await client.execExitCode(execID) ?? -1
            guard exitCode == 0 else {
                let message = String(decoding: stderr.current, as: UTF8.self).trimmed
                throw BackupError.dumpFailed(exitCode: exitCode, message: String(message.suffix(600)))
            }
            guard transfer.size > 0 else { throw BackupError.incompleteDump(String(localized: "file is empty")) }
            let (head, tail) = try Self.edges(of: file)
            try engine.validate(head: head, tail: tail)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }

        let manifest = BackupManifest(
            kind: engine.manifestKind,
            source: container.name,
            image: container.image,
            createdAt: .now,
            fileName: file.lastPathComponent,
            size: transfer.size,
            sha256: transfer.sha256
        )
        try manifest.write(for: file)
        return manifest
    }

    /// The first 16 bytes and the last 4 KB of the file.
    static func edges(of file: URL) throws -> (Data, String) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 16) ?? Data()
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > 4096 ? end - 4096 : 0)
        let tail = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        return (head, tail)
    }
}
