import Foundation

// MARK: - Tar writer

/// Builds a ustar header for a single regular file; sufficient for `PUT /containers/{id}/archive`.
enum TarWriter {
    /// The size field holds 11 octal digits (8 GiB - 1).
    static let maxSize: Int64 = 0o77777777777

    static func paddedSize(_ size: Int64) -> Int64 { (size + 511) / 512 * 512 }

    /// Header + padded content + two zero blocks terminating the archive.
    static func archiveSize(contentSize: Int64) -> Int64 { 512 + paddedSize(contentSize) + 1024 }

    static func header(name: String, size: Int64, mode: Int = 0o644, mtime: Date = .now) throws -> Data {
        guard isValidEntryName(name) else { throw BackupError.invalidArchive(String(localized: "invalid tar entry name “\(name)”")) }
        guard size >= 0, size <= maxSize else { throw BackupError.invalidArchive(String(localized: "file larger than 8 GiB is not supported")) }
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, length: Int) {
            for (index, byte) in text.utf8.prefix(length).enumerated() { block[offset + index] = byte }
        }
        func octal(_ value: Int64, digits: Int) -> String {
            let raw = String(value, radix: 8)
            return String(repeating: "0", count: max(0, digits - raw.count)) + raw
        }
        put(name, at: 0, length: 100)
        put(octal(Int64(mode), digits: 7), at: 100, length: 8)
        put(octal(0, digits: 7), at: 108, length: 8)
        put(octal(0, digits: 7), at: 116, length: 8)
        put(octal(size, digits: 11), at: 124, length: 12)
        put(octal(Int64(mtime.timeIntervalSince1970), digits: 11), at: 136, length: 12)
        put("        ", at: 148, length: 8)
        put("0", at: 156, length: 1)
        put("ustar", at: 257, length: 6)
        put("00", at: 263, length: 2)
        let checksum = block.reduce(0) { $0 + Int64($1) }
        put(octal(checksum, digits: 6), at: 148, length: 6)
        block[154] = 0
        block[155] = 0x20
        return Data(block)
    }

    /// A bare file name only (no `/`, cannot start with `.`), limited to `[A-Za-z0-9._-]`, at most 100 bytes.
    static func isValidEntryName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"#, options: .regularExpression) != nil
    }
}

// MARK: - Database restore

/// Restores a logical dump (created by `DatabaseBackup`) into a running database container.
///
/// - MySQL / MariaDB / PostgreSQL: copies the file into the container's `/tmp` via the archive API,
///   runs the database's own client on it, then deletes it. Credentials come from the container's env.
/// - Redis / Valkey: stops the container, replaces the RDB file in its data directory, and starts it
///   again (also when the upload fails). Refused when AOF is enabled, since Redis would ignore the RDB.
///
/// All file checks (manifest, SHA-256, dump type, head / tail content) run before touching Docker.
enum DatabaseRestore {
    static let stagingDirectory = "/tmp"
    static let stagingName = "colimax-restore.dump"

    struct Outcome: Equatable, Sendable {
        let verification: BackupVerification
        /// Non-fatal errors reported by the client (e.g. psql reporting that a role already exists).
        let warnings: [String]
    }

    enum Family: Equatable { case mysql, postgres, redis }

    static func family(_ engine: DatabaseEngine) -> Family {
        switch engine {
        case .mysql, .mariadb: .mysql
        case .postgres: .postgres
        case .redis: .redis
        }
    }

    static func family(_ kind: BackupManifest.Kind) -> Family? {
        switch kind {
        case .mysql, .mariadb: .mysql
        case .postgres: .postgres
        case .redis: .redis
        case .volume, .elasticsearch: nil
        }
    }

    /// Validates the file **without touching Docker**: manifest (if any), dump type matches the engine, dump is complete.
    static func preflight(_ file: URL, engine: DatabaseEngine) async throws -> BackupVerification {
        let verification = try await BackupVerifier.verify(file)
        if case .verified(let manifest) = verification {
            guard family(manifest.kind) == family(engine) else {
                throw BackupError.invalidArchive(String(localized: "backup is \(manifest.kind.rawValue), container is \(engine.title)"))
            }
        }
        let (head, tail) = try DatabaseBackup.edges(of: file)
        try engine.validate(head: head, tail: tail)
        return verification
    }

    /// Restore script run **inside the container**. Constant: contains no user input. Nil for Redis, which restores by file replacement.
    static func script(_ engine: DatabaseEngine) -> String? {
        let file = "\(stagingDirectory)/\(stagingName)"
        switch engine {
        case .mysql, .mariadb:
            return #"""
            set -e
            F="\#(file)"
            trap 'rm -f "$F"' EXIT
            if command -v mariadb >/dev/null 2>&1; then CLI=mariadb; else CLI=mysql; fi
            PW="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
            PWFILE="${MARIADB_ROOT_PASSWORD_FILE:-${MYSQL_ROOT_PASSWORD_FILE:-}}"
            if [ -z "$PW" ] && [ -n "$PWFILE" ] && [ -r "$PWFILE" ]; then PW="$(cat "$PWFILE")"; fi
            export MYSQL_PWD="$PW"
            "$CLI" -uroot < "$F"
            """#
        case .postgres:
            return #"""
            F="\#(file)"
            trap 'rm -f "$F"' EXIT
            psql -X -q -v ON_ERROR_STOP=0 -U "${POSTGRES_USER:-postgres}" -d postgres -f "$F"
            """#
        case .redis:
            return nil
        }
    }

    @discardableResult
    static func restore(file: URL, into container: DockerContainer, engine: DatabaseEngine, client: any DockerEngine) async throws -> Outcome {
        guard container.isRunning else { throw BackupError.containerNotRunning(container.name) }
        let verification = try await preflight(file, engine: engine)
        switch family(engine) {
        case .redis:
            try await restoreRedis(file: file, container: container, client: client)
            return Outcome(verification: verification, warnings: [])
        case .mysql, .postgres:
            let warnings = try await restoreSQL(file: file, container: container, engine: engine, client: client)
            return Outcome(verification: verification, warnings: warnings)
        }
    }

    private static func restoreSQL(file: URL, container: DockerContainer, engine: DatabaseEngine, client: any DockerEngine) async throws -> [String] {
        guard let script = script(engine) else { return [] }
        try await client.uploadAsTar(container: container.id, directory: stagingDirectory, file: file, entryName: stagingName, mode: 0o644, timeout: 600)
        let result: (output: String, exitCode: Int)
        do {
            result = try await client.exec(container.id, command: script, timeout: 3600)
        } catch {
            _ = try? await client.exec(container.id, command: "rm -f \(stagingDirectory)/\(stagingName)", timeout: 300)
            throw error
        }
        guard result.exitCode == 0 else {
            throw BackupError.restoreFailed(exitCode: result.exitCode, message: String(result.output.trimmed.suffix(600)))
        }
        return warnings(in: result.output)
    }

    /// Non-fatal `ERROR:` lines from the client output. Drops the expected errors when restoring a
    /// `pg_dumpall` into an existing cluster (role already exists, current user cannot be dropped).
    static func warnings(in output: String) -> [String] {
        output.lines
            .map(\.trimmed)
            .filter { $0.contains("ERROR:") }
            .filter { !($0.contains("role \"") && $0.contains("already exists")) }
            .filter { !$0.contains("current user cannot be dropped") }
    }

    /// Each `CONFIG GET` prints a key line followed by a value line.
    static let redisConfigScript = #"""
    set -e
    CLI="$(command -v redis-cli || command -v valkey-cli || command -v keydb-cli || true)"
    if [ -z "$CLI" ]; then echo "redis-cli not found in container" >&2; exit 127; fi
    if [ -n "${REDIS_PASSWORD:-}" ]; then export REDISCLI_AUTH="$REDIS_PASSWORD"; fi
    "$CLI" CONFIG GET dir
    "$CLI" CONFIG GET dbfilename
    "$CLI" CONFIG GET appendonly
    """#

    struct RedisConfig: Equatable {
        let dir: String
        let dbfilename: String
        let appendOnly: Bool
    }

    static func parseRedisConfig(_ output: String) throws -> RedisConfig {
        let lines = output.lines.map(\.trimmed).filter { !$0.isEmpty }
        var values: [String: String] = [:]
        var index = 0
        while index + 1 < lines.count {
            values[lines[index]] = lines[index + 1]
            index += 2
        }
        guard let dir = values["dir"], dir.hasPrefix("/"), !dir.contains(".."),
              let name = values["dbfilename"], TarWriter.isValidEntryName(name)
        else { throw BackupError.restoreFailed(exitCode: 0, message: String(localized: "cannot read Redis dir / dbfilename")) }
        return RedisConfig(dir: dir, dbfilename: name, appendOnly: values["appendonly"] == "yes")
    }

    private static func restoreRedis(file: URL, container: DockerContainer, client: any DockerEngine) async throws {
        let probe = try await client.exec(container.id, command: redisConfigScript, timeout: 300)
        guard probe.exitCode == 0 else {
            throw BackupError.restoreFailed(exitCode: probe.exitCode, message: probe.output.trimmed)
        }
        let config = try parseRedisConfig(probe.output)
        guard !config.appendOnly else {
            throw BackupError.restoreFailed(exitCode: 0, message: String(localized: "appendonly is enabled; Redis would ignore the RDB file. Disable AOF first."))
        }
        // Stop before replacing the file: Redis writes its RDB on shutdown, which would overwrite ours.
        try await client.containerAction(container.id, "stop")
        var uploadError: Error?
        do {
            try await client.uploadAsTar(container: container.id, directory: config.dir, file: file, entryName: config.dbfilename, mode: 0o644, timeout: 600)
        } catch {
            uploadError = error
        }
        try await client.containerAction(container.id, "start")
        if let uploadError { throw uploadError }
    }
}
